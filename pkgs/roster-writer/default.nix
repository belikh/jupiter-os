{
  lib,
  buildGoModule,
}:

# roster-writer — the ISS/Kronos roster sole-writer (spec §8.1/§8.2).
#
# Takes over n8n's "Roster to Home Assistant" + "Shift Change Watchdog" roles:
# fetch the iCal feed on a bounded interval, parse it exactly as the n8n
# workflows did (parity is contractual — see PARITY.md), write the canonical
# roster tables in the fleet Postgres (public.shift_roster / shift_history /
# shift_change_log / roster_feed_state), and publish the retained MQTT
# contract HA consumes (jupiter/schedule/shift/* + HA discovery).
#
# Built from the in-tree source (main.go, roster.go, mqtt.go, *_test.go,
# go.mod + vendor/). Consumed by modules/services/roster-writer.nix via
# pkgs.callPackage; standalone verification: `nix build .#roster-writer`.
#
# vendor/ is in-tree (go mod tidy && go mod vendor), so vendorHash = null and
# builds run fully offline — the suno-top convention.
buildGoModule {
  pname = "roster-writer";
  version = "0.1.0";

  src = ./.;

  vendorHash = null; # vendor/ is in-tree

  ldflags = [ "-s" ];

  doCheck = true; # pure unit tests (fixture-driven; no network)

  meta = with lib; {
    description = "Kronos roster sole-writer → fleet Postgres + retained MQTT contract";
    mainProgram = "roster-writer";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
