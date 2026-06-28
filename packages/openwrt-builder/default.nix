{
  nix-openwrt-imagebuilder,
  pkgs,
  profile,
  extraPackages ? [ ],
}:

nix-openwrt-imagebuilder.lib.build {
  inherit pkgs;
  target = "qualcommax/ipq807x"; # ipq807x moved under qualcommax in modern OpenWrt (23.x+)
  profile = profile;
  packages = [
    "nano"
    "tcpdump" # Essential for debugging mesh/roaming
    "iperf3" # Essential for testing mesh throughput
  ]
  ++ extraPackages;

  # Any static configuration files to inject into the firmware (e.g., uci-defaults)
  files = ../../hosts/parents-house/access-points/mx4300-files;
}
