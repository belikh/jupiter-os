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
      # destroy every one matching the disposable `pallene-run-*` pattern.
      # There is normally exactly one (this one); destroying extras is safe,
      # since every pallene-run-* is an ephemeral build server meant to be
      # torn down. The trap below fires on ANY exit (success or failure).
      log "self-destruct: finding pallene-run-* servers to destroy..."
      my_ids=""
      for attempt in 1 2 3 4 5; do
        resp="$(${bl}/bin/bl-api GET "/v2/servers" 2>/dev/null || true)"
        my_ids="$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.servers[]? | select(.name | test("^pallene-run-")) | .id' 2>/dev/null || true)"
        if [ -n "$my_ids" ]; then break; fi
        log "self-destruct attempt $attempt: no pallene-run-* matched (raw: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 180)); retrying in 10s"
        sleep 10
      done
      if [ -z "''${my_ids:-}" ]; then
        log "!! could not find any pallene-run-* server after retries — CANNOT self-destruct." >&2
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
    # Prefer a partition on the data disk (BinaryLane's disk carries a leftover
    # vda1 from the debian-12 placeholder, so mkswap on the whole /dev/vda is
    # refused because a partition table already exists); fall back to the whole
    # disk if there's no partition.
    data_disk="$($ul/bin/lsblk -nbo NAME,TYPE,SIZE 2>/dev/null | awk '$2=="part" {print $1, $3}' | sort -k2 -n | tail -1 | awk '{print $1}')"
    if [ -z "$data_disk" ]; then
      data_disk="$($ul/bin/lsblk -nbo NAME,TYPE,SIZE 2>/dev/null | awk '$2=="disk" {print $1, $3}' | sort -k2 -n | tail -1 | awk '{print $1}')"
    fi
    log "swap setup: swap device=''${data_disk:-<none>}; lsblk: $($ul/bin/lsblk -nbo NAME,TYPE,SIZE 2>/dev/null | tr '\n' ';')"
    if [ -n "$data_disk" ] && [ -b "/dev/$data_disk" ]; then
      if $ul/bin/mkswap "/dev/$data_disk" >/dev/null 2>&1 && $ul/bin/swapon "/dev/$data_disk"; then
        log "swap online on /dev/$data_disk; raising tmpfs size caps so the store + /tmp can spill to it"
        for m in $($ul/bin/findmnt -nbo TARGET,FSTYPE 2>/dev/null | awk '$2=="tmpfs" {print $1}'); do
          $ul/bin/mount -o remount,size=300G "$m" 2>/dev/null || true
        done
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
          log "$host built: $outpath — pushing to attic cache '${cfg.atticCache}'"
          if ! ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" "$outpath"; then
            log "!! attic push failed for $host" >&2
            exit 1
          fi
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

    # Tuned for an 8-thread BinaryLane plan. max-jobs=8/cores=1 favors
    # derivation-level parallelism over per-derivation multithreading: a
    # "rebuild the world" run has multiple hosts' worth of independent (and
    # often shared/deduped) derivations in flight at once, which keeps all 8
    # threads busy far more reliably than a handful of packages each trying
    # to multithread their own build.
    nix.settings.max-jobs = 8;
    nix.settings.cores = 1;

    # REQUIRED: pallene is mkIsoHost (it skips common.nix), so without this
    # the runScript's `nix build .#nixosConfigurations…` dies INSTANTLY with
    # "experimental Nix feature 'nix-command' is disabled" — the run then
    # does nothing (0 CPU) until self-destruct. common.nix sets this for the
    # real hosts; pallene needs it here.
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Without this, europa's btver2-tuned build fails deterministically with
    # "missing system features" on the CPU-tuned bootstrap derivations.
    nix.settings.system-features = lib.mkAfter (map (a: "gccarch-${a}") cfg.microarchs);

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
      description = "Force-destroy this build server if the main run is still going after 4h";
      serviceConfig.Type = "oneshot";
      script = ''
        my_id="$(${bl}/bin/bl-api GET "/v2/servers?hostname=$(hostname)" | ${pkgs.jq}/bin/jq -r '.servers[0].id // empty')"
        [ -n "$my_id" ] && ${bl}/bin/bl-api DELETE "/v2/servers/$my_id?reason=force-destroy+4h+safety+net"
      '';
    };
  };
}
