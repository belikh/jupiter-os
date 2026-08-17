{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.core.crush;

  # Pinned straight to upstream's GitHub release tag, same approach as
  # modules/core/ecc.nix — nixpkgs' own `crush` derivation lags upstream
  # releases (0.81.0 in nixpkgs vs 0.87.0 here as of 2026-07-26). Bump by
  # editing version/sha256/vendorHash (recompute vendorHash with
  # lib.fakeHash + a build, same as any Go package). `crush-go` is the flake
  # root's nixpkgs-unstable overlay — this release's go.mod needs a newer Go
  # than the fleet's pinned nixpkgs ships.
  crush = pkgs.buildGoModule.override { go = pkgs.crush-go; } rec {
    pname = "crush";
    version = "0.87.0";

    src = pkgs.fetchFromGitHub {
      owner = "charmbracelet";
      repo = "crush";
      rev = "v${version}";
      sha256 = "08qvn9snnp14139h2c8d3mxvwl46ar72rxk9lsbpw4ci4jmpw7rz";
    };

    vendorHash = "sha256-HGsySgR+J2Pm4rodcToS9fPYF8UWIVAgUbdnStBh6DQ=";

    # Same rationale as nixpkgs' own crush derivation's doCheck=false
    # candidates would need: skip the test suite for a personal-fleet
    # package rather than chase which subset is safe under sandboxed builds.
    doCheck = false;

    ldflags = [
      "-s"
      "-X=github.com/charmbracelet/crush/internal/version.Version=${version}"
    ];

    meta = with lib; {
      description = "Glamourous AI coding agent for your favourite terminal";
      homepage = "https://github.com/charmbracelet/crush";
      # FSL-1.1 (converts to MIT ~2 years after each release) — same
      # unfree-until-conversion license nixpkgs' own crush derivation
      # carries. common.nix already sets nixpkgs.config.allowUnfree = true
      # fleet-wide, so this doesn't need its own allowUnfreePredicate entry.
      license = licenses.fsl11Mit;
      mainProgram = "crush";
    };
  };

  # Same z.ai coding-plan provider as modules/core/zed.nix's zed-wrapped.
  # Groq is a second cloud provider (fast Llama/Kimi hosting) alongside it.
  #
  # The fleet model server (modules/services/llama-server.nix) is wired up as
  # a `llamacpp` provider on EVERY host that enables crush. jupiter.services.llm.clientUrl
  # defaults to the local llama-server when one runs here; common.nix sets it
  # fleet-wide to callisto's static LAN address for hosts that only consume
  # the shared server. Crush auto-discovers /v1/models from that endpoint
  # (discover_models defaults to true and the provider carries no explicit
  # models list), so Qwen3-Coder shows up in Crush's model picker alongside
  # GLM-4.6 without hard-coding the GGUF here.
  # The z.ai endpoint + GLM-4.6 constants are shared with zed.nix's
  # language_models block (same account); schemas are tool-specific so they
  # are NOT merged — keep the URLs/model names in sync by hand.
  crushSettings = pkgs.writeText "crush.json" (
    builtins.toJSON {
      "$schema" = "https://charm.land/crush.json";
      providers = {
        "z-ai" = {
          type = "openai";
          base_url = "https://api.z.ai/api/coding/paas/v4";
          api_key = "$Z_AI_API_KEY";
          models = [
            {
              id = "glm-4.6";
              name = "GLM-4.6";
              context_window = 200000;
              default_max_tokens = 128000;
            }
          ];
        };
        "qwen-local" = {
          type = "llamacpp";
          name = "Qwen3-Coder (local)";
          base_url = config.jupiter.services.llm.clientUrl;
        };
        "groq" = {
          type = "openai";
          base_url = "https://api.groq.com/openai/v1";
          api_key = "$GROQ_API_KEY";
        };
      };
    }
  );

  # crush expands $VAR references in its config at runtime, but still needs
  # the var present in its environment — wrap it the same way zed-wrapped
  # sources the sops secret instead of requiring a manual `crush auth` paste.
  crush-wrapped = pkgs.writeShellScriptBin "crush" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key.path})"
    exec ${crush}/bin/crush "$@"
  '';
in
{
  options.jupiter.core.crush = {
    enable = lib.mkEnableOption "Crush terminal AI coding agent, preconfigured with the Z.ai coding-plan provider";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ crush-wrapped ];

    sops.secrets.zai_api_key = {
      owner = "io";
      mode = "0400";
    };

    sops.secrets.groq_api_key = {
      owner = "io";
      mode = "0400";
    };

    # ~/.config is already persisted for io (modules/core/impermanence.nix).
    # Re-synced on every activation, so the committed config always wins
    # over local edits made through `crush` itself.
    system.activationScripts.crushSettings = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${crushSettings} /home/io/.config/crush/crush.json
    '';
  };
}
