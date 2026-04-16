{
  description = "AMD AI inference stack for NixOS (XRT, xrt-plugin-amdxdna, FastFlowLM, Lemonade)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      flake = {
        overlays.default = final: prev: let
          xrt = final.callPackage ./pkgs/xrt {};
          fastflowlm = final.callPackage ./pkgs/fastflowlm {inherit xrt;};
        in {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = final.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = final.callPackage ./pkgs/lemonade {inherit fastflowlm;};
        };

        nixosModules.default = {
          imports = [./modules/amd-npu.nix];
          nixpkgs.overlays = [inputs.self.overlays.default];
        };
      };

      perSystem = {
        pkgs,
        ...
      }: let
        xrt = pkgs.callPackage ./pkgs/xrt {};
        fastflowlm = pkgs.callPackage ./pkgs/fastflowlm {inherit xrt;};
      in {
        packages = {
          inherit xrt fastflowlm;
          xrt-plugin-amdxdna = pkgs.callPackage ./pkgs/xrt-plugin-amdxdna {inherit xrt;};
          lemonade = pkgs.callPackage ./pkgs/lemonade {inherit fastflowlm;};
        };
      };
    };
}
