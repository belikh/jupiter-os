{
  config,
  lib,
  pkgs,
  ...
}:

# remote-opencode — Discord bot bridging this host's opencode rig to Discord
# slash commands (github.com/bevibing/remote-opencode, packaged in
# pkgs/discord-opencode-bridge). Phase-2 item from
# docs/plans/2026-08-24-001-callisto-opencode-rig-deployment.md §11, pulled
# forward at io's request 2026-08-26 (Node 24 was already committed for it).
#
# Design notes:
#   - Runs AS IO (plan §11's explicit choice — the bot drives io's own
#     ~/.opencode rig, projects and sessions; a dedicated user would share
#     nothing with it). It spawns `opencode` children itself, so the unit
#     PATH leads with /run/current-system/sw: that resolves `opencode` to
#     modules/core/opencode.nix's wrapped launcher, which injects the sops
#     provider keys (Z_AI/GROQ/OPENCODE) into every spawned session — the
#     dsh.nix PATH lesson applied end-to-end.
#   - Credentials live in ONE packed sops secret (`discord_bridge_env`,
#     KEY=value lines, restic_env/dsh_env pattern):
#       DISCORD_TOKEN / CLIENT_ID / GUILD_ID / ALLOWED_USER_IDS
#     The token must NEVER land in chat, git or the store: preStart renders
#     ~/.remote-opencode/config.json (upstream's expected location, 0600)
#     fresh from the secret at every start, so rotating the sops value +
#     restarting is the whole rotation story.
#   - ALLOWED_USER_IDS is comma-separated Discord user ids. Upstream treats
#     an EMPTY allowlist as "anyone in the guild may run commands on this
#     host" — keep at least io's own id in there.
#   - First-run slash-command deployment: upstream's setup wizard registers
#     the commands against the guild once. Headless equivalent, run once as
#     io after the first successful start (config.json then exists):
#       ~/.nix-profile/... no — simply: `remote-opencode` CLI from this
#       package exposes deploy via `remote-opencode setup`; if a future
#       upstream adds `deploy` as a standalone subcommand, prefer it.
#   - Hardening deliberately light (no ProtectHome/ProtectSystem strict):
#     the unit IS io's agent surface — it must read /home/io/.opencode,
#     write ~/.remote-opencode and ~/.config, and spawn compilers/git in
#     project dirs, exactly like dsh's rationale for its own exceptions.
let
  cfg = config.jupiter.services.discordOpencodeBridge;

  bridgePkg = pkgs.callPackage ../../pkgs/discord-opencode-bridge { };

  # Render upstream's config.json out of the packed sops env file. jq builds
  # the JSON so values are quoted/escaped properly and never echoed.
  renderConfig = pkgs.writeShellScript "remote-opencode-render-config" ''
    set -euo pipefail
    envFile="${config.sops.secrets.discord_bridge_env.path}"
    get() { sed -n "s/^$1=//p" "$envFile"; }
    cfgDir="$HOME/.remote-opencode"
    mkdir -p "$cfgDir"
    allowed="$(${pkgs.jq}/bin/jq -Rn \
      --arg raw "$(get ALLOWED_USER_IDS)" \
      '$raw | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
    ${pkgs.jq}/bin/jq -n \
      --arg discordToken "$(get DISCORD_TOKEN)" \
      --arg clientId "$(get CLIENT_ID)" \
      --arg guildId "$(get GUILD_ID)" \
      --argjson allowedUserIds "$allowed" \
      '{
        # Upstream reads creds via loadConfig().bot (configStore.js
        # getBotConfig/hasBotConfig) — the flat example in the upstream
        # README {discordToken, clientId, …} does NOT match the shipped
        # code and yields "No bot configuration found" at start
        # (observed live 2026-08-26).
        bot: {
          discordToken: $discordToken,
          clientId: $clientId,
          guildId: $guildId
        },
        allowedUserIds: $allowedUserIds
      }' \
      > "$cfgDir/.config.json.rendered"
    chmod 0600 "$cfgDir/.config.json.rendered"
    mv -f "$cfgDir/.config.json.rendered" "$cfgDir/config.json"
  '';
in
{
  options.jupiter.services.discordOpencodeBridge = {
    enable = lib.mkEnableOption ''
      remote-opencode Discord bridge: slash-command access to this host's
      opencode rig as io.
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = bridgePkg;
      defaultText = "pkgs/discord-opencode-bridge";
      description = "remote-opencode package to run.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.discord_bridge_env = {
      owner = "io";
      mode = "0400";
    };

    systemd.services.remote-opencode = {
      description = "Discord bridge for opencode (remote-opencode)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # /run/current-system/sw FIRST: `opencode` resolves to the wrapped
      # launcher (provider keys injected); everything else (git, ssh, curl,
      # node tooling) comes from the system package set — same grammar as
      # dsh.nix, whose spawned-agent PATH findings apply verbatim here.
      path = [
        "/run/current-system/sw"
        pkgs.nodejs
        pkgs.git
      ];

      environment = {
        NODE_ENV = "production";
        # update-notifier wants a writable config home; HOME is set by
        # systemd from the io passwd entry anyway, pinned here for clarity.
        HOME = "/home/io";
        # The npm update check writes under ~/.config and spams the journal
        # when it can't; irrelevant for a pinned Nix package.
        NO_UPDATE_NOTIFIER = "1";
      };

      serviceConfig = {
        Type = "exec";
        User = "io";
        Group = "users";
        WorkingDirectory = "/home/io";
        Restart = "on-failure";
        RestartSec = "5s";
        PrivateTmp = true;
      };

      preStart = "${renderConfig}";

      script = ''
        exec ${lib.getExe cfg.package} start
      '';
    };
  };
}
