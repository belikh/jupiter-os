{
  config,
  lib,
  pkgs,
  ...
}:

# External backstop for the ephemeral BinaryLane "pallene" build server
# (modules/services/build-server.nix). That module already self-destructs on
# every exit path via a bash EXIT trap, plus its own in-VM 6h force-destroy
# timer — but both live *inside* pallene, so neither covers:
#   (1) a SIGKILL (the OOM killer, which the branch's own testing triggered
#       under the full btver2 bootstrap) skips bash's EXIT trap entirely;
#   (2) a stale/rotated BinaryLane token baked into an old ISO can't destroy
#       anything no matter how the in-VM logic retries.
# This runs on europa instead: a different host, polling on a short interval,
# using a token sourced fresh from sops rather than the ISO-baked copy.
#
# BinaryLane's server-list response schema isn't relied on for an age field
# (unverified from here) — instead this tracks "first seen by this watchdog"
# per server id in local state, which needs nothing from the API but the
# id/name every response is guaranteed to carry.

let
  cfg = config.jupiter.services.palleneWatchdog;

  watchdogRun = pkgs.writeShellScriptBin "pallene-watchdog-run" ''
    set -uo pipefail
    state_file="/var/lib/pallene-watchdog/state"
    touch "$state_file"
    token="$(cat "${cfg.apiTokenFile}")"
    now="$(date -u +%s)"

    resp="$(${pkgs.curl}/bin/curl -sS -X GET "https://api.binarylane.com.au/v2/servers" \
      -H "Authorization: Bearer $token")" || {
      echo "pallene-watchdog: BinaryLane API unreachable this run, skipping"
      exit 0
    }

    live_ids="$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.servers[]? | select(.name | test("^pallene")) | .id' 2>/dev/null || true)"

    new_state="$(mktemp)"
    for id in $live_ids; do
      name="$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r --arg id "$id" '.servers[] | select(.id == ($id | tonumber)) | .name' 2>/dev/null || echo "pallene")"
      first_seen="$(${pkgs.gawk}/bin/awk -v id="$id" '$1 == id { print $2; exit }' "$state_file")"
      if [ -z "$first_seen" ]; then
        first_seen="$now"
        echo "pallene-watchdog: first seen $name (id=$id)"
      fi
      age_hours=$(( (now - first_seen) / 3600 ))
      if [ "$age_hours" -ge "${toString cfg.maxAgeHours}" ]; then
        echo "pallene-watchdog: $name (id=$id) is ''${age_hours}h old (>= ${toString cfg.maxAgeHours}h budget) - destroying"
        ${pkgs.curl}/bin/curl -sS -X DELETE \
          "https://api.binarylane.com.au/v2/servers/$id?reason=pallene-watchdog+external+backstop" \
          -H "Authorization: Bearer $token" \
          && echo "pallene-watchdog: destroy call sent for $id" \
          || echo "pallene-watchdog: !! destroy call failed for $id, will retry next run"
        # Keep tracking it (don't drop from state) until it stops appearing
        # in the live list, in case the destroy call above needs a retry.
        echo "$id $first_seen" >> "$new_state"
      else
        echo "pallene-watchdog: $name (id=$id) is ''${age_hours}h old - within budget"
        echo "$id $first_seen" >> "$new_state"
      fi
    done
    mv "$new_state" "$state_file"
  '';
in
{
  options.jupiter.services.palleneWatchdog = {
    enable = lib.mkEnableOption "external BinaryLane backstop that kills stale pallene* build servers";

    apiTokenFile = lib.mkOption {
      type = lib.types.path;
      default = config.sops.secrets.binarylane_api_token.path;
      description = ''
        Path to the decrypted BinaryLane API token, sourced fresh from sops
        on europa rather than the copy baked into the pallene ISO by
        `make pallene-iso` — so a rotated token that hasn't made it into a
        fresh ISO build yet doesn't also blind this watchdog.
      '';
    };

    maxAgeHours = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        Destroy any BinaryLane server named `pallene*` once this watchdog
        has observed it for this many hours. Deliberately tighter than
        build-server.nix's own in-VM 6h force-destroy timer: real
        rebuild-the-world runs have taken up to ~3h in practice (full
        btver2 bootstrap), so 4h leaves headroom for a genuine run while
        still bounding the cost of a stuck one — and this covers the two
        gaps the in-VM timer can't (a SIGKILL skips bash's EXIT trap; a
        stale token baked into an old ISO can't self-destroy at all).
      '';
    };

    checkIntervalMinutes = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = "How often to poll the BinaryLane API for stale pallene* servers.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.binarylane_api_token = { };

    systemd.services.pallene-watchdog = {
      description = "Destroy any BinaryLane pallene* build server older than the watchdog budget";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchdogRun}/bin/pallene-watchdog-run";
        StateDirectory = "pallene-watchdog";
      };
    };

    systemd.timers.pallene-watchdog = {
      description = "Periodic pallene-watchdog run";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "${toString cfg.checkIntervalMinutes}m";
      };
    };
  };
}
