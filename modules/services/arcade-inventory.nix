# Fleet arcade inventory — europa-side snapshot of the retro game library.
#
# Not an always-on daemon. A 15-minute systemd timer fires a oneshot that
# walks the cartridge tree (per-system ROM counts + du -sb), the three eXo
# curated collections (game vs. box_front line coverage in each
# metadata.pegasus.txt), and the current rom-acquire unit state, then writes
# a single JSON document to the retro state dir. kiosks and operators read
# that file; nothing polls europa.
#
# Optional MQTT publishing: when `publishMqtt` is on, the same JSON is
# `mosquitto_pub`'d (retained) to the callisto broker under
# `jupiter/arcade/#`. Off by default because it needs a sops secret
# (`mqtt_jupiter_arcade`) that the operator must add first. Declaring the
# matching `jupiter-arcade` MQTT user here is inert on europa (the broker
# lives on callisto, so `jupiter.services.mqtt.enable` is false here and the
# whole mqtt config block is skipped) — it documents the ACL the publisher
# needs and activates automatically if this module ever runs on the broker
# host. The secret is declared here too so europa can decrypt it locally and
# feed `mosquitto_pub -P`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.arcadeInventory;

  inventoryRun = pkgs.writeShellScriptBin "jupiter-arcade-inventory-run" ''
    set -uo pipefail

    STATE_FILE="${cfg.stateFile}"
    CARTRIDGE_ROOT="${cfg.cartridgeRoot}"
    EXO_ROOT="${cfg.exoRoot}"
    PUBLISH_MQTT=${lib.boolToString cfg.publishMqtt}
    MQTT_HOST="${cfg.mqttHost}"
    # MQTT_PASSWORD_FILE is handed in via the service environment (conditionally,
    # only when publishMqtt is on) so this script never forces a reference to a
    # sops secret that may not be declared on hosts with publishMqtt=false.
    : "''${MQTT_PASSWORD_FILE:=}"
    ROM_ACQUIRE_UNIT="jupiter-rom-acquire.service"
    SYSTEMS=(${lib.escapeShellArgs cfg.cartridgeSystems})
    EXO_COLLECTIONS=(dos win3x win9x)

    JQ="${pkgs.jq}/bin/jq"
    FIND="${pkgs.findutils}/bin/find"
    GREP="${pkgs.gnugrep}/bin/grep"
    DU="${pkgs.coreutils}/bin/du"
    CUT="${pkgs.coreutils}/bin/cut"
    WC="${pkgs.coreutils}/bin/wc"
    SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    MOSQ="${pkgs.mosquitto}/bin/mosquitto_pub"

    mkdir -p "$(dirname "''${STATE_FILE}")"

    # Full-path posix-extended regex for each known cartridge system.
    pattern_for() {
      case "''$1" in
        nes)  printf '%s' '.*\.nes$' ;;
        snes) printf '%s' '.*\.(sfc|smc)$' ;;
        gb)   printf '%s' '.*\.gb$' ;;
        gbc)  printf '%s' '.*\.gbc$' ;;
        gba)  printf '%s' '.*\.gba$' ;;
        n64)  printf '%s' '.*\.(z64|n64|v64)$' ;;
        *)    : ;; # unknown system → empty pattern, skipped below
      esac
    }

    # --- cartridge systems: per-system ROM count + du -sb ---
    cart='{}'
    for sys in "''${SYSTEMS[@]}"; do
      dir="''${CARTRIDGE_ROOT}/''${sys}"
      pat="''$(pattern_for "''${sys}")"
      count=0
      size=0
      if [ -d "''${dir}" ] && [ -n "''${pat}" ]; then
        count=$("''${FIND}" "''${dir}" -type f -regextype posix-extended -iregex "''${pat}" 2>/dev/null | "''${WC}" -l || echo 0)
        size=$("''${DU}" -sb "''${dir}" 2>/dev/null | "''${CUT}" -f1 || echo 0)
      fi
      cart="$(printf '%s' "''${cart}" | "''${JQ}" \
        --arg k "''${sys}" --argjson n "''${count:-0}" --argjson b "''${size:-0}" \
        '. + {($k): {count:$n, size_bytes:$b}}')"
    done

    # --- eXo curated collections: game vs. box_front coverage ---
    exo='{}'
    for name in "''${EXO_COLLECTIONS[@]}"; do
      meta="''${EXO_ROOT}/exo-''${name}/metadata.pegasus.txt"
      games=0
      art=0
      if [ -f "''${meta}" ]; then
        games=$("''${GREP}" -c '^game: ' "''${meta}" 2>/dev/null || echo 0)
        art=$("''${GREP}" -c '^assets\.box_front: ' "''${meta}" 2>/dev/null || echo 0)
      fi
      exo="$(printf '%s' "''${exo}" | "''${JQ}" \
        --arg k "''${name}" --argjson g "''${games:-0}" --argjson a "''${art:-0}" \
        '. + {($k): {games:$g, art:$a, coverage_pct: (if $g > 0 then (($a/$g*1000)|floor)/10 else 0 end)}}')"
    done

    # --- rom-acquire download unit state ---
    active_state="$("''${SYSTEMCTL}" show -p ActiveState --value "''${ROM_ACQUIRE_UNIT}" 2>/dev/null || true)"
    if [ -z "''${active_state}" ]; then
      active_state="unknown"
    fi

    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp)"
    "''${JQ}" -n \
      --arg generated_at "''${now}" \
      --argjson cartridge "''${cart}" \
      --argjson exo "''${exo}" \
      --arg active_state "''${active_state}" \
      --arg unit "''${ROM_ACQUIRE_UNIT}" \
      '{generated_at:$generated_at,
        cartridge:$cartridge,
        exo:$exo,
        rom_acquire:{unit:$unit, active_state:$active_state}}' > "''${tmp}"
    mv "''${tmp}" "''${STATE_FILE}"
    echo "jupiter-arcade-inventory: wrote ''${STATE_FILE}"

    # --- optional MQTT publish (retained, for HA discovery later) ---
    if [ "''${PUBLISH_MQTT}" = "1" ]; then
      pw="$(cat "''${MQTT_PASSWORD_FILE}" 2>/dev/null || true)"
      if [ -n "''${pw}" ]; then
        "''${MOSQ}" -h "''${MQTT_HOST}" -u jupiter-arcade -P "''${pw}" -r \
          -t jupiter/arcade/inventory -f "''${STATE_FILE}" \
          && echo "jupiter-arcade-inventory: published to ''${MQTT_HOST}" \
          || echo "jupiter-arcade-inventory: MQTT publish failed (non-fatal)"
      else
        echo "jupiter-arcade-inventory: empty MQTT password, skipping publish"
      fi
    fi
  '';
