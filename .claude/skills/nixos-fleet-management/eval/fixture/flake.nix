{
  description = "fixture fleet (stand-in for jupiter-os)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      amalthea = {
        hostName = "amalthea";
        role = "canonical-template";
      };
      metis = {
        hostName = "metis";
        role = "sibling";
      };
    };
  };
}
