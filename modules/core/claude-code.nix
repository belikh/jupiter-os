{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.core.claudeCode;
in
{
  options.jupiter.core.claudeCode = {
    enable = lib.mkEnableOption ''
      Claude Code — Anthropic's terminal coding agent (the `claude` CLI).

      Installs nixpkgs' `claude-code` package, which downloads Anthropic's
      native binary from its CDN (pinned by sha256) with auto-updates disabled,
      so upgrades flow through Nix rather than self-modification. It is a
      self-contained Bun binary needing no Node.js runtime and works on stock
      NixOS.

      The release is pinned by the sibling `claude-code-manifest.zst.json`
      rather than by the nixpkgs pin, so Claude Code can track Anthropic's
      weekly releases without bumping nixpkgs fleet-wide. This is a
      single-package override (the package's own `manifest` argument), not an
      overlay — see the buildability rules in CLAUDE.md. To upgrade:

          V=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)
          curl -fsSL "https://downloads.claude.ai/claude-code-releases/$V/manifest.zst.json" \
            -o modules/core/claude-code-manifest.zst.json

      Authentication is per-user and not provisioned here: run `claude
      setup-token` (OAuth) or export `ANTHROPIC_API_KEY` in your shell after
      enabling this option.
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.claude-code.override { manifest = lib.importJSON ./claude-code-manifest.zst.json; })
    ];
  };
}
