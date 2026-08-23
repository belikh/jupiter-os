{
  config,
  lib,
  ...
}:

# THE console-system catalogue — the single source of truth for every fact
# about the jupiterOS Arcade's console systems: scripts/cartridge-catalogue.tsv.
# This module parses that file into the jupiter.arcade.catalogue option;
# today's consumers are the kiosk mounts (modules/desktop/cartridges.nix)
# and the arcade webapp, which embeds the same TSV (its Go scanner parses
# the identical row semantics).
#
# Historically this data lived in FIVE hand-copied places and DID drift (a
# 'acorn' system once existed only in one consumer script: it would have
# promoted to the pool invisible — never scraped, mounted, inventoried or
# launchable). Now adding/removing a system is ONE TSV row and everything
# follows.
#
# Fact columns (see the TSV header for the full contract):
#   collection  Pegasus collection display title
#   bucket      which europa dataset (NFS export + recordsize) it lives on
#   core        libretro core basename ('jupiter-retroarch -L <core>')
#   emulator    standalone emulator when core is null (currently only Wii U)
#   extensions  ROM file extensions (drives inventory patterns; their
#               union + zip + bin was cartridge-scrape.sh's global ROM regex,
#               now scripts/deprecated/)
#   skyHandle   Skyscraper -p platform handle when it differs from the key
#   torrent     Minerva/Myrient torrent basename for bulk acquisition
#
# BIOS notes for the cores live in modules/desktop/cartridges.nix's header.
let
  # "-" is the TSV's "not applicable" marker.
  orNull = v: if v == "-" then null else v;

  raw = lib.splitString "\n" (builtins.readFile ../../scripts/cartridge-catalogue.tsv);
  # Trim each line and filter out empty/comment lines. Handles missing trailing newline.
  dataLines = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (map lib.trim raw);

  # system collection core emulator extensions sky bucket torrent
  row = builtins.match "([^\t]+)	([^	]+)	([^	]+)	([^	]+)	([^	]+)	([^	]+)	([^	]+)	(.*)";

  parseLine =
    line:
    let
      m = row line;
    in
    if m == null then
      abort "arcade-catalogue: unparseable TSV row: ${line}"
    else
      {
        name = builtins.elemAt m 0;
        value = {
          collection = builtins.elemAt m 1;
          core = orNull (builtins.elemAt m 2);
          emulator = orNull (builtins.elemAt m 3);
          extensions = lib.splitString "," (builtins.elemAt m 4);
          skyHandle = orNull (builtins.elemAt m 5);
          bucket = builtins.elemAt m 6;
          torrent = orNull (builtins.elemAt m 7);
        };
      };
in
{
  options.jupiter.arcade = {
    catalogue = lib.mkOption {
      type =
        let
          system = lib.types.submodule {
            options = {
              collection = lib.mkOption { type = lib.types.str; };
              bucket = lib.mkOption {
                type = lib.types.enum [
                  "cartridge"
                  "optical"
                  "modern"
                ];
              };
              core = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              emulator = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              extensions = lib.mkOption { type = lib.types.listOf lib.types.str; };
              skyHandle = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              torrent = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          };
        in
        lib.types.attrsOf system;
      readOnly = true;
      description = ''
        The fleet console-system catalogue, parsed from
        scripts/cartridge-catalogue.tsv (see that file's header). Edit the
        TSV, never a consumer.
      '';
    };

    # Extensions that appear in cartridge-scrape.sh's GLOBAL ROM regex but in
    # no per-system pattern: No-Intro cartridge sets ship as .zip archives, and
    # cue/bin pairs travel together.
    extraGlobalExtensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "ROM extensions for the global scrape regex beyond the per-system union.";
    };
  };

  config.jupiter.arcade = {
    catalogue = builtins.listToAttrs (map parseLine dataLines);
    extraGlobalExtensions = [
      "zip"
      "bin"
    ];
  };
}
