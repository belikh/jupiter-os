{
  config,
  lib,
  pkgs,
  ...
}:

# The disposable BinaryLane "rebuild the world" build server — see
# docs/roadmap.md's "Ephemeral BinaryLane build server" section for the full
# design and the reasoning behind each choice below. In one sentence: boots
# from a minimal custom ISO (hosts/pallene), rebuilds every fleet host's
# closure (each tuned for that host's own CPU via jupiter.build.microarch),
# pushes the results to the attic cache, then deletes itself via the
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

    log() { echo "[jupiter-build-server] $*"; }

    # --- self-destruct, unconditionally, no matter what happens above -------
    # This is the "so we don't waste money" guarantee: it runs on ANY exit
    # path (success, build failure, script bug) via the trap below, not just
    # the happy path.
    self_destruct() {
      log "self-destruct: looking up this server's id by hostname..."
      my_id="$(${bl}/bin/bl-api GET "/v2/servers?hostname=$(hostname)" \
        | ${pkgs.jq}/bin/jq -r '.servers[0].id // empty')"
      if [ -z "''${my_id:-}" ]; then
        log "!! could not determine own server id — CANNOT self-destruct." >&2
        log "!! ${cfg.destroyFallbackNote}" >&2
        return 1
      fi
      log "destroying server id=$my_id (reason: rebuild-the-world run complete)"
      ${bl}/bin/bl-api DELETE "/v2/servers/$my_id?reason=rebuild-the-world+run+complete" \
        || log "!! destroy call failed — ${cfg.destroyFallbackNote}" >&2
    }
    trap self_destruct EXIT

    # --- figure out what to build --------------------------------------------
    # BinaryLane's cloud-init datasource (if present) can pass a git ref via
    # user_data at server-create time, so a single ISO build can be reused to
    # build any commit — rebuild the ISO only when this module itself changes.
    ref="master"
    userdata_file=/var/lib/cloud/instance/user-data.txt
    if [ -r "$userdata_file" ] && [ -s "$userdata_file" ]; then
      ref="$(tr -d '[:space:]' < "$userdata_file")"
      log "using git ref from cloud-init user-data: $ref"
    else
      log "no cloud-init user-data found, defaulting to ref: $ref"
    fi

    workdir="$(mktemp -d)"
    log "cloning ${cfg.repoUrl} @ $ref into $workdir"
    if ! ${pkgs.git}/bin/git clone --depth 1 --branch "$ref" "${cfg.repoUrl}" "$workdir/jupiter-os"; then
      log "!! clone failed, aborting run (self-destruct still fires)" >&2
      exit 1
    fi
    cd "$workdir/jupiter-os"

    # --- attic auth -----------------------------------------------------------
    ${pkgs.attic-client}/bin/attic login jupiter "${cfg.atticServer}" "$(cat "${cfg.atticPushTokenFile}")"

    # --- rebuild the world, one host at a time, best-effort ------------------
    # A single broken host must not stop the rest from being pushed, but the
    # overall run should still report failure so CI knows something needs
    # attention.
    overall_status=0
    for host in ${lib.concatStringsSep " " cfg.hosts}; do
      log "building $host..."
      if ${pkgs.nix}/bin/nix build ".#nixosConfigurations.$host.config.system.build.toplevel" \
           --no-link --print-out-paths > "$workdir/$host.outpath" 2>"$workdir/$host.log"; then
        outpath="$(cat "$workdir/$host.outpath")"
        log "$host built: $outpath — pushing to attic cache '${cfg.atticCache}'"
        if ! ${pkgs.attic-client}/bin/attic push "${cfg.atticCache}" "$outpath"; then
          log "!! attic push failed for $host" >&2
          overall_status=1
        fi
      else
        log "!! build failed for $host — see $workdir/$host.log" >&2
        tail -n 40 "$workdir/$host.log" >&2 || true
        overall_status=1
      fi
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

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ganymede"
        "himalia"
        "europa"
        "metis"
        "adrastea"
        "amalthea"
        "thebe"
        "callisto"
        "elara"
        "carme"
      ];
      description = ''
        The nixosConfigurations to rebuild and push each run. Defaults to
        every currently-registered fleet host (excluding pallene itself).
      '';
    };

    apiTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/binarylane-api-token";
      description = ''
        Path to a file containing the BinaryLane API bearer token, used only
        to look up and delete *this* server at the end of the run. Baked into
        the ISO at build time the same way `make build-mx4300` injects
        secrets (see the Makefile `pallene-iso` target and
        docs/roadmap.md) — there is no persistent host key here for
        sops-nix to decrypt against at runtime.
      '';
    };

    atticServer = lib.mkOption {
      type = lib.types.str;
      example = "https://attic.home.jupiter.au";
      description = "Base URL of the attic server hosts pull the binary cache from.";
    };

    atticCache = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os";
      description = "Name of the attic cache to push built closures into.";
    };

    atticPushTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/jupiter-build-server/attic-push-token";
      description = "Path to a file containing the attic push token. Baked in at ISO build time, same as apiTokenFile.";
    };

    destroyFallbackNote = lib.mkOption {
      type = lib.types.str;
      default = "check the BinaryLane control panel and destroy this server by hand to stop billing.";
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    # BinaryLane's platform provides a cloud-init datasource for their catalog
    # images; assuming it's also available to a custom-booted ISO lets CI pass
    # the target git ref via user_data without rebuilding the ISO per commit.
    # UNVERIFIED — confirm this actually works against a real BinaryLane VPS
    # before relying on it; if it doesn't, fall back to baking the ref into
    # the ISO at build time instead (same mechanism as the secret files above).
    services.cloud-init.enable = true;

    environment.systemPackages = [
      pkgs.git
      pkgs.jq
      pkgs.curl
      pkgs.attic-client
    ];

    systemd.services.jupiter-build-server = {
      description = "Rebuild every fleet host's closure, push to attic, self-destruct";
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
        OnBootSec = "4h";
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
