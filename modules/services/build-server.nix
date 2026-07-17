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

  # post-build-hook: incremental attic push. After each derivation builds, the
  # nix daemon pipes the newly-built store paths (one per line) to this
  # script's stdin. The WHOLE POINT of the build mesh is that every compiled
  # package lands in attic so a restart substitutes it instead of rebuilding
  # for hours — so this hook must actually cache, not best-effort-ish cache.
  #
  # Two failure modes that previously silently lost packages:
  #  (1) concurrent completions (max-jobs>1) fired the hook in parallel and
  #      the pushes raced on attic — serialized here with flock so only one
  #      push runs at a time.
  #  (2) transient failures (WG blip, attic busy) were swallowed by `|| true`,
  #      losing the path — replaced with a retry+backoff loop that keeps
  #      trying until the path is actually stored, and logs every miss.
  # --ignore-upstream-cache-filter guarantees storage (built paths are
  # btver2-tuned, not on cache.nixos.org, so the filter is a no-op for them
  # — but explicit so no built path is ever silently delegated away).
  # ALWAYS exit 0: a cache miss must never abort the build (the final push +
  # future runs are the backstop). HOME=/root so attic finds the push token.
  pushHook = pkgs.writeShellScript "jupiter-attic-post-build-hook" ''
    export HOME=/root
    set -uo pipefail
    paths="$(cat)" || exit 0
    [ -n "$paths" ] || exit 0
    # Serialize: nix fires one hook per completion; without this, parallel
    # pushes race and some silently drop. One push at a time, reliably.
    exec 9>/tmp/attic-hook.lock
    ${pkgs.util-linux}/bin/flock 9
    for attempt in 1 2 3 4 5 6 7 8; do
      if printf '%s\n' "$paths" | ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" --stdin --ignore-upstream-cache-filter >>/tmp/attic-hook.log 2>&1; then
        exit 0
      fi
      echo "[hook $(date +%H:%M:%S)] attempt $attempt failed; retry in $((attempt*3))s" >>/tmp/attic-hook.log
      sleep $((attempt * 3))
    done
    echo "[hook $(date +%H:%M:%S)] GAVE UP after 8 attempts: $(printf '%s\n' "$paths" | tr '\n' ' ' | head -c 300)" >>/tmp/attic-hook.log
    exit 0
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

    # --- figure out what to build --------------------------------------------
    # BinaryLane's cloud-init datasource (if present) can pass a git ref via
    # user_data at server-create time, so a single ISO build can be reused to
    # build any commit — rebuild the ISO only when this module itself changes.
    ref="${cfg.defaultRef}"
    userdata_file=/var/lib/cloud/instance/user-data.txt
    if [ -r "$userdata_file" ] && [ -s "$userdata_file" ]; then
      ref="$(tr -d '[:space:]' < "$userdata_file")"
      log "using git ref from cloud-init user-data: $ref"
    else
      log "no cloud-init user-data found, defaulting to ref: $ref"
    fi

    workdir="$(mktemp -d)"
    log "cloning ${cfg.repoUrl} @ $ref into $workdir"
    if ! timeout 600 ${pkgs.git}/bin/git clone --depth 1 --branch "$ref" "${cfg.repoUrl}" "$workdir/jupiter-os"; then
      log "!! clone failed, aborting run (self-destruct still fires)" >&2
      exit 1
    fi
    cd "$workdir/jupiter-os"

    # --- attic auth -----------------------------------------------------------
    # Timeout: if attic.jupiter.au is unreachable from this builder the login
    # would otherwise hang for hours (0 CPU) until the 4h force-destroy. A
    # 2-min ceiling turns that into a fast, visible failure → self-destruct.
    if ! timeout 120 ${pkgs.attic-client}/bin/attic login jupiter "${cfg.atticServer}" "$(cat "${cfg.atticPushTokenFile}")"; then
      log "!! attic login failed or timed out (network to ${cfg.atticServer}?) — cannot push, aborting" >&2
      exit 1
    fi

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
    # the SAME nix-daemon — the daemon (tuned below via nix.settings.max-jobs/
    # cores for this box's 8 threads) does the actual scheduling, dedup, and
    # concurrency-limiting across all of them. A single broken host must not
    # stop the rest from being built and pushed, and each host is pushed to
    # attic the moment ITS build finishes rather than waiting on the slowest
    # host — but the overall run should still report failure so CI knows
    # something needs attention.
    pids=()
    for host in ${lib.concatStringsSep " " cfg.hosts}; do
      (
        log "building $host..."
        if ${pkgs.nix}/bin/nix build ".#nixosConfigurations.$host.config.system.build.toplevel" \
             --no-link --print-out-paths > "$workdir/$host.outpath" 2>"$workdir/$host.log"; then
          outpath="$(cat "$workdir/$host.outpath")"
          log "$host built: $outpath"
          # Final push = a backstop sweep of the toplevel closure. The
          # post-build-hook already cached every package as it built; this just
          # catches anything it missed. Retry on failure, and NEVER fail the run
          # on its account — the build succeeded and the hook did the caching.
          # No --ignore-upstream-cache-filter here (unlike the hook): this
          # pushes the whole closure including public cache.nixos.org deps, and
          # the filter correctly delegates those (only stores the btver2 paths).
          ok=0
          for attempt in 1 2 3; do
            if ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" "$outpath" >/dev/null 2>&1; then
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
      # dashboard-v2 has no europa host; point at the branch carrying the
      # hosts in `hosts/` (currently the phase2 branch).
      default = "feat/europa-phase2-tuned-closure";
      description = ''
        Git ref to build when cloud-init user-data is absent. Defaults to the
        active development branch; override via BinaryLane user-data at
        server-create time to build a specific commit without rebuilding the
        ISO.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "europa" ];
      description = ''
        The nixosConfigurations to rebuild and push each run. Only europa is
        microarch-tuned on this branch; untuned hosts substitute from
        cache.nixos.org already, so building them here just wastes compute.
        Add hosts here as they adopt jupiter.build.microarch.
      '';
    };

    apiTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/binarylane-api-token";
      description = ''
        Path to a file containing the BinaryLane API bearer token, used only
        to look up and delete *this* server at the end of the run. Baked into
        the ISO at build time (see hosts/pallene + the Makefile pallene-iso
        target) — there is no persistent host key here for sops-nix to
        decrypt against at runtime.
      '';
    };

    atticServer = lib.mkOption {
      type = lib.types.str;
      default = "https://attic.jupiter.au";
      description = ''
        Base URL of the attic server this builder pushes to. europa's atticd,
        reached over the public internet via the Cloudflare Tunnel
        (modules/services/cloudflare-tunnel.nix).
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
      default = "/etc/jupiter-build-server/attic-push-token";
      description = ''
        Path to a file containing the attic push token. Baked in at ISO build
        time, same as apiTokenFile.
      '';
    };

    # R2 credentials for the robust build-log upload (see self_destruct in
    # runScript). The build log is uploaded to r2://{logBucket}/logs/ on exit
    # so a failed run is still diagnosable — this path uses only curl/aws over
    # the public internet (like the build's own source fetches), so it works
    # even when the nix daemon or the attic tunnel is the thing that failed.
    r2AccountIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/r2-account-id";
      description = "Path to a file containing the Cloudflare account id (for the R2 endpoint host).";
    };

    r2AccessKeyIdFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/r2-access-key-id";
      description = "Path to a file containing the R2 access key id.";
    };

    r2SecretAccessKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/r2-secret-access-key";
      description = "Path to a file containing the R2 secret access key.";
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
      default = [ "btver2" ];
      description = ''
        Every distinct `jupiter.build.microarch` value used by the hosts in
        `hosts`. nixpkgs tags CPU-tuned bootstrap derivations (e.g. the
        stage0 glibc/gcc bootstrap) with `requiredSystemFeatures =
        [ "gccarch-<arch>" ]` — a hard Nix-level gate: without the matching
        `gccarch-<arch>` in this builder's own `system-features`, Nix refuses
        to even attempt the build ("missing system features"), regardless of
        whether the CPU could actually run it. Keep in sync by hand with each
        host's `jupiter.build.microarch`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # BinaryLane's platform provides a cloud-init datasource for their catalog
    # images; assuming it's also available to a custom-booted ISO lets CI pass
    # the target git ref via user_data without rebuilding the ISO per commit.
    # UNVERIFIED on custom ISOs (open question Q1 in the Phase 2 plan) — if it
    # doesn't work, the ref falls back to defaultRef baked above.
    services.cloud-init.enable = true;

    # Tuned for an 8-thread BinaryLane plan. max-jobs=4/cores=4 (jobs×cores=16,
    # ~2x the 8 physical cores) is a deliberate middle ground:
    #  - The stdenv bootstrap (glibc → gcc's 3 self-stages → final stdenv) is the
    #    long pole and is DAG-narrow — often only 1-3 derivations ready at once.
    #    cores=4 lets gcc/glibc run `make -j4`, which is ~3x faster than -j1 and
    #    is where most of the wall-clock goes. With cores=1 (the old setting)
    #    gcc built single-threaded and the bootstrap crawled (load ~1.0).
    #  - Later, when the DAG widens to hundreds of packages, max-jobs=4 keeps
    #    4 in flight; small derivations don't use all 4 cores, so the 2x
    #    theoretical oversubscription only bites briefly when 4 big C++ builds
    #    coincide (~15-25% context-switch overhead, not catastrophic).
    nix.settings.max-jobs = 4;
    nix.settings.cores = 4;

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
      ];
      wants = [ "network-online.target" ];
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
    systemd.timers.jupiter-build-server-force-destroy = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "6h";
        Unit = "jupiter-build-server-force-destroy.service";
      };
    };
    systemd.services.jupiter-build-server-force-destroy = {
      description = "Force-destroy this build server if the main run is still going after 6h";
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
