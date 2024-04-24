{
  description = "WFVM: Windows Functional Virtual Machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    # only x64 is supported
    system = "x86_64-linux";

    pkgs = nixpkgs.legacyPackages.${system};
  in rec {
    lib = import ./wfvm {
      inherit pkgs;
    };

    packages.${system} = rec {
      demoImage = import ./wfvm/demo-image.nix {
        inherit self;
      };

      default = lib.utils.wfvm-run {
        name = "demo";
        image = demoImage;
        script = ''
          echo "Windows booted. Press Enter to terminate VM."
          read
        '';
        display = true;
      };
    };
  };
}