in
{
  options.jupiter.services.arcadeInventory = {
    enable = lib.mkEnableOption "periodic fleet arcade ROM/library inventory JSON generator";

    stateFile = lib.mkOption {
      type = lib.types.path;
      default = "/tank/archive/retro/state/inventory.json";
      description = ''
        Where the generated inventory JSON is written. Kiosks and operators
        read this file (or its MQTT mirror); nothing polls the generator.
      '';
    };

    cartridgeRoot = lib.mkOption {
      type = lib.types.path;
      default = "/tank/archive/retro/games/cartridge";
      description = ''
        Root of the playable cartridge tree. Each enabled system is expected
        at `<cartridgeRoot>/<sys>/` (nes, snes, gb, gbc, gba, n64). Missing
        systems are reported as count 0 / size 0.
      '';
    };

    exoRoot = lib.mkOption {
      type = lib.types.path;
      default = "/tank/archive/retro/games/curated";
      description = ''
        Root holding the eXo curated collections. Each collection is read at
        `<exoRoot>/exo-<name>/metadata.pegasus.txt` (dos, win3x, win9x).
      '';
    };

    cartridgeSystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nes"
        "snes"
        "gb"
        "gbc"
        "gba"
        "n64"
      ];
      description = ''
        Cartridge systems to inventory. Only these six have known ROM
        extensions; an unknown system here yields count 0 / size 0.
      '';
    };

    publishMqtt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the inventory JSON (retained) to the fleet MQTT broker under
        `jupiter/arcade/inventory`. Off by default: it requires the
        `mqtt_jupiter_arcade` sops secret to exist first. When enabled, this
        module also declares the `jupiter-arcade` MQTT user + the sops secret
        (the user entry is inert on europa since the broker runs on callisto,
        but documents the ACL the publisher needs and activates if this
        module runs on the broker host).
      '';
    };

    mqttHost = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.3";
      description = ''
        Broker host the inventory is published to when `publishMqtt` is on.
        Defaults to the callisto broker's static LAN reservation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.mosquitto
      pkgs.jq
    ];

    systemd.services.jupiter-arcade-inventory = {
      description = "Generate the fleet arcade ROM/library inventory JSON";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.mosquitto
        pkgs.systemd
      ];
      # Handed to the script as MQTT_PASSWORD_FILE only when publishing is on,
      # so the default (off) config never references an undeclared sops secret.
      environment = lib.optionalAttrs cfg.publishMqtt {
        MQTT_PASSWORD_FILE = config.sops.secrets.mqtt_jupiter_arcade.path;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${inventoryRun}/bin/jupiter-arcade-inventory-run";
      };
    };

    systemd.timers.jupiter-arcade-inventory = {
      description = "Periodic arcade inventory refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "15m";
        Persistent = true;
      };
    };

    # Sops secret europa decrypts locally to feed `mosquitto_pub -P`. Gated on
    # publishMqtt so the default (off) configuration needs no secret to exist.
    sops.secrets.mqtt_jupiter_arcade = lib.mkIf cfg.publishMqtt { };

    # NOTE: the matching broker-side `jupiter.services.mqtt.users.jupiter-arcade`
    # user + ACL (passwordFile = this same secret, acl = write
    # homeassistant/# + jupiter/arcade/#) is NOT declared here: europa doesn't
    # import the mqtt module (the broker lives on callisto), so the option
    # doesn't exist on this host. Declare that user in the broker host's config
    # (callisto) when flipping publishMqtt on — europa only needs the cleartext
    # password above to authenticate as that user against the remote broker.
  };
}
