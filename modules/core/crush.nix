{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.core.crush;

  # Same z.ai coding-plan provider as modules/core/zed.nix's zed-wrapped —
  # it's the only LLM API key in secrets/secrets.yaml.
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
      };
    }
  );

  # crush expands $VAR references in its config at runtime, but still needs
  # the var present in its environment — wrap it the same way zed-wrapped
  # sources the sops secret instead of requiring a manual `crush auth` paste.
  crush-wrapped = pkgs.writeShellScriptBin "crush" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    exec ${pkgs.crush}/bin/crush "$@"
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

    # ~/.config is already persisted for io (modules/core/impermanence.nix).
    # Re-synced on every activation, so the committed config always wins
    # over local edits made through `crush` itself.
    system.activationScripts.crushSettings = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${crushSettings} /home/io/.config/crush/crush.json
    '';
  };
}
