{ lib, modulesPath, ... }:

let
  # secrets/pallene-secrets/*.placeholder are committed dummy files so
  # `nix flake check`/`nix build` always have something to reference (a Nix
  # path literal must exist on disk at eval time). `make pallene-iso`
  # materializes the real (gitignored) plaintext files from sops right before
  # building and deletes them right after — see that Makefile target.
  realOrPlaceholder =
    name:
    let
      real = ../../secrets/pallene-secrets + "/${name}";
      placeholder = ../../secrets/pallene-secrets + "/${name}.placeholder";
    in
    if builtins.pathExists real then real else placeholder;
in

# EPHEMERAL BUILD SERVER — see docs/roadmap.md's "Ephemeral BinaryLane build
# server" section for the full workflow this exists to run. Never a
# persistent fleet member: BinaryLane boots a disposable VPS from the ISO
# built from this config (`nix build .#pallene-iso`), it automatically
# rebuilds every host's closure (see modules/services/build-server.nix),
# pushes the results to the attic cache, then deletes itself. No storage
# profile, no impermanence, no backup, no branding, no desktop — as minimal
# as the stock installer media allows, plus the one module that does the
# actual work.
#
# Named after a small, distant Jupiter moon, matching this fleet's naming
# convention — fitting for a host that's only ever briefly in orbit.
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    ../../modules/services/build-server.nix
  ];

  networking.hostName = "pallene";

  jupiter.services.buildServer = {
    enable = true;
    # TODO once the attic server is actually stood up (see docs/roadmap.md):
    atticServer = "https://attic.home.jupiter.au";
  };

  # There's no persistent host key here for sops-nix to decrypt against at
  # runtime (this box never survives past one run), so the two secrets the
  # build-server module needs are instead baked into the ISO's Nix store at
  # BUILD time, the same way `make build-mx4300` injects OpenWrt secrets.
  # `make pallene-iso` materializes these plaintext files from sops
  # immediately before the build and deletes them immediately after — do not
  # run `nix build .#pallene-iso` directly, use the Makefile target.
  environment.etc = {
    "jupiter-build-server/binarylane-api-token" = {
      source = realOrPlaceholder "binarylane-api-token";
      mode = "0400";
    };
    "jupiter-build-server/attic-push-token" = {
      source = realOrPlaceholder "attic-push-token";
      mode = "0400";
    };
  };

  # No exposure to chaotic-nyx's cache/overlay/registry needed here — this
  # host never builds anything gaming/CachyOS-related itself, it just invokes
  # `nix build` against the cloned repo's own flake (mirrors europa's
  # reasoning in hosts/europa/configuration.nix).
  chaotic.nyx.cache.enable = false;
  chaotic.nyx.overlay.enable = false;
  chaotic.nyx.registry.enable = false;
}
