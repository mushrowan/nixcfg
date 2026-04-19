{
  description = "nixcfg - bridge config structs to NixOS module options via JSON Schema";

  inputs = {
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs?shallow=1&ref=nixos-unstable";

    flake-parts = {
      url = "git+https://github.com/hercules-ci/flake-parts?shallow=1";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    flake-parts,
    nixpkgs,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

      flake.lib = import ./nix/lib.nix {inherit (nixpkgs) lib;};

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks.flakeModule
      ];

      perSystem = {
        system,
        config,
        ...
      }: let
        pkgs = import inputs.nixpkgs {inherit system;};
        nixcfgLib = import ./nix/lib.nix {inherit (pkgs) lib;};
      in {
        checks = import ./nix/checks.nix {
          inherit (pkgs) lib;
          inherit pkgs nixcfgLib;
        };

        devShells.default = import ./nix/devshell.nix {
          inherit pkgs;
          shellHook = config.pre-commit.installationScript;
        };

        pre-commit.settings.hooks = {
          treefmt.enable = true;
          treefmt.package = config.treefmt.build.wrapper;
        };

        treefmt = {
          projectRootFile = "flake.nix";
          programs = {
            alejandra.enable = true;
            deadnix.enable = true;
            statix.enable = true;
          };
        };
      };
    };
}
