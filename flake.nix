{
  description = "nixcfg - bridge config structs to NixOS module options";

  inputs = {
    nixpkgs.url = "git+https://github.com/nixos/nixpkgs?shallow=1&ref=nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    rust-overlay,
  }: let
    lib = nixpkgs.lib;
    nixcfgLib = import ./nix/lib.nix {inherit lib;};
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
    eachSystem = f:
      lib.genAttrs systems (system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
        };
        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
      in
        f {inherit pkgs craneLib;});
  in {
    lib = nixcfgLib;

    checks = eachSystem ({pkgs, craneLib}:
      (import ./nix/checks.nix {inherit lib pkgs nixcfgLib craneLib;})
      // (import ./nix/rust-checks.nix {inherit lib pkgs craneLib;}));
  };
}
