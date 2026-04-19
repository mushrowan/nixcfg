{
  description = "nixcfg - bridge config structs to NixOS module options";

  inputs = {
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs?shallow=1&ref=nixos-unstable";

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    nix-gleam = {
      url = "github:arnarg/nix-gleam";
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
        self',
        config,
        ...
      }: let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [(import inputs.rust-overlay)];
        };

        rustToolchain = pkgs.rust-bin.nightly.latest.default.override {
          extensions = ["rust-src" "rust-analyzer"];
        };

        craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;

        # rust lives under rust/, cleanly scoped so editing nix/, gleam/,
        # or docs doesn't bust the cargo build cache
        src = craneLib.cleanCargoSource ./rust;

        nixcfgLib = import ./nix/lib.nix {inherit (pkgs) lib;};

        craneOutputs = import ./nix/package.nix {
          inherit pkgs craneLib src;
          cargoToml = ./rust/nixcfg/Cargo.toml;
        };

        gleamOutputs = import ./nix/gleam.nix {
          inherit pkgs;
          inherit (inputs) nix-gleam;
        };
      in {
        packages.default = craneOutputs.package;
        packages.example-gleam = gleamOutputs.exampleApp;

        checks =
          (import ./nix/checks.nix {
            inherit (pkgs) lib;
            inherit pkgs nixcfgLib;
          })
          // {
            inherit (craneOutputs) package clippy test deny doctest schemaCheck;
            gleamSchemaCheck = gleamOutputs.schemaCheck;
            gleamTest = gleamOutputs.testCheck;
          };

        devShells.default = import ./nix/devshell.nix {
          inherit pkgs craneLib;
          inherit (craneOutputs) cargoArtifacts;
          inherit (self') checks;
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
            rustfmt = {
              enable = true;
              package = rustToolchain;
            };
            taplo.enable = true;
            gleam.enable = true;
          };
        };
      };
    };
}
