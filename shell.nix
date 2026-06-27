{ pkgs, deploy-rs }:

pkgs.mkShell {
  packages = with pkgs; [
    terraform
    sops
    age
    deploy-rs.packages.${pkgs.system}.deploy-rs
  ];
}
