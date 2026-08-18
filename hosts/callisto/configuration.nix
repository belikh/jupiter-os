{
  config,
  lib,
  pkgs,
  ...
}:

# Compute node with no local disk — HP EliteDesk 800 G4 DM, i5-8500T
# (Coffee Lake, 6c/6t, no HT) + 64GB RAM. The box has repeatedly destroyed
# local NVMe drives, so it has none; root instead lives on an ext4
# filesystem carried over iSCSI from europa's tank/services/callisto-root
# zvol (modules/services/iscsi-target.nix). PXE (europa, jupiter.pxe) still
# hands off the kernel+initrd exactly as before — only what happens after
# the kernel starts has changed, from "unpack a RAM-resident squashfs" to
# "iSCSI-login, then mount a real ext4 root over the network".
#
# Role: the fleet's shared Nix remote builder (jupiter.core.buildMachines,
# in modules/core/build-machines.nix). Dwarfs every other registered host's
# hardware, so every host delegates eligible builds here instead of
# building locally.
#
# Live at 10.1.1.3 (UniFi DHCP reservation, MAC c4:65:16:b8:76:03 — see
# modules/core/build-machines.nix).
#
{
  imports = [
    ../../modules/common.nix
    ../../modules/services/mqtt.nix
    # Tailscale client for Jupiter tailnet
    ../../modules/services/tailscale.nix
    # Aeon autonomous agent framework dashboard
    ../../modules/services/aeon.nix
    # nom-web: browser UI for jupiter-ci build logs
    ../../modules/services/nom-web.nix
    # DeepSeek Harness (dsh): agent harness web UI on :3080
    ../../modules/services/dsh.nix
    # Dedicated Cloudflare tunnel for this host's public hostnames
    # (dsh.jupiter.au → loopbound-bound dsh via cloudflared running here)
    ../../modules/services/cloudflare-tunnel.nix
    # jupiterOS Arcade: boots straight into the gamescope/Pegasus session on
    # tty1 (modules/desktop/arcade-console.nix) with full kiosk collection
    # parity — console ROMs (modules/desktop/cartridges.nix) + eXo DOS/Win
    # collections (modules/desktop/exodos.nix), both read from europa over
    # NFS (export in modules/storage/nas-nfs.nix already covers the LAN).
    ../../modules/desktop/arcade-console.nix
    ../../modules/desktop/cartridges.nix
    ../../modules/desktop/exodos.nix
  ];

  networking.hostName = "callisto";
  # Stable per-host 8-char hex. Not currently required — callisto's root is
  # ext4, not ZFS, so nothing here actually consumes this — kept set anyway
  # since it's harmless and cheap insurance if a ZFS-backed filesystem is
  # ever added on this host later.
  networking.hostId = "ca11157c";

  # ---- Root over iSCSI -----------------------------------------------------
  # boot.iscsi-initiator (nixos/modules/services/networking/iscsi/root-initiator.nix)
  # HARD-asserts `!boot.initrd.systemd.enable` — it uses preLVMCommands/
  # extraUtilsCommands, which the systemd-stage-1 initrd doesn't implement
  # at all ("systemd stage 1 does not support iscsi yet" is its own literal
  # assertion message). This is the one non-optional trade of this whole
  # design: callisto loses systemd-stage-1's tooling in exchange for a
  # working iSCSI root, on this one host only.
  boot.initrd.systemd.enable = false;

  # The module also forces networking.useNetworkd = true and
  # networking.useDHCP = false itself (unconditional assignments, not
  # mkDefault) — don't set those separately here, they'd conflict. It adds
  # the iscsi_tcp kernel module, the iscsid/iscsiadm binaries, and
  # boot.initrd.network.enable = true (generic initrd DHCP, the classic-initrd
  # equivalent of what systemd-stage-1's network.enable does) on its own.
  # The only thing left to us is the NIC driver, which (unlike
  # netboot-minimal's RAM-resident environment, which had "no hardware scan
  # behind it") this classic initrd can autoload via udev the normal way —
  # same mechanism every disk-based NixOS install already relies on.
  boot.initrd.availableKernelModules = [ "e1000e" ]; # onboard Intel I219-LM
  boot.iscsi-initiator = {
    name = "iqn.2026-07.au.jupiter:callisto";
    discoverPortal = "${config.jupiter.fleet.addresses.europa}:3260";
    target = "iqn.2026-07.au.jupiter:europa:callisto-root";
  };

  # networkd has NO managed interfaces in stage 2 (the root-initiator module
  # forces networkd, but eno1's address comes from initrd DHCP and the
  # interface stays "unmanaged"), so systemd-networkd-wait-online can never
  # succeed — every nixos-rebuild restart of it hung 2 minutes, timed out, and
  # aborted switch-to-configuration MID-ACTIVATION (after the stop phase,
  # before the start phase), killing the arcade session on every switch and
  # never writing a boot generation. Nothing on this host consumes
  # network-online.target (the iSCSI root is up long before stage 2), so the
  # blessed fix is to not run the waiter at all.
  systemd.network.wait-online.enable = false;

  fileSystems."/" = {
    device = "/dev/disk/by-path/ip-${config.jupiter.fleet.addresses.europa}:3260-iscsi-iqn.2026-07.au.jupiter:europa:callisto-root-lun-0";
    fsType = "ext4";
    options = [ "relatime" ];
  };

  # PXE (europa's jupiter.pxe) hands off the kernel+initrd directly — this
  # host's own firmware boot menu / EFI NVRAM is never consulted, so
  # systemd-boot's *files* landing on the ESP are inert (harmless, just
  # unused). The provisioning install must therefore run with
  # `nixos-install --no-bootloader` (see docs/callisto-iscsi-root-provisioning.md
  # Stage 2): systemd-boot's installer runs `check-mountpoints`, which HARD-fails
  # when /boot isn't a mounted ESP, and the iSCSI LUN is a bare zvol with no
  # ESP — so the bootloader step must be skipped, not run. Actually touching
  # EFI NVRAM is the dangerous part regardless: the provisioning install runs
  # FROM europa against the zvol as a local block device, and EFI NVRAM belongs
  # to whichever physical machine runs the install (europa), not to the target
  # disk — leaving canTouchEfiVariables at common.nix's default would try to
  # rewrite EUROPA's own boot entries during that cross-machine install.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.systemd-boot.enable = false; # iSCSI LUN has no ESP; PXE boots kernel+initrd directly
  boot.loader.grub.enable = false; # no bootloader on iSCSI LUN

  # ---- Build daemon tuning for the shared-builder workload ----------------
  # callisto is a SHARED incremental builder for the fleet: when any host
  # does `nixos-rebuild`, only the few packages that actually changed get
  # dispatched here (the rest substitute from cache.nixos.org / Harmonia). Low
  # concurrency, larger per-package work. For that shape, cores=N +
  # max-jobs=1 wins: each derivation gets all 6 cores for its internal
  # `make -j$NIX_BUILD_CORES`, so even single big packages (a stale LLVM, a
  # kernel bump, a fresh rustc) finish fast instead of compiling
  # single-threaded while the other 5 cores sit idle waiting for the next
  # dispatch.
  #
  # Risk consideration: 64GB RAM. Worst-case -j6 linker memory for
  # LLVM-class packages is ~12-24GB; the box has 60+GB free in steady
  # state, so no OOM exposure at this setting. No swap — root now persists
  # on a disk-backed ext4 filesystem rather than tmpfs, but that headroom
  # math was never about tmpfs pressure in the
  # first place, it's about the build's own working set vs. RAM.
  nix.settings.cores = 4;
  nix.settings.max-jobs = 1;

  # Advertise capability to BUILD other hosts' microarch-tuned derivations.
  # callisto's own closure is ALSO skylake-tuned now (jupiter.build.microarch
  # = "skylake" below), so this advert matches its own tag. Without the
  # matching gccarch-<arch> feature, Nix refuses to even attempt a tagged
  # derivation here regardless of whether the CPU could run it.
  #
  # CPU confirmed 2026-07-20: i5-8500T is Coffee Lake, a strict ISA superset
  # of Skylake — so the gccarch-skylake advert is safe both ways (callisto
  # can compile skylake-tagged code AND run it in any checkPhase). This is
  # what makes the kiosk tuning (also skylake, i5-6300U) safe to dispatch
  # here.
  nix.settings.system-features = lib.mkAfter [
    "gccarch-bdver4"
    "gccarch-skylake"
    "big-parallel"
  ];

  # Dedicated key for fleet hosts to authenticate as root here for build
  # delegation (modules/core/buildMachines.nix). Public key only — not a
  # secret. Merges with common.nix's io-derived root key (NixOS concatenates
  # list-type options across modules), so admin SSH access is unaffected.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv1nEsuHqlA1ykn1p8wZmhhv1Y77cBxhgu2tAO3DhlP jupiter-fleet-nix-build"
  ];

  jupiter.build.microarch = "skylake";

  # Symmetric peer-to-peer build pool: callisto + 4 kiosks
  jupiter.core.buildMachines = {
    enable = true;
    selfHost = "callisto";
  };

  sops.secrets.tailscale_fleet_authkey = { };
  jupiter.services.tailscale = {
    enable = true;
    serverUrl = "https://neptune.jupiter.au:8080";
    tags = [ "tag:fleet" ];
    acceptRoutes = true;
    authKeyFile = config.sops.secrets.tailscale_fleet_authkey.path;
  };

  # console-screensaver removed 2026-08-16: tty1 is the arcade session now
  # and the cmatrix-on-getty screensaver belongs to the pre-arcade headless
  # era. tty1 hosts Pegasus (arcade-console.nix); the rescue getty lives on
  # tty2 (systemd.targets.getty.wants override in arcade-console.nix).

  sops.secrets.mqtt_homeassistant = { };
  sops.secrets.mqtt_ha_linux_agent = { };

  jupiter.services.mqtt = {
    enable = true;
    users = {
      homeassistant = {
        passwordFile = config.sops.secrets.mqtt_homeassistant.path;
        acl = [ "readwrite #" ];
      };
      ha-linux-agent = {
        passwordFile = config.sops.secrets.mqtt_ha_linux_agent.path;
        acl = [
          "readwrite homeassistant/#"
          "readwrite ha-linux-agent/#"
        ];
      };
    };
  };

  # ---- Local model server (jupiter.services.llm) — DISABLED 2026-08-15 ----
  # The box is now also the office arcade (arcadeConsole below): gamescope +
  # the emulators need the UHD 630 iGPU, which llama-server's Vulkan offload
  # was monopolizing. Disabled "for now" per io — re-enable by uncommenting
  # when the arcade experiment ends or the GPU is re-partitioned. Until then
  # the fleet has NO model server: every host's crush client still dials
  # http://10.1.1.3:8081 (modules/common.nix default) and will fail.
  # jupiter.services.llm.enable = true;
  # jupiter.services.llm.host = "0.0.0.0";
  # jupiter.services.llm.exposeLan = true;
  # jupiter.services.llm.clientUrl = "http://127.0.0.1:8081";

  hardware.graphics.enable = true;

  # ---- jupiterOS Arcade -----------------------------------------------------
  # Boot straight into the Pegasus arcade on tty1 over the HDMI display
  # (HDMI-A-1 confirmed connected 2026-08-15). Full kiosk collection parity:
  # console ROM sets (PS1/PS2 incl. — the Resident Evil archive lives on
  # europa's optical dataset) + the eXo DOS/Win3x/Win9x collections. gamescope
  # + emulators render on the UHD 630 via Mesa (hardware.graphics above);
  # stock nixpkgs gamescope, no Jovian/Steam/NM stack — see the module header
  # for why the kiosk's dashboard-gaming path is deliberately not used here.
  jupiter.arcadeConsole.enable = true;
  # The office arcade's display IS its audio output: LG TV on HDMI-A-1.
  # Without this, PulseAudio's heuristics pick the (silent) built-in analog
  # speakers over HDMI — game audio went nowhere until routed 2026-08-16.
  jupiter.arcadeConsole.audioOutput = "hdmi";
  jupiter.cartridges.enable = true;
  jupiter.exodos.enable = true;

  # Vulkan / Mesa diagnostics (vulkaninfo) — same tool modules/gaming/console.nix
  # installs for the same reason, kept independent here since that module is
  # gamescope-specific and not something callisto should pull in.
  # `gh` is on aeon.service's own PATH (modules/services/aeon.nix) — it's here
  # too so the CLI is available interactively for checking what the dashboard
  # sees (`sudo -u aeon gh auth status`, `gh secret list`) without digging a
  # store path out of the unit.
  environment.systemPackages = [
    pkgs.vulkan-tools
    pkgs.gh
  ];

  # ---- Aeon autonomous agent framework --------------------------------------
  # Runs the aeon dashboard (Next.js on port 5555, loopback + tunnel for
  # Tailscale access). The dashboard manages belikh/agent (a public fork of
  # aeonfun/aeon) via the `gh` CLI — all config (skills, schedules,
  # STRATEGY.md, SOUL.md, API keys, notifications) is done through the web UI.
  # GitHub Actions runs skills on cron in the fork's repo (public = unlimited
  # free Actions minutes). See modules/services/aeon.nix.
  # The dashboard runs as the unprivileged `aeon` user and reads this token in
  # ExecStartPre (`gh auth login --with-token < …`), so it must be readable by
  # that user — the sops default (0400 root:root) fails the unit outright.
  sops.secrets.aeon_gh_token = {
    owner = "aeon";
    group = "aeon";
    mode = "0400";
  };

  jupiter.services.aeon = {
    enable = true;
    repoUrl = "github:belikh/aeon";
    ghTokenFile = config.sops.secrets.aeon_gh_token.path;
    # Loopback + the Cloudflare tunnel below (aeon.jupiter.au ingress), NOT a
    # LAN bind: the dashboard wields a repo-scope GitHub PAT (workflow
    # dispatch, secrets writes) — 0.0.0.0 + an open LAN port made that
    # reachable from every device on 10.1.1.0/24 (P0, fixed 2026-08-17).
    # dsh.jupiter.au uses the same loopback+tunnel shape.
    #
    # ONE manual step completes the cutover (run once, from anywhere with
    # the cloudflare cert — same command that routed dsh.jupiter.au):
    #   cloudflared tunnel route dns jupiter-callisto aeon.jupiter.au
    # Until then the tunnel 502s for that name; `ssh -L 5555:localhost:5555`
    # bridges the gap.
    host = "127.0.0.1";
    exposeLan = false;
  };

  # ---- nom-web: browser UI for ci-distributed.yml's build logs -------------
  # Reads europa's /var/log/jupiter-ci over NFS (export in
  # modules/storage/nas-nfs.nix); `soft` so a dead europa doesn't hang the
  # service. Reached publicly at nom.jupiter.au via europa's Cloudflare
  # Tunnel (extraIngress in hosts/europa/configuration.nix), so the port only
  # needs to be open to the LAN, not the internet.
  fileSystems."/mnt/jupiter-ci-logs" = {
    device = "${config.jupiter.fleet.addresses.europa}:/var/log/jupiter-ci";
    fsType = "nfs";
    options = [
      "ro"
      "noatime"
      "soft"
      "timeo=50"
      "retrans=2"
    ];
  };

  # tmpfs for Nix sandbox build directory (/build) — speeds up I/O-heavy builds
  # (linking, unpacking, writing build outputs). 20GB limit (callisto has 64GB RAM;
  # maxJobs=1 * cores=4 means at most one large build at a time; 20GB leaves
  # ample headroom for OS + services + the build's working set).
  fileSystems."/build" = {
    fsType = "tmpfs";
    options = [
      "size=20G"
      "mode=1777"
      "noatime"
    ];
  };

  jupiter.services.nomWeb = {
    enable = true;
    openFirewall = true;
  };

  # ---- DeepSeek Harness (dsh) — agent harness web UI ------------------------
  # Binds loopback ONLY by upstream design (0.1.0-rc.6's schema accepts just
  # 127.0.0.1|0.0.0.0 and the CLI rejects 0.0.0.0 as a safety guard — see
  # modules/services/dsh.nix). Public reachability is the dedicated
  # Cloudflare tunnel below, whose cloudflared runs on this host and proxies
  # to localhost:3080. The web app's /api trust fence keys on the Host
  # header, so the public hostname must be passed as a trusted host.
  #
  # Models: the settings/credentials UI plane is hard-gated to loopback by
  # upstream rc.6 (PRIVILEGED_METHODS in dsh-client-connection — no auth
  # layer exists yet), so providers are provisioned HOST-SIDE instead:
  # settingsFile declares two OpenAI-compatible providers using the SAME
  # keys the crush/zed wrappers already use (z.ai coding plan + groq), with
  # apiKeyEnv references resolved from the dsh_env sops secret. DeepSeek
  # itself stays available via Settings → Models if ever provisioned
  # loopback-side. Model ids fetched live from each endpoint's /models
  # 2026-08-17 (catalogs don't refresh themselves — see dsh-llm-pi-ai
  # §Known Limitations).
  jupiter.services.dsh = {
    enable = true;
    trustedHosts = [ "dsh.jupiter.au" ];
    environmentFile = config.sops.secrets.dsh_env.path;
    settingsFile =
      (pkgs.writeText "dsh-settings.yaml" ''
        # Default model for new sessions/agents (settings ns: agent-default-model)
        agent-default-model:
          provider: zai-coding
          model: glm-5.3

        llm-pi-ai:
          providers:
            zai-coding:
              displayName: Z.AI (coding plan)
              apiKeyEnv: Z_AI_API_KEY
              api: openai-completions
              baseURL: https://api.z.ai/api/coding/paas/v4
              models:
                - id: glm-5.3
                - id: glm-5.2
                - id: glm-5.1
                - id: glm-5
                - id: glm-5-turbo
                - id: glm-4.7
                - id: glm-4.6
                - id: glm-4.5-air
            groq:
              displayName: Groq
              apiKeyEnv: GROQ_API_KEY
              api: openai-completions
              baseURL: https://api.groq.com/openai/v1
              models:
                - id: llama-3.3-70b-versatile
                - id: llama-3.1-8b-instant
                - id: openai/gpt-oss-120b
                - id: openai/gpt-oss-20b
                - id: qwen/qwen3.6-27b
                - id: groq/compound
                - id: groq/compound-mini
      '').outPath;
  };

  # Keys for the providers above (same values as the crush/zed secrets,
  # packed as one env file — restic_env pattern).
  sops.secrets.dsh_env = { };

  # ---- Cloudflare Tunnel (dedicated per-host tunnel) ------------------------
  # europa's tunnel can't serve dsh: its cloudflared can't reach THIS host's
  # loopback-bound dsh, and a second connector on europa's tunnel would be
  # edge-routed requests its ingress doesn't know (see
  # modules/services/cloudflare-tunnel.nix). Tunnel "jupiter-callisto"
  # (85534a9c) created 2026-08-16 via `cloudflared tunnel create`; creds in
  # the cloudflare_callisto_cert sops secret; DNS dsh.jupiter.au → tunnel
  # via `cloudflared tunnel route dns`.
  jupiter.services.cloudflareTunnel = {
    enable = true;
    tunnelId = "85534a9c-2c13-412c-a658-322f7c36edc7";
    credentialSecret = "cloudflare_callisto_cert";
    # This host serves no Harmonia — leave europa's cache hostname out.
    harmoniaHostname = null;
    extraIngress = [
      {
        hostname = "dsh.jupiter.au";
        # cloudflared runs here; dsh is loopback-only. host defaults to
        # localhost, which is exactly right.
        port = 3080;
      }
      {
        # Loopback-bound aeon dashboard (see the aeon block above) — needs
        # `cloudflared tunnel route dns jupiter-callisto aeon.jupiter.au`
        # once, same as dsh.
        hostname = "aeon.jupiter.au";
        port = 5555;
      }
    ];
  };
}
