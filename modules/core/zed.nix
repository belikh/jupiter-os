{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.core.zed;

  zedSettings = pkgs.writeText "zed-settings.json" (
    builtins.toJSON {
      language_models = {
        openai_compatible = {
          "z-ai" = {
            api_url = "https://api.z.ai/api/coding/paas/v4";
            available_models = [
              {
                name = "glm-4.6";
                display_name = "GLM-4.6";
                max_tokens = 200000;
                max_output_tokens = 128000;
                max_completion_tokens = 128000;
                capabilities = {
                  tools = true;
                  images = false;
                  parallel_tool_calls = true;
                  prompt_cache_key = true;
                };
              }
            ];
          };
        };
      };
      agent = {
        default_model = {
          provider = "z-ai";
          model = "glm-4.6";
        };
      };
    }
  );

  # Zed's docs explicitly say never put API keys in settings.json — custom
  # openai_compatible providers pick up credentials from an env var named
  # <PROVIDER_ID>_API_KEY (uppercased, hyphens to underscores), which takes
  # precedence over its keychain-backed "Add Provider" UI flow. Wrapping the
  # binary lets the key come from the sops secret instead of a manual paste.
  zed-wrapped = pkgs.writeShellScriptBin "zed" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    exec ${pkgs.zed-editor}/bin/zeditor "$@"
  '';
in
{
  options.jupiter.core.zed = {
    enable = lib.mkEnableOption "Zed editor, preconfigured with the Z.ai coding-plan provider";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ zed-wrapped ];

    sops.secrets.zai_api_key = {
      owner = "io";
      mode = "0400";
    };

    # ~/.config is already persisted for io (modules/core/impermanence.nix),
    # so this survives reboots. Re-synced on every activation, so the
    # committed config always wins over local edits made through Zed's UI.
    system.activationScripts.zedSettings = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${zedSettings} /home/io/.config/zed/settings.json
    '';
  };
}
