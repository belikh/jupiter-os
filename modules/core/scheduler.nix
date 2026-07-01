{ config, lib, ... }:

let
  cfg = config.jupiter.core.scheduler;
in
{
  options.jupiter.core.scheduler = {
    enable = lib.mkEnableOption "a sched-ext (scx) userspace CPU scheduler (chaotic-nyx)";

    name = lib.mkOption {
      type = lib.types.str;
      default = "scx_rustland";
      example = "scx_lavd";
      description = ''
        Which sched-ext scheduler to run (services.scx.scheduler). Pick the
        variant suited to the host's actual workload rather than defaulting
        to the gaming-tuned one everywhere, e.g. scx_lavd for low-latency
        interactive/gaming hosts, scx_bpfland for general desktop
        responsiveness, scx_rustland for server/throughput workloads.
        Requires a sched_ext-capable kernel (jupiter.gaming.console's
        cachyOsKernel, or any other kernel with CONFIG_SCHED_CLASS_EXT).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.scx = {
      enable = true;
      scheduler = cfg.name;
    };
  };
}
