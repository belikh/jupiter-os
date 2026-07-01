{ pkgs, deploy-rs }:

pkgs.mkShell {
  packages = with pkgs; [
    terraform
    sops
    age
    awscli2 # S3-compatible upload/presign for the R2 pallene-iso bucket (make rebuild-world)
    deploy-rs.packages.${pkgs.system}.deploy-rs
  ];
}
