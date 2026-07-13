{
  lib,
  modulesPath,
  ...
}:

let
  # secrets/pallene-secrets/*.placeholder are committed dummy files so
  # `nix flake check` / `nix build` always have something to reference (a Nix
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

# EPHEMERAL BUILD SERVER. Never a persistent fleet member: BinaryLane boots a
# disposable VPS from the ISO built from this config (`make pallene-iso`), it
# automatically rebuilds europa's tuned closure (see
# modules/services/build-server.nix), pushes the result to the attic cache,
# then deletes itself. No storage profile, no impermanence, no backup, no
# branding, no desktop — as minimal as the stock installer media allows, plus
# the one module that does the actual work.
#
# Registered via flake.nix's mkIsoHost (not mkHost) so the common flake-module
# injection (sops-nix, impermanence, disko, ha-linux-agent) is skipped — this
# box never survives past one run and has no persistent host key to decrypt
# against. Named after a small, distant Jupiter moon, matching this fleet's
# convention — fitting for a host only briefly in orbit.
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    ../../modules/services/build-server.nix
  ];

  networking.hostName = "pallene";

  jupiter.services.buildServer = {
    enable = true;
    # europa's atticd (modules/services/attic-server.nix), reached over the
    # public internet via the Cloudflare Tunnel.
    atticServer = "https://attic.jupiter.au";
  };

  # There's no persistent host key here for sops-nix to decrypt against at
  # runtime (this box never survives past one run), so the two secrets the
  # build-server module needs are instead baked into the ISO's Nix store at
  # BUILD time. `make pallene-iso` materializes these plaintext files from
  # sops immediately before the build and deletes them immediately after — do
  # not run `nix build .#pallene-iso` directly, use the Makefile target.
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
}
