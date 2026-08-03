{
  config,
  lib,
  pkgs,
  ...
}:

# Local model host for the fleet. Serves the Qwen3-Coder-30B-A3B GGUF on a
# localhost-only OpenAI-compatible API for agentic clients (Crush, Zed), so
# code and prompts never leave the LAN. Wraps nixpkgs' own `services.llama-cpp`
# (llama-server) rather than hand-rolling a service — that is the blessed
# path, and it satisfies buildability rule 2: nothing heavy (~19GB model)
# enters the nix store / closure. llama-server downloads the GGUF from
# HuggingFace on first start via --hf-repo / --hf-file into its StateDirectory.
#
# Model choice (research, 2026-07): Qwen 3B-active MoE is the sweet spot for
# callisto — 6-thread, CPU-only, no AVX-512, ~62Gi usable RAM, and it doubles
# as the fleet build server. A dense 7-14B is faster but falls below agentic
# coding needs; the leaderboard 35B-class dense models assume server hardware.
# Qwen3-Coder-30B-A3B (30B total / ~3B active MoE) keeps per-token CPU cost
# low while its agentic-coding + function-calling handle opencode/crush's
# multi-step tool loops. Q4_K_M (~18Gi) fits callisto's RAM with headroom.
let
  cfg = config.jupiter.services.llm;
in
{
  options.jupiter.services.llm = {
    enable = lib.mkEnableOption "Qwen3-Coder-30B-A3B served via llama-server for local agentic clients";

    package = lib.mkPackageOption pkgs "llama-cpp" { };

    hfRepo = lib.mkOption {
      type = lib.types.str;
      default = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF";
      description = "HuggingFace repo holding the GGUF it self-downloads.";
    };

    hfFile = lib.mkOption {
      type = lib.types.str;
      default = "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf";
      description = "GGUF file within hfRepo to serve.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address llama-server binds. Localhost-only by default.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Port llama-server listens on.";
    };

    exposeLan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the serving port on the LAN firewall (trusted fleet VLAN only).";
    };

    contextSize = lib.mkOption {
      type = lib.types.int;
      default = 32768;
      description = "Context window in tokens.";
    };

    gpuLayers = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "GPU layers offloaded. 0 = CPU-only (callisto has no discrete GPU).";
    };

    # The agentic reasoner shares CPU with nix builds on this box, so default
    # to a sub-set of the cores and let operators tune up if the box is quiet.
    # A best-fit heuristic is the physical cores (callisto: 6).
    nThreads = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "Number of CPU threads llama-server uses (--threads).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.llama-cpp = {
      enable = true;
      package = cfg.package;
      settings = {
        host = cfg.host;
        port = cfg.port;
        "hf-repo" = cfg.hfRepo;
        "hf-file" = cfg.hfFile;
        "ctx-size" = cfg.contextSize;
        "n-gpu-layers" = cfg.cpusLayers; # set via jupiter option below
        threads = cfg.nThreads;
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.lanOpen cfg.port;
  };
}