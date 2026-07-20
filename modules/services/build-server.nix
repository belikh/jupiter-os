{
  config,
  lib,
  pkgs,
  ...
}:

# The disposable BinaryLane "rebuild the world" build server. In one sentence:
# boots from a minimal custom ISO (hosts/pallene), rebuilds europa's
# btver2-tuned closure, pushes the result to the attic cache on europa (reached
# over the Cloudflare Tunnel at attic.jupiter.au), then deletes itself via the
# BinaryLane API — regardless of whether the build succeeded, so a broken
# build never leaves a server running (and billing) unattended.
#
# This host is never a persistent member of the fleet: it has no storage
# profile, no backup, no branding, no desktop. Everything here is scoped to
# running once, unattended, then disappearing.

let
  cfg = config.jupiter.services.buildServer;

  bl = pkgs.writeShellScriptBin "bl-api" ''
    set -euo pipefail
    # Thin curl wrapper around the BinaryLane API (openapi: binarylane.com.au).
    # Usage: bl-api METHOD PATH [JSON_BODY]
    method="$1"; path="$2"; body="''${3:-}"
    args=(-sS -X "$method" "https://api.binarylane.com.au$path" \
      -H "Authorization: Bearer $(cat "${cfg.apiTokenFile}")")
    if [ -n "$body" ]; then
      args+=(-H "Content-Type: application/json" -d "$body")
    fi
    ${pkgs.curl}/bin/curl "''${args[@]}"
  '';

  # post-build-hook + async pusher: incremental attic push, split into two
  # pieces so a slow/degraded push can NEVER block the build.
  #
  # `man 5 nix.conf`'s post-build-hook section is explicit: "The hook
  # executes synchronously, and blocks other builds from progressing while
  # it runs" and "If the hook fails, the build succeeds but no further
  # builds execute." A previous version of this hook did its retry+timeout
  # loop INLINE, synchronously, directly hitting both of those. Concrete
  # failure this caused (2026-07-19, run 640853): a degraded mesh push could
  # burn up to ~26 minutes (8 attempts x up to 180s + backoff) with the
  # daemon unable to schedule a single new derivation the whole time —
  # visible externally as load average dropping to 0 while `nix build` sat
  # idle. Worse: killing the stuck hook process to "unblock" it made nix
  # treat the hook as FAILED, which (per the same man page) stopped the
  # ENTIRE build from scheduling any further work — aborting the whole
  # multi-hour run outright, well before the closure finished.
  #
  # Fix: pushHook does nothing but append $OUT_PATHS to a queue file under a
  # brief flock (microseconds, no network) and exit — it can never be the
  # thing nix is waiting on. `pusherLoop` is a separate, independently
  # backgrounded process (launched once from runScript, not by nix) that
  # drains the queue and does the actual attic push with the same
  # retry+timeout+backoff design as before, fully decoupled from nix's
  # build scheduling — free to take as long as it needs, or even re-queue a
  # batch that ran out of retries, without stalling anything.
  #
  # HOME=/root so attic finds the push token. --ignore-upstream-cache-filter
  # guarantees storage (built paths are btver2-tuned, not on cache.nixos.org,
  # so the filter is a no-op for them — but explicit so no built path is
  # ever silently delegated away).
  queueFile = "/tmp/attic-queue.txt";
  queueLock = "/tmp/attic-queue.lock";

  pushHook = pkgs.writeShellScript "jupiter-attic-post-build-hook" ''
    export HOME=/root
    set -uo pipefail
    log() { echo "[hook $(date -u +%Y-%m-%dT%H:%M:%S%z)] $*" >>/tmp/attic-hook.log; }
    # Nix passes built outputs via $OUT_PATHS (space-separated), NOT stdin —
    # see `man 5 nix.conf`'s post-build-hook section. A prior version of this
    # hook read `paths="$(cat)"` from stdin, which is always empty (nix never
    # writes there): every single invocation logged "nothing to push" and
    # exited immediately, even while the build produced real outputs the
    # whole time. Confirmed empirically on 2026-07-19 (run 640853): 232
    # consecutive firings, all "empty stdin", while 625+ paths had already
    # registered as built — the hook had never once actually pushed anything
    # this entire bring-up; every push so far was a manual backstop.
    if [ -z "''${OUT_PATHS:-}" ]; then
      log "invoked with no OUT_PATHS (drv ''${DRV_PATH:-?}, nothing to enqueue), exiting"
      exit 0
    fi
    paths="$(printf '%s' "$OUT_PATHS" | tr ' ' '\n')"
    n="$(printf '%s\n' "$paths" | wc -l)"
    # Just enqueue and exit — no network call here, ever. This is the only
    # thing standing between a build completion and nix scheduling the next
    # one, so it must always be near-instant regardless of push health.
    exec 9>${queueLock}
    ${pkgs.util-linux}/bin/flock 9
    printf '%s\n' "$paths" >> ${queueFile}
    exec 9>&-
    log "enqueued: drv=''${DRV_PATH:-?} $n path(s): $(printf '%s' "$paths" | tr '\n' ' ' | head -c 300)"
    exit 0
  '';

  pusherLoop = pkgs.writeShellScript "jupiter-attic-pusher" ''
    export HOME=/root
    set -uo pipefail
    log() { echo "[pusher $(date -u +%Y-%m-%dT%H:%M:%S%z)] $*" >>/tmp/attic-hook.log; }
    log "pusher loop starting"
    : > ${queueFile}
    while true; do
      batch=""
      exec 9>${queueLock}
      ${pkgs.util-linux}/bin/flock 9
      if [ -s ${queueFile} ]; then
        batch="$(cat ${queueFile})"
        : > ${queueFile}
      fi
      exec 9>&-
      if [ -z "$batch" ]; then
        sleep 3
        continue
      fi
      paths="$(printf '%s\n' "$batch" | sort -u)"
      n="$(printf '%s\n' "$paths" | grep -c .)"
      log "draining batch: $n path(s): $(printf '%s' "$paths" | tr '\n' ' ' | head -c 300)"
      pushed=0
      # 600s (was 180s in the old synchronous hook): safe to be generous here
      # now that this loop is off the build-blocking critical path — a large
      # batch (e.g. llvm-src) that needs more than 180s to transfer over a
      # degraded link previously could never succeed (retried from scratch
      # each time, always cut off before finishing); a longer window gives it
      # an actual chance instead of cycling GAVE UP -> re-queue forever.
      for attempt in 1 2 3 4 5 6 7 8; do
        attempt_start=$(date +%s)
        log "  attempt $attempt: starting (timeout 600s)"
        if printf '%s\n' "$paths" | ${pkgs.coreutils}/bin/timeout 600 ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" --stdin --ignore-upstream-cache-filter >>/tmp/attic-hook.log 2>&1; then
          log "  attempt $attempt: SUCCEEDED in $(( $(date +%s) - attempt_start ))s"
          pushed=1
          break
        fi
        rc=$?
        elapsed=$(( $(date +%s) - attempt_start ))
        if [ "$rc" -eq 124 ]; then
          log "  attempt $attempt: TIMED OUT after ''${elapsed}s (push hung — likely a wedged connection, not a clean failure); retry in $((attempt*3))s"
        else
          log "  attempt $attempt: failed (exit $rc) after ''${elapsed}s; retry in $((attempt*3))s"
        fi
        sleep $((attempt * 3))
      done
      if [ "$pushed" != 1 ]; then
        log "!! GAVE UP after 8 attempts on this batch, re-queueing for a later pass: $(printf '%s' "$paths" | tr '\n' ' ' | head -c 300)"
        exec 9>${queueLock}
        ${pkgs.util-linux}/bin/flock 9
        printf '%s\n' "$paths" >> ${queueFile}
        exec 9>&-
        sleep 10
      fi
    done
  '';

  runScript = pkgs.writeShellScript "jupiter-build-server-run" ''
    set -uo pipefail

    # Mirror the entire run to a log file so it survives self-destruct
    # (uploaded to attic in the self_destruct trap below; the server's own
    # journal is lost when it deletes itself, which otherwise makes any
    # build/push failure invisible from the outside).
    exec > >(tee /tmp/jupiter-build.log) 2>&1

    log() { echo "[jupiter-build-server] $*"; }

    # --- self-destruct, unconditionally, no matter what happens above -------
    # This is the "so we don't waste money" guarantee: it runs on ANY exit
    # path (success, build failure, script bug) via the trap below, not just
    # the happy path.
    self_destruct() {
      # Best-effort final flush of anything the async pusher (see pusherLoop
      # above) hadn't gotten to yet — e.g. a batch it was mid-retry on when
      # the build finished. One bounded attempt only: this must never delay
      # self-destruct, and the per-host final push below + a future run's
      # substitution are the real backstop if this also fails.
      if [ -s ${queueFile} ]; then
        ${pkgs.coreutils}/bin/timeout 60 ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" --stdin --ignore-upstream-cache-filter < ${queueFile} >>/tmp/attic-hook.log 2>&1 \
          && log "final queue flush succeeded" \
          || log "!! final queue flush failed/timed out (paths already covered by the toplevel backstop push below, if that host's build succeeded)"
      fi
      # Upload the build log so it survives this self-destruct (best-effort —
      # never let a log-upload problem block the destroy). R2 first (robust:
      # public-internet path like the build's own source fetches), attic second
      # (needs the nix daemon + a reachable attic, so it may fail when those
      # are exactly what failed in the run — which is when we most want a log).
      if [ -f /tmp/jupiter-build.log ]; then
        if [ -f ${cfg.r2AccessKeyIdFile} ]; then
          AWS_ACCESS_KEY_ID="$(cat ${cfg.r2AccessKeyIdFile})" \
          AWS_SECRET_ACCESS_KEY="$(cat ${cfg.r2SecretAccessKeyFile})" \
          ${pkgs.awscli}/bin/aws \
            --endpoint-url "https://$(cat ${cfg.r2AccountIdFile}).r2.cloudflarestorage.com" \
            s3 cp /tmp/jupiter-build.log "s3://${cfg.logBucket}/logs/pallene-$(date -u +%Y%m%d%H%M%S).log" \
            --region auto >/tmp/r2upload.err 2>&1 \
            && log "build log uploaded to R2 (logs/)" \
            || log "!! failed to upload build log to R2: $(head -c 200 /tmp/r2upload.err 2>/dev/null)"
        fi
        # Also upload the per-host nix build logs ($workdir/<host>.log) — these
        # hold the actual compiler/eval errors. Without them a build failure is
        # undiagnosable (the box self-destructs and the detail is gone). $workdir
        # is the main script's mktemp dir, visible here in the same shell.
        if [ -n "''${workdir:-}" ] && [ -d "$workdir" ]; then
          for hl in "$workdir"/*.log; do
            [ -f "$hl" ] || continue
            _hname="$(basename "$hl" .log)"
            AWS_ACCESS_KEY_ID="$(cat ${cfg.r2AccessKeyIdFile})" \
            AWS_SECRET_ACCESS_KEY="$(cat ${cfg.r2SecretAccessKeyFile})" \
            ${pkgs.awscli}/bin/aws \
              --endpoint-url "https://$(cat ${cfg.r2AccountIdFile}).r2.cloudflarestorage.com" \
              s3 cp "$hl" "s3://${cfg.logBucket}/logs/''${_hname}-$(date -u +%Y%m%d%H%M%S).log" \
              --region auto >/dev/null 2>&1 \
              && log "host log uploaded to R2 (logs/''${_hname}-)" \
              || log "!! failed to upload host log ''${_hname} to R2"
          done
        fi
        _logpath="$(${pkgs.nix}/bin/nix store add-path /tmp/jupiter-build.log 2>/dev/null || true)"
        if [ -n "''${_logpath:-}" ]; then
          ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" "$_logpath" >/dev/null 2>&1 \
            && log "build log uploaded to attic: $_logpath" \
            || log "!! failed to upload build log to attic"
        fi
      fi
      # The post-build-hook's own log is a SEPARATE file (/tmp/attic-hook.log,
      # written by pushHook above) — without this it never left the box, so
      # every past "is the hook even running" question needed a live SSH
      # session racing self-destruct instead of a log line. R2 only (not
      # attic — if the hook itself is the thing broken, pushing its own
      # diagnostic log through the same broken path is pointless).
      if [ -f /tmp/attic-hook.log ] && [ -f ${cfg.r2AccessKeyIdFile} ]; then
        AWS_ACCESS_KEY_ID="$(cat ${cfg.r2AccessKeyIdFile})" \
        AWS_SECRET_ACCESS_KEY="$(cat ${cfg.r2SecretAccessKeyFile})" \
        ${pkgs.awscli}/bin/aws \
          --endpoint-url "https://$(cat ${cfg.r2AccountIdFile}).r2.cloudflarestorage.com" \
          s3 cp /tmp/attic-hook.log "s3://${cfg.logBucket}/logs/pallene-attic-hook-$(date -u +%Y%m%d%H%M%S).log" \
          --region auto >/dev/null 2>&1 \
          && log "attic-hook log uploaded to R2 (logs/)" \
          || log "!! failed to upload attic-hook log to R2"
      fi
      # Self-destruct MUST be reliable — this is the "stop billing" guarantee.
      # It must NOT depend on the `hostname` command (not on pallene's PATH by
      # default — its absence silently broke self-destruct and left idle
      # servers billing for hours) or on the OS hostname matching the
      # BinaryLane server name (it may not). Instead: list all servers and
      # destroy every one matching the disposable `pallene*` pattern.
      # There is normally exactly one (this one); destroying extras is safe,
      # since every pallene* is an ephemeral build server meant to be
      # torn down. The trap below fires on ANY exit (success or failure).
      log "self-destruct: finding pallene* servers to destroy..."
      my_ids=""
      for attempt in 1 2 3 4 5; do
        resp="$(${bl}/bin/bl-api GET "/v2/servers" 2>/dev/null || true)"
        my_ids="$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.servers[]? | select(.name | test("^pallene")) | .id' 2>/dev/null || true)"
        if [ -n "$my_ids" ]; then break; fi
        log "self-destruct attempt $attempt: no pallene* matched (raw: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 180)); retrying in 10s"
        sleep 10
      done
      if [ -z "''${my_ids:-}" ]; then
        log "!! could not find any pallene* server after retries — CANNOT self-destruct." >&2
        log "!! ${cfg.destroyFallbackNote}" >&2
        return 1
      fi
      for my_id in $my_ids; do
        log "destroying server id=$my_id (reason: rebuild-the-world run complete)"
        ${bl}/bin/bl-api DELETE "/v2/servers/$my_id?reason=rebuild-the-world+run+complete" \
          || log "!! destroy call failed for $my_id — ${cfg.destroyFallbackNote}" >&2
      done
    }
    trap self_destruct EXIT

    # --- figure out what to build, and load secrets, entirely at RUNTIME -----
    # BinaryLane's cloud-init datasource passes the user_data given at
    # server-create time via this exact file, written early in boot
    # independent of whether cloud-init recognizes the content as YAML — this
    # was already relied on for the git ref alone; it's now the single source
    # for every per-run parameter (git ref, host list, and every secret this
    # script needs), so a single stable ISO build is reused across every run.
    # Only rebuild the ISO when this module (or wireguard.nix / the pallene
    # host config) actually changes.
    #
    # Format: plain `KEY=value` lines (directly `source`-able), one of
    # GIT_REF / HOSTS / MAX_JOBS / CORES / BINARYLANE_API_TOKEN /
    # ATTIC_PUSH_TOKEN / R2_ACCOUNT_ID / R2_ACCESS_KEY_ID /
    # R2_SECRET_ACCESS_KEY per line — see scripts/binarylane-build-server.sh,
    # which builds and sends this blob. Backward-compatible fallback: if the
    # content has no `=` at all, treat it as a bare git ref (the
    # pre-runtime-params behaviour), so a server created by hand from the
    # BinaryLane console with a plain ref still works using the baked
    # defaults for everything else.
    ref="${cfg.defaultRef}"
    repo_url="${cfg.repoUrl}"
    runtime_hosts=""
    max_jobs="${cfg.defaultMaxJobs}"
    cores="${toString cfg.defaultCores}"
    attic_server="${cfg.atticServer}"
    wg_peer_public_key="${cfg.wireguardPeerPublicKey}"
    wg_endpoint="${cfg.wireguardEndpoint}"
    wg_allowed_ips="${lib.concatStringsSep "," cfg.wireguardAllowedIPs}"
    wg_address="${cfg.wireguardAddress}"
    runtime_dir=/var/lib/jupiter-build-server
    userdata_file=/var/lib/cloud/instance/user-data.txt
    mkdir -p "$runtime_dir"
    if [ -r "$userdata_file" ] && [ -s "$userdata_file" ] && grep -q '=' "$userdata_file" 2>/dev/null; then
      log "loading runtime parameters from cloud-init user-data"
      set -a
      # shellcheck disable=SC1090
      source "$userdata_file"
      set +a
      [ -n "''${GIT_REF:-}" ] && ref="$GIT_REF" && log "  git ref: $ref"
      [ -n "''${REPO_URL:-}" ] && repo_url="$REPO_URL" && log "  repo url: $repo_url"
      [ -n "''${HOSTS:-}" ] && runtime_hosts="$HOSTS" && log "  hosts: $runtime_hosts"
      [ -n "''${MAX_JOBS:-}" ] && max_jobs="$MAX_JOBS" && log "  max-jobs: $max_jobs"
      [ -n "''${CORES:-}" ] && cores="$CORES" && log "  cores: $cores"
      [ -n "''${ATTIC_SERVER:-}" ] && attic_server="$ATTIC_SERVER" && log "  attic server: $attic_server"
      [ -n "''${WG_PEER_PUBLIC_KEY:-}" ] && wg_peer_public_key="$WG_PEER_PUBLIC_KEY"
      [ -n "''${WG_ENDPOINT:-}" ] && wg_endpoint="$WG_ENDPOINT"
      [ -n "''${WG_ALLOWED_IPS:-}" ] && wg_allowed_ips="$WG_ALLOWED_IPS"
      [ -n "''${WG_ADDRESS:-}" ] && wg_address="$WG_ADDRESS"
      for pair in \
        "BINARYLANE_API_TOKEN ${cfg.apiTokenFile}" \
        "ATTIC_PUSH_TOKEN ${cfg.atticPushTokenFile}" \
        "R2_ACCOUNT_ID ${cfg.r2AccountIdFile}" \
        "R2_ACCESS_KEY_ID ${cfg.r2AccessKeyIdFile}" \
        "R2_SECRET_ACCESS_KEY ${cfg.r2SecretAccessKeyFile}" \
        "WIREGUARD_PRIVATE_KEY ${cfg.wireguardPrivateKeyFile}"; do
        set -- $pair
        varname="$1"
        destfile="$2"
        val="''${!varname:-}"
        if [ -n "$val" ]; then
          mkdir -p "$(dirname "$destfile")"
          printf '%s' "$val" > "$destfile"
          chmod 0400 "$destfile"
        fi
      done
    elif [ -r "$userdata_file" ] && [ -s "$userdata_file" ]; then
      ref="$(tr -d '[:space:]' < "$userdata_file")"
      log "cloud-init user-data has no '=' — treating as a bare git ref: $ref"
    else
      log "no cloud-init user-data found, defaulting to ref: $ref"
    fi

    # Every secret must exist by now — from user-data above, or baked at ISO
    # build time (only the WireGuard key still is; see hosts/pallene). A
    # missing file here means a genuinely broken run: fail fast and loud
    # rather than let attic-login/self-destruct fail confusingly later with
    # no clue why, wasting the whole run's compute for nothing.
    for f in "${cfg.apiTokenFile}" "${cfg.atticPushTokenFile}" "${cfg.r2AccountIdFile}" "${cfg.r2AccessKeyIdFile}" "${cfg.r2SecretAccessKeyFile}"; do
      if [ ! -s "$f" ]; then
        log "!! required secret file missing/empty: $f (not in cloud-init user-data and not baked) — aborting" >&2
        exit 1
      fi
    done

    workdir="$(mktemp -d)"
    log "cloning $repo_url @ $ref into $workdir"
    if ! timeout 600 ${pkgs.git}/bin/git clone --depth 1 --branch "$ref" "$repo_url" "$workdir/jupiter-os"; then
      log "!! clone failed, aborting run (self-destruct still fires)" >&2
      exit 1
    fi
    cd "$workdir/jupiter-os"

    # --- wireguard mesh (if enabled) -------------------------------------------
    # Configured directly with ip/wg rather than the declarative
    # networking.wireguard.interfaces module — every piece of this (key,
    # peer, endpoint, allowed-ips, this host's own address) is runtime data
    # by the time we get here (from user-data above or the module's own
    # defaults), so there's no NixOS-build-time option to set it through in
    # the first place; doing it inline here also means it inherits this
    # script's own correct ordering (well after cloud-final) for free,
    # instead of needing a separate systemd-unit dependency to get right.
    ${lib.optionalString cfg.wireguardEnable ''
      if [ -z "$wg_peer_public_key" ] || [ -z "$wg_endpoint" ] || [ -z "$wg_allowed_ips" ] || [ -z "$wg_address" ]; then
        log "!! wireguardEnable is set but peer/endpoint/allowed-ips/address are incomplete (check user-data WG_* keys and the module's defaults) — skipping mesh, attic reachability may fail" >&2
      elif [ ! -s "${cfg.wireguardPrivateKeyFile}" ]; then
        log "!! wireguard enabled but no private key at ${cfg.wireguardPrivateKeyFile} — skipping mesh" >&2
      else
        log "bringing up wireguard interface ${cfg.wireguardInterfaceName}"
        ${pkgs.iproute2}/bin/ip link add ${cfg.wireguardInterfaceName} type wireguard
        ${pkgs.wireguard-tools}/bin/wg set ${cfg.wireguardInterfaceName} \
          private-key ${cfg.wireguardPrivateKeyFile} \
          peer "$wg_peer_public_key" \
          endpoint "$wg_endpoint" \
          allowed-ips "$wg_allowed_ips" \
          persistent-keepalive ${toString cfg.wireguardPersistentKeepalive}
        ${pkgs.iproute2}/bin/ip address add "$wg_address" dev ${cfg.wireguardInterfaceName}
        ${pkgs.iproute2}/bin/ip link set up dev ${cfg.wireguardInterfaceName}
        # Install kernel routes for every allowed-ips CIDR. WireGuard's
        # allowed-ips only controls which packets WG will ENCRYPT for the
        # peer; the kernel routing table still needs an explicit route per
        # CIDR to actually send those packets into the interface. With only
        # `ip address add <addr>/32` (the typical wg_address), the kernel
        # has no route to any wider CIDR in allowed-ips and falls back to
        # the default route — which on a BinaryLane VPS goes to a gateway
        # with no route to RFC1918 space, so the packets black-hole and
        # every TCP connect times out after 15s.
        # Concrete failure this fixes (2026-07-19, run 640782): pallene's
        # wg_address was 192.168.5.2/32 and allowed-ips was
        # "10.1.1.0/24,192.168.5.0/24" — the kernel had a connected route
        # to 192.168.5.0/24 but no route at all to 10.1.1.0/24, so every
        # nix-daemon substitution attempt to europa (10.1.1.2:8080) went
        # out the public ens3 interface and timed out. `attic login`'s
        # 120s gate passed because that subcommand only writes the token
        # locally without contacting the server, so the failure was silent
        # and pallene spent 1h45m rebuilding paths already in attic before
        # anyone noticed.
        IFS=',' read -ra _wg_cidrs <<< "$wg_allowed_ips"
        for _cidr in "''${_wg_cidrs[@]}"; do
          # Skip the host's own interface address — `ip address add` already
          # installed a connected route for that exact prefix.
          [ "$_cidr" != "$wg_address" ] || continue
          if ${pkgs.iproute2}/bin/ip route add "$_cidr" dev ${cfg.wireguardInterfaceName} 2>/dev/null; then
            log "  route added: $_cidr dev ${cfg.wireguardInterfaceName}"
          else
            log "  route add skipped for $_cidr (already present or unreachable via this interface)"
          fi
        done
        unset _wg_cidrs _cidr
        log "wireguard up: $(${pkgs.wireguard-tools}/bin/wg show ${cfg.wireguardInterfaceName} 2>&1 | tr '\n' ' ')"
      fi
    ''}

    # --- attic auth -----------------------------------------------------------
    # $attic_server (not ${cfg.atticServer} directly) so ATTIC_SERVER in
    # user-data can point a run at a different endpoint without an ISO
    # rebuild — e.g. bypassing a degraded path in favour of a direct
    # UDM port-forward, same override pattern as MAX_JOBS/CORES/WG_*.
    # Timeout: if the attic server is unreachable from this builder the login
    # would otherwise hang for hours (0 CPU) until the 4h force-destroy. A
    # 2-min ceiling turns that into a fast, visible failure → self-destruct.
    if ! timeout 120 ${pkgs.attic-client}/bin/attic login jupiter "$attic_server" "$(cat "${cfg.atticPushTokenFile}")"; then
      log "!! attic login failed or timed out (network to $attic_server?) — cannot push, aborting" >&2
      exit 1
    fi

    # Launch the async push queue drainer now that login succeeded — see
    # pusherLoop's comment above for why this must run independently of
    # nix's post-build-hook rather than inside it.
    log "launching background attic-push queue drainer"
    nohup ${pusherLoop} >/dev/null 2>&1 &
    disown

    # --- use the data disk as swap so the build isn't RAM-bound --------------
    # The live ISO builds into /nix/store + /tmp, both tmpfs (RAM) — a full
    # btver2 closure build (hundreds of GB) fills RAM and dies "no space left
    # on device". The 340 GB BinaryLane data disk otherwise sits unused. Add it
    # as swap AND raise every tmpfs size cap so the tmpfs can actually spill
    # into the swap (swap alone does NOT raise a tmpfs's size= cap — the
    # remount is what unblocks it). We deliberately do NOT mount the disk over
    # /nix/store: that hides the live ISO's base system (nix/gcc/bash live in
    # the squashfs lower layer of the store overlay) and breaks everything.
    # lsblk/mkswap/swapon/findmnt/mount all live in util-linux — reference them
    # by absolute nix-store path. The systemd service runs with a minimal PATH,
    # so bare `lsblk`/`mkswap`/`swapon` are silently "command not found" (hidden
    # by 2>/dev/null) — which is exactly why swap never enabled on the first
    # attempt. Also log the lsblk output + swapon result so the next run's log
    # shows the disk layout if this still goes wrong.
    ul=${pkgs.util-linux}
    # Pick the largest block device to repurpose as swap, preferring a
    # partition (BinaryLane's disk carries a leftover vda1 part from the
    # debian-12 placeholder, so mkswap on the whole /dev/vda is refused because
    # a partition table already exists); fall back to the whole disk. Parsed in
    # PURE BASH because the minimal installer's service PATH has no awk/jq —
    # the first attempt piped lsblk through `awk`, which silently errored
    # "command not found" → empty result → "no data disk found" → no swap →
    # RAM-bound OOM mid-build. -l = flat list (no ├─/└─ tree glyphs), -b =
    # bytes. Skip partitions < 1 GiB (vda14/vda15 boot/efi leftovers).
    pick_swap_dev() {
      local want_type="$1" best="" best_size=0 name typ size
      while IFS=$' \t' read -r name typ size _; do
        [ "$typ" = "$want_type" ] || continue
        size="''${size:-0}"
        [ "$size" -gt 1073741824 ] 2>/dev/null || continue
        if [ "$size" -gt "$best_size" ]; then best="$name"; best_size="$size"; fi
      done < <($ul/bin/lsblk -lnbo NAME,TYPE,SIZE 2>/dev/null)
      printf '%s' "$best"
    }
    data_disk="$(pick_swap_dev part)"
    [ -n "$data_disk" ] || data_disk="$(pick_swap_dev disk)"
    log "swap setup: swap device=''${data_disk:-<none>}; lsblk: $($ul/bin/lsblk -nbo NAME,TYPE,SIZE 2>/dev/null | tr '\n' ';')"
    if [ -n "$data_disk" ] && [ -b "/dev/$data_disk" ]; then
      if $ul/bin/mkswap "/dev/$data_disk" >/dev/null 2>&1 && $ul/bin/swapon "/dev/$data_disk"; then
        log "swap online on /dev/$data_disk; raising tmpfs size caps so the store + /tmp can spill to it"
        # NOTE: findmnt needs -l (list mode) so targets come back clean
        # ("/nix/.rw-store") and NOT tree-formatted ("├─/nix/.rw-store") — the
        # leading glyph would make the remount target an invalid path, failing
        # silently under `|| true` and leaving the store tmpfs at its default
        # 50%-of-RAM cap (986 MiB here), which ENOSPC's the build even with 40G
        # of swap available. swap alone does NOT raise a tmpfs size= cap.
        while IFS=$' \t' read -r m fstype _; do
          [ "$fstype" = "tmpfs" ] || continue
          if $ul/bin/mount -o remount,size=300G "$m" 2>/dev/null; then
            log "  tmpfs raised: $m -> size=300G"
          fi
        done < <($ul/bin/findmnt -nlbo TARGET,FSTYPE 2>/dev/null)
        log "swap now active: $($ul/bin/swapon --show 2>/dev/null | tr '\n' ' ')"
      else
        log "!! mkswap/swapon failed on /dev/$data_disk — build may run out of RAM"
      fi
    else
      log "!! no data disk found — build may run out of RAM"
    fi

    # --- rebuild the world, all hosts at once, best-effort --------------------
    # Every host's build+push runs as its own background job, all talking to
    # the SAME nix-daemon — the daemon (max-jobs/cores set to "auto" below, so
    # it scales to whatever size tier this run actually landed on) does the
    # actual scheduling, dedup, and concurrency-limiting across all of them.
    # A single broken host must not stop the rest from being built and
    # pushed, and each host is pushed to attic the moment ITS build finishes
    # rather than waiting on the slowest host — but the overall run should
    # still report failure so CI knows something needs attention.
    #
    # Host list: from cloud-init user-data (HOSTS=, comma/space-separated) if
    # given, else the module's baked default — same override pattern as the
    # git ref, so which hosts a run builds is also a per-run choice, not an
    # ISO-rebuild one.
    if [ -n "$runtime_hosts" ]; then
      host_list="$(printf '%s' "$runtime_hosts" | tr ',' ' ')"
    else
      host_list="${lib.concatStringsSep " " cfg.hosts}"
    fi
    log "hosts to build: $host_list"
    log "concurrency: max-jobs=$max_jobs cores=$cores"
    pids=()
    for host in $host_list; do
      (
        log "building $host..."
        # --fallback: the WireGuard mesh back to europa's attic occasionally
        # corrupts a substituter transfer mid-stream ("Transferred a partial
        # file") rather than failing cleanly — without --fallback nix treats
        # that as fatal and aborts the ENTIRE closure build over one flaky
        # download (observed 2026-07-17: killed a multi-host run in <3min
        # over a single corrupted compiler-rt-src fetch). --fallback makes
        # nix rebuild/refetch that one derivation from its original source
        # instead of aborting when a substitute fails to download intact.
        # --max-jobs/--cores: explicit CLI flags, not just nix.conf, so the
        # runtime MAX_JOBS/CORES user-data override (sized to whatever VPS
        # tier THIS run actually landed on) actually takes effect — nix.conf
        # only supplies the size-agnostic fallback baked at ISO build time.
        if ${pkgs.nix}/bin/nix build ".#nixosConfigurations.$host.config.system.build.toplevel" \
             --no-link --print-out-paths --fallback \
             --max-jobs "$max_jobs" --cores "$cores" \
             > "$workdir/$host.outpath" 2>"$workdir/$host.log"; then
          outpath="$(cat "$workdir/$host.outpath")"
          log "$host built: $outpath"
          # Final push = a backstop sweep of the toplevel closure. The
          # post-build-hook already cached every package as it built; this just
          # catches anything it missed. Retry on failure, and NEVER fail the run
          # on its account — the build succeeded and the hook did the caching.
          # No --ignore-upstream-cache-filter here (unlike the hook): this
          # pushes the whole closure including public cache.nixos.org deps, and
          # the filter correctly delegates those (only stores the btver2 paths).
          # timeout: without it, a wedged mesh connection hangs this push
          # forever — the host job's `wait` (below) never returns, so the
          # whole run never reaches self_destruct until the 6h force-destroy
          # safety net. 300s is generous for a whole-closure push even over
          # a degraded link; a hung attempt gets abandoned and retried fresh.
          ok=0
          for attempt in 1 2 3; do
            if ${pkgs.coreutils}/bin/timeout 300 ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" "$outpath" >/dev/null 2>&1; then
              ok=1
              break
            fi
            sleep 5
          done
          [ "$ok" = 1 ] || log "!! final attic push failed for $host (post-build-hook should still have cached each package)"
        else
          log "!! build failed for $host — see $workdir/$host.log" >&2
          tail -n 40 "$workdir/$host.log" >&2 || true
          exit 1
        fi
      ) &
      pids+=("$!")
    done

    overall_status=0
    for pid in "''${pids[@]}"; do
      wait "$pid" || overall_status=1
    done

    log "rebuild-the-world run complete, overall_status=$overall_status"
    exit "$overall_status"
  '';
in
{
  options.jupiter.services.buildServer = {
    enable = lib.mkEnableOption "the ephemeral BinaryLane rebuild-the-world build server";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/belikh/jupiter-os.git";
      description = "Repo to clone and build from at boot.";
    };

    defaultRef = lib.mkOption {
      type = lib.types.str;
      # Until scripts/binarylane-build-server.sh wires GIT_REF through
      # cloud-init user-data, this default is what pallene actually builds.
      # main carries the hosts in `hosts/` (the former phase2 branch, now
      # promoted to trunk).
      default = "main";
      description = ''
        Git ref to build when cloud-init user-data is absent. Defaults to the
        active development branch; override via BinaryLane user-data at
        server-create time to build a specific commit without rebuilding the
        ISO.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "europa"
        "callisto"
      ];
      description = ''
        The nixosConfigurations to rebuild and push each run. Europa (btver2)
        and callisto (skylake — added 2026-07-20 once the i5-8500T Coffee Lake
        was confirmed on the running box) are the microarch-tuned hosts;
        untuned hosts substitute from cache.nixos.org already, so building
        them here just wastes compute. Add hosts here as they adopt
        jupiter.build.microarch.
      '';
    };

    defaultMaxJobs = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = ''
        `nix build --max-jobs` value when cloud-init user-data has no
        MAX_JOBS override. "auto" resolves to nproc. Override per-run via
        MAX_JOBS= in BinaryLane user-data — which size/job split is correct
        depends on which VPS tier THIS run actually landed on, a per-run
        fact, never one to bake into the ISO.
      '';
    };

    defaultCores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        `nix build --cores` value when cloud-init user-data has no CORES
        override. 1 (each concurrent job single-threaded, so max-jobs alone
        controls parallelism) is the safe default for any vCPU count — see
        the nix.settings.cores comment below for the oversubscription bug
        this avoids. Override per-run via CORES= in BinaryLane user-data if a
        future dependency graph genuinely needs wide per-job parallelism
        (e.g. one huge monolithic compile) instead of many concurrent jobs.
      '';
    };

    # ---- WireGuard build mesh: defaults only, entirely runtime-overridable
    # via cloud-init user-data (WIREGUARD_PRIVATE_KEY / WG_PEER_PUBLIC_KEY /
    # WG_ENDPOINT / WG_ALLOWED_IPS / WG_ADDRESS) — see the runScript's
    # "wireguard mesh" section, which brings the interface up directly with
    # `ip`/`wg` rather than through the declarative networking.wireguard
    # module (that module is still right for europa, the server peer whose
    # key comes from sops at activation time with no boot race; pallene's
    # whole mesh identity is boot-time cloud-init data instead, so keeping
    # only ONE piece — the key — as a NixOS-time default while the rest was
    # fixed at ISO build time was an inconsistent half-measure).
    wireguardEnable = lib.mkEnableOption "the WireGuard route to attic (bypasses the Cloudflare Tunnel's ~100s NAR-size limit)";

    wireguardInterfaceName = lib.mkOption {
      type = lib.types.str;
      default = "jupwg";
      description = "Name of the WireGuard interface the runScript brings up.";
    };

    wireguardAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "This host's WireGuard IPv4/CIDR on the mesh, e.g. \"192.168.5.2/32\".";
    };

    wireguardPeerPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Public key of the mesh peer to connect to (e.g. the UDM's WireGuard server).";
    };

    wireguardEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "host:port of the mesh peer's public WireGuard endpoint.";
    };

    wireguardAllowedIPs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "CIDR ranges routed over the WireGuard interface.";
    };

    wireguardPersistentKeepalive = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Keepalive interval in seconds — needed since pallene is behind NAT as the roaming client.";
    };

    apiTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/binarylane-api-token";
      description = ''
        Path to a file containing the BinaryLane API bearer token, used only
        to look up and delete *this* server at the end of the run. Written at
        BOOT time from cloud-init user-data (BINARYLANE_API_TOKEN=) by the
        runScript — not baked into the ISO, so rotating this token or running
        against a different account never needs an ISO rebuild. There is no
        persistent host key here for sops-nix to decrypt against at runtime,
        which is exactly why this has to arrive via user-data instead.
      '';
    };

    atticServer = lib.mkOption {
      type = lib.types.str;
      default = "https://attic.jupiter.au";
      description = ''
        Base URL of the attic server this builder pushes to. europa's atticd,
        reached over the public internet via the Cloudflare Tunnel
        (modules/services/cloudflare-tunnel.nix).

        This is the DEFAULT only — runScript's attic-login step reads
        ATTIC_SERVER from cloud-init user-data first (same override pattern
        as MAX_JOBS/CORES/WG_*), so a run can point at a different endpoint
        without an ISO rebuild. NOTE this only affects the attic-client
        login/push path; nix.settings.substituters below is baked from this
        same option at ISO BUILD time and can't be runtime-overridden (nix.conf
        is read once at daemon startup) — keep the two in sync by changing
        this default when the reliable path changes, not just via user-data.
      '';
    };

    atticCache = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os";
      description = "Name of the attic cache to push built closures into.";
    };

    atticPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os:jd6naJxSxt9xPtYTaOSQDOoeoHil5OsVy8ltpIBs9dQ=";
      description = ''
        Public key of the attic cache (a "name:base64..." string), used to
        verify paths substituted from the attic server. Must match the key
        minted by `attic cache create` on the attic host (europa) and set in
        attic-server.nix's publicKey option — keep the two in sync. If this is
        wrong, nix silently doesn't trust the paths and falls through to
        cache.nixos.org (harmless: pallene just builds from source, as it did
        before this substituter was wired).
      '';
    };

    atticPushTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/attic-push-token";
      description = ''
        Path to a file containing the attic push token. Written at boot time
        from cloud-init user-data (ATTIC_PUSH_TOKEN=), same as apiTokenFile.
      '';
    };

    # R2 credentials for the robust build-log upload (see self_destruct in
    # runScript). The build log is uploaded to r2://{logBucket}/logs/ on exit
    # so a failed run is still diagnosable — this path uses only curl/aws over
    # the public internet (like the build's own source fetches), so it works
    # even when the nix daemon or the attic tunnel is the thing that failed.
    # All three written at boot time from cloud-init user-data, same as
    # apiTokenFile.
    r2AccountIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/r2-account-id";
      description = "Path to a file containing the Cloudflare account id (for the R2 endpoint host).";
    };

    r2AccessKeyIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/r2-access-key-id";
      description = "Path to a file containing the R2 access key id.";
    };

    r2SecretAccessKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/r2-secret-access-key";
      description = "Path to a file containing the R2 secret access key.";
    };

    wireguardPrivateKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jupiter-build-server/wireguard-private-key";
      description = ''
        Path this module writes the WireGuard private key to, if
        WIREGUARD_PRIVATE_KEY is present in cloud-init user-data. Not
        consumed by this module itself — a host that also enables
        `jupiter.network.wireguard` should point its `privateKeyFile` at
        this same path (see hosts/pallene/configuration.nix) so the key
        arrives at runtime instead of being baked into the ISO.
      '';
    };

    logBucket = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os-pallene-iso";
      description = "R2 bucket the build log is uploaded to (under logs/).";
    };

    destroyFallbackNote = lib.mkOption {
      type = lib.types.str;
      default = "check the BinaryLane control panel and destroy this server by hand to stop billing.";
      internal = true;
    };

    microarchs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "btver2"
        "skylake"
      ];
      description = ''
        Every distinct `jupiter.build.microarch` value used by the hosts in
        `hosts`. nixpkgs tags CPU-tuned bootstrap derivations (e.g. the
        stage0 glibc/gcc bootstrap) with `requiredSystemFeatures =
        [ "gccarch-<arch>" ]` — a hard Nix-level gate: without the matching
        `gccarch-<arch>` in this builder's own `system-features`, Nix refuses
        to even attempt the build ("missing system features"), regardless of
        whether the CPU could actually run it. Keep in sync by hand with each
        host's `jupiter.build.microarch`. Baked at ISO build time (unlike
        the actual host list) — it gates what the nix DAEMON declares itself
        capable of at boot, before the runScript (and any runtime HOSTS
        override) even runs. Picking a HOSTS value at runtime whose microarch
        isn't declared here just fails that one host fast with "missing
        system features" — cheap, not a wasted multi-hour run.

        Current set: btver2 (europa, Opteron X3216 Puma) + skylake (callisto,
        i5-8500T Coffee Lake — GCC schedules Coffee Lake identically to
        Skylake; the kiosks will reuse the same tag once they adopt tuning).
      '';
    };

    selfDestructCeilingHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        Hard backstop (systemd timer, independent of the run itself): destroy
        this server if it's still alive after this many hours, no matter
        what. This is a SAFETY NET for a genuinely hung run, not the primary
        time control — that's the caller's own polling loop in
        scripts/binarylane-build-server.sh (its TIMEOUT_SECS, a plain env
        var, no ISO rebuild needed to change). Keep this comfortably above
        whatever TIMEOUT_SECS you actually intend to use; if this fires
        first it silently overrides a more generous external timeout, which
        is exactly the bug that killed a genuine multi-hour run at the old
        hardcoded 6h (2026-07-17).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # BinaryLane's API confirmed (docs, 2026-07-18) to accept a user_data
    # field on server creation, carried through to an OS reinstall — but
    # BinaryLane doesn't publicly document which cloud-init datasource
    # actually delivers it (their API shape closely matches DigitalOcean's,
    # whose OWN datasource was deprecated in cloud-init 23.2 in favor of
    # ConfigDrive, so even "it's DO-compatible" doesn't pin this down). This
    # was ALREADY an open, unresolved question in the pre-refactor code (only
    # for the git ref); it's now load-bearing for every runtime parameter,
    # not just one string. Genuinely unverified on a custom-booted ISO as of
    # this refactor — no live BinaryLane run has confirmed it yet.
    #
    # Made cheap to be wrong about: if the datasource isn't reachable here,
    # every runtime parameter falls back to its baked default (ref =
    # defaultRef, hosts = cfg.hosts), and the required-secret-file check
    # right after this block fails FAST (seconds into the run, at the clone
    # step) rather than silently proceeding on stale/empty secrets — turning
    # a wrong bet on this mechanism into a near-free first test, not a
    # wasted multi-hour run.
    services.cloud-init.enable = true;

    # Daemon-level fallback ONLY — a size-agnostic safe default, not a bet on
    # any particular VPS tier. The value that actually governs a real run is
    # the runtime MAX_JOBS/CORES user-data pair (see runScript below), passed
    # as `--max-jobs`/`--cores` flags on the `nix build` invocation itself, on
    # the same override pattern as GIT_REF/HOSTS — because which core/job
    # split is correct depends on which size tier THIS run actually landed on
    # (BinaryLane capacity issues already forced a fallback between
    # different size classes in practice, 2026-07-17), and that's a per-run
    # fact, never an ISO-build-time one.
    #
    # cores = 1, NOT 0, as the fallback. cores=0 tells EACH of the (up to
    # nproc) concurrent top-level jobs "use every core you can get", so nproc
    # jobs each trying to internally -jnproc oversubscribes the box
    # nproc-fold regardless of the box's actual size. Concrete failure this
    # fixes (2026-07-19, run 640829): std-8vcpu, load average settled at ~45
    # against 8 vCPUs, 20GB swapped out of 31GB RAM, and after 45+ minutes of
    # genuine CPU activity not one derivation had finished building
    # (confirmed: /tmp/attic-hook.lock, which the post-build-hook creates
    # unconditionally on its very first invocation, never appeared). cores=1
    # makes each job single-threaded, so max-jobs=auto (~nproc) concurrent
    # single-threaded builds gives full utilization without thrashing — the
    # standard Hydra/build-farm pattern for a dependency graph with many
    # small-to-medium packages rather than one monolithic multi-core compile,
    # and it's the right default for ANY vCPU count, not just this run's.
    nix.settings.max-jobs = "auto";
    nix.settings.cores = 1;

    # REQUIRED: pallene is mkIsoHost (it skips common.nix), so without this
    # the runScript's `nix build .#nixosConfigurations…` dies INSTANTLY with
    # "experimental Nix feature 'nix-command' is disabled" — the run then
    # does nothing (0 CPU) until self-destruct. common.nix sets this for the
    # real hosts; pallene needs it here.
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Without this, europa's btver2-tuned build fails deterministically with
    # "missing system features" on the CPU-tuned bootstrap derivations.
    nix.settings.system-features = lib.mkAfter (map (a: "gccarch-${a}") cfg.microarchs);

    # Pull from our own attic cache ahead of cache.nixos.org. Without this
    # pallene only knows about cache.nixos.org (the NixOS default), so it
    # rebuilds the ENTIRE btver2-tuned bootstrap from source on every run —
    # even a retry where those exact paths already sit in attic from a prior
    # run. mkBefore PREPENDS attic to the default substituter list (so it's
    # tried first) while leaving cache.nixos.org as the fallback for the
    # bootstrap seeds and any path attic doesn't have yet; the attic public
    # key is appended to trusted-public-keys the same way (no need to
    # re-hardcode cache.nixos.org's key — NixOS already provides it).
    nix.settings.substituters = lib.mkBefore [ "${cfg.atticServer}/${cfg.atticCache}" ];
    nix.settings.trusted-public-keys = [ cfg.atticPublicKey ];

    # Large NARs (gcc/binutils/go/llvm-src-class, 100MB+) intermittently stall
    # mid-transfer even over the direct UDM port-forward (2026-07-19, run
    # 640866) — "HTTP error 200 (curl error: Timeout was reached)", i.e. the
    # connection succeeds but throughput drops for a sustained stretch. This
    # isn't unique to the WireGuard mesh (see atticServer's doc above); it
    # persisted after switching off it, so it's a genuine throughput/stall
    # issue somewhere in the path, not just WG software-crypto overhead.
    # nix's defaults (stalled-download-timeout=300s, download-attempts=5;
    # confirmed via `nix show-config` on this same nixpkgs) give up on
    # exactly this kind of large-file blip too readily — the substituter
    # then gets marked disabled and nix rebuilds from source instead,
    # burning far more time than a longer wait or a couple more retries
    # would have. Bumped past the push side's 600s/8 attempts (substitution
    # failures are cheaper to retry than a push batch, since there's nothing
    # to re-enqueue) to actually give a blip a chance to clear before
    # falling back to a from-scratch rebuild.
    nix.settings.stalled-download-timeout = 900;
    nix.settings.download-attempts = 8;

    # Incremental cache push: fire after each derivation builds (see pushHook
    # in the let block). Replaces the old "build the whole closure, then push
    # once at the end" behaviour — the cache now fills during the build, so a
    # run that dies mid-build has still banked everything it completed. The
    # runScript's final `attic push` is retained as a harmless confirmation
    # step (it just re-confirms paths the hook already pushed).
    nix.settings.post-build-hook = "${pushHook}";

    environment.systemPackages = [
      pkgs.git
      pkgs.jq
      pkgs.curl
      pkgs.awscli
      pkgs.attic-client
    ];

    systemd.services.jupiter-build-server = {
      description = "Rebuild europa's tuned closure, push to attic, self-destruct";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "cloud-init.target"
        "cloud-final.service"
      ];
      wants = [
        "network-online.target"
        "cloud-final.service"
      ];
      # cloud-init.target alone was NOT sufficient — observed 2026-07-18, live:
      # this service started before /var/lib/cloud/instance/user-data.txt was
      # actually written, read an empty file, and (worse) then couldn't even
      # self-destruct since its own BinaryLane token came from that same
      # user-data. cloud-final.service is cloud-init's genuinely terminal
      # stage (nixpkgs nixos/modules/services/system/cloud-init.nix: runs
      # after cloud-config.service, which runs after cloud-init.service, the
      # stage that actually fetches/caches user-data) — ordering after the
      # unit itself (which systemd treats as "started" only once its oneshot
      # process exits) instead of just the target closes the race.
      # `path` (not PATH=) puts these on the service's PATH so that `nix build`
      # can find `git` when it re-locks the flake / uses the git+file fetcher on
      # the cloned repo — nix invokes git by name internally, and the default
      # systemd service PATH doesn't include the system profile. Without this
      # the build dies instantly with `executing "git": No such file or directory`.
      path = [
        pkgs.git
        pkgs.nix
        pkgs.jq
        pkgs.awscli
        pkgs.attic-client
        pkgs.util-linux
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${runScript}";
        # Deliberately no Restart= — a failed run should self-destruct and
        # stop, not loop and burn more compute time.
      };
    };

    # Hard safety net independent of the service above: if the main run hangs
    # for any reason (network partition mid-script, attic outage, etc.) this
    # forces a destroy after a generous ceiling regardless of the main
    # service's own state, so a stuck run can never bill indefinitely.
    # cfg.selfDestructCeilingHours, NOT a hardcoded value — this used to be a
    # bare "6h" that silently overrode a more generous external TIMEOUT_SECS,
    # killing a genuine multi-hour run before it could finish (2026-07-17).
    systemd.timers.jupiter-build-server-force-destroy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.selfDestructCeilingHours}h";
        Unit = "jupiter-build-server-force-destroy.service";
      };
    };
    systemd.services.jupiter-build-server-force-destroy = {
      description = "Force-destroy this build server if the main run is still going after ${toString cfg.selfDestructCeilingHours}h";
      serviceConfig.Type = "oneshot";
      # Same robust lookup as self_destruct (list all servers, match ^pallene).
      # The old version used `?hostname=$(hostname)` which never matched the
      # BinaryLane server name (e.g. "pallene.jupiter.au") and silently left
      # stranded servers billing — exactly the bug that stranded the first run.
      script = ''
        resp="$(${bl}/bin/bl-api GET "/v2/servers" 2>/dev/null || true)"
        my_ids="$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.servers[]? | select(.name | test("^pallene")) | .id' 2>/dev/null || true)"
        for my_id in $my_ids; do
          ${bl}/bin/bl-api DELETE "/v2/servers/$my_id?reason=force-destroy+6h+safety+net" || true
        done
      '';
    };
  };
}
