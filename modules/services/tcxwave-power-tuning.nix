{ pkgs, ... }:

# Power/kernel tuning for the Toshiba TCx Wave units behind hosts/{metis,adrastea,amalthea,thebe}
# (4x retail-POS terminals, model 6140-E45: Intel Core i5-6300U — Skylake-U,
# dual-core/4-thread, 15W TDP, 2.4GHz base / Turbo to 3.0GHz, full HWP/EPP
# support — with integrated HD Graphics 520 (Gen9) driving a built-in 15"
# touchscreen panel). CPU/GPU/NIC/storage are confirmed against SUSE's YES
# certification for this exact model (i5-6300U, HD 520/i915, I219-LM/e1000e,
# SanDisk Z400s SATA SSD), so the assumptions below are no longer guesses.
# These run a Chromium dashboard 24/7 at near-idle CPU load, so the win is
# almost entirely in idle power: deep C-states, a GPU that can power down its
# display link between repaints, and runtime PM everywhere else, not raw
# compute tuning.
{
  # Newest mainline kernel: intel_idle C-state tables, i915 power fixes, and
  # intel_pstate/HWP scaling improvements land here first. Pulled from the
  # binary cache, not compiled from source — no CI cost.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # GPU (i915 / Skylake Gen9, eDP panel): PSR lets the display controller
  # power down the link entirely while content is static — and a dashboard
  # is static almost all the time between refreshes, which is exactly the
  # case PSR is for. FBC additionally cuts memory-bandwidth power whenever it
  # *is* actively scanning out. RC6 covers render-engine idle. fastboot skips
  # a redundant modeset when firmware already matches.
  #
  # Deliberately NOT capping processor.max_cstate / intel_idle.max_cstate:
  # that would force the CPU into shallower, higher-power idle states. Deep
  # C-states between repaints are exactly where we want it sitting.
  #
  # Deliberately NOT passing mitigations=off: these boxes render Chromium
  # against arbitrary remote (Home Assistant dashboard) content, so CPU
  # vulnerability mitigations stay on.
  boot.kernelParams = [
    "i915.enable_rc6=1"
    "i915.enable_fbc=1"
    "i915.enable_psr=1"
    "i915.fastboot=1"
    "nmi_watchdog=0" # one less periodic timer interrupt; no hardlockup detection needed on an appliance
    "quiet" # branding.nix's verbose banner is off for this host (see modules/desktop/dashboard-kiosk.nix) — no console spam to suppress
  ];

  boot.kernel.sysctl = {
    "vm.swappiness" = 1; # prefer zram below; only spill to disk if truly desperate
  };

  # Boot speed: this fleet is fixed, known hardware (same 4 retail-POS units,
  # same SSD, same internal panel) booting from local disk, not a generic
  # NixOS ISO that has to cope with anything. No bootloader menu to wait on,
  # no broad hardware-compat module set to probe through, and a quiet,
  # parallel initrd instead of a serial one.
  boot.loader.timeout = 0;

  # Stage-1 init as systemd: udev/module loading runs in parallel instead of
  # the legacy serial shell script. branding.nix forces this off fleet-wide
  # (its preDeviceCommands banner needs the legacy script); off for this host
  # since branding is disabled above.
  boot.initrd.systemd.enable = true;

  # Skip NixOS's broad default initrd module set (covers arbitrary unknown
  # hardware) and list only what this specific, known machine needs to find
  # its root device and basic input. The 128GB SSD is a SanDisk Z400s on the
  # SATA/AHCI bus (confirmed by SUSE's YES cert for the 6140-E45 — ahci.ko),
  # so `nvme` is dropped: this chassis has no NVMe slot. Deliberately NOT
  # touching Wi-Fi/Bluetooth modules — those aren't initrd-critical and
  # guessing wrong there silently breaks hardware instead of just costing a
  # few boot-seconds.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [
    "ahci"
    "usb_storage"
    "usbhid"
  ];

  # No beep hardware worth a kernel module on a touchscreen kiosk appliance.
  boot.blacklistedKernelModules = [ "pcspkr" ];

  # Quieter console = fewer synchronous framebuffer writes during boot.
  boot.consoleLogLevel = 3;

  # The ZFS root pool here is tiny (root + nix only, no bulk data — see
  # disko.nix), so a default-sized ARC just steals RAM Chromium could use.
  # These units have 8GB (confirmed at purchase), so the 512MB cap below is
  # deliberately conservative — there's plenty of headroom, but a read-light
  # kiosk pool gains little from a bigger cache, so the RAM is better left
  # free for Chromium than handed to ARC.
  #
  # zfs_txg_timeout batches writes further apart, meaning fewer storage
  # wakeups — at the cost of a wider data-loss window on power loss.
  # Acceptable: kiosks are stateless appliances, nothing irreplaceable lives
  # here (see disko.nix).
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=536870912
    options zfs zfs_txg_timeout=30
  '';

  # zram swap instead of disk swap. lz4 keeps (de)compression overhead low —
  # the same tradeoff this fleet already makes for its ZFS pools — and this
  # CPU has cycles to spare for it unlike a low-power Atom box.
  zramSwap = {
    enable = true;
    algorithm = "lz4";
    memoryPercent = 50;
  };

  # GPU userspace stack for VA-API hardware video decode (see the chromium
  # flags in modules/desktop/dashboard-kiosk.nix) — offloads video decode from
  # the CPU to the iGPU's fixed-function decoder. intel-media-driver (iHD) is
  # the actively maintained driver for Gen9 Skylake graphics (the legacy i965
  # driver targets Gen4-8 and isn't the right pick here).
  hardware.graphics = {
    enable = true;
    extraPackages = [
      pkgs.intel-media-driver
      pkgs.libvdpau-va-gl
    ];
  };

  # Pin the iHD VA-API driver for Gen9 Skylake graphics rather than relying
  # on driver auto-probe.
  environment.variables.LIBVA_DRIVER_NAME = "iHD";

  # TLP owns runtime power management: CPU governor + energy/perf hint, SATA/
  # PCIe link power, USB autosuspend, Wake-on-LAN, audio codec power-save.
  # CPU_ENERGY_PERF_POLICY only works because Skylake has full HWP support —
  # it lets the CPU itself bias every P-state decision toward efficiency
  # instead of a fixed governor curve, which is the better lever than capping
  # max frequency (that would just make bursty page-render work take longer
  # to finish and go idle). If these units do have a backup battery, only the
  # *_ON_AC keys apply here since they're permanently mains-powered.
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "power";
      SATA_LINKPWR_ON_AC = "min_power";
      PCIE_ASPM_ON_AC = "powersupersave";
      RUNTIME_PM_ON_AC = "auto";
      # Never autosuspend the display GPU via generic PCI runtime PM — these
      # boxes exist to show a screen, and i915's own RC6/PSR (enabled above)
      # already cover the actually-meaningful power saving on this device.
      RUNTIME_PM_DRIVER_DENYLIST = "i915";
      USB_AUTOSUSPEND = 1;
      WOL_DISABLE = "Y";
      SOUND_POWER_SAVE_ON_AC = 1;
    };
  };

  # Keeps a thermally-constrained terminal chassis from ever needing to
  # throttle hard by trimming proactively instead.
  services.thermald.enable = true;

  # Diagnostics only — TLP already continuously enforces the equivalent of
  # `powertop --auto-tune`, so we don't also run powertop's one-shot tuning
  # (the two would fight over the same sysfs knobs).
  environment.systemPackages = [ pkgs.powertop ];

  # A kiosk has no operator tailing `journalctl` day to day, and every
  # persisted log line is a write the disk had to wake up for.
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=64M
  '';
}
