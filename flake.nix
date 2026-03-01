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

    packages = eachSystem ({craneLib, ...}: let
      src = craneLib.cleanCargoSource ./drivers/rust;
      commonArgs = {inherit src;};
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    in {
      nixcfg-rs = craneLib.buildPackage (commonArgs // {inherit cargoArtifacts;});
    });

    checks = eachSystem ({
      pkgs,
      craneLib,
    }: let
      # -- nix lib checks --
      schema = builtins.fromJSON (builtins.readFile ./examples/mycel.json);
      opts = nixcfgLib.optionsFromFile ./examples/mycel.json;
      mod' = nixcfgLib.mkModule {schema = ./examples/mycel.json;};
      evaled = lib.evalModules {modules = [mod'];};
      moduleOpts = evaled.options.services.mycel;

      # mock config for testing toCliArgs / toEnvVars
      mockCfg = {
        dataDir = "/var/lib/mycel";
        model = "claude-sonnet-4-20250514";
        logLevel = "info";
        cacheWarming = true;
        discordTokenFile = "/run/secrets/discord";
        anthropicKeyFile = null;
      };
      cliArgs = nixcfgLib.toCliArgs schema mockCfg;
      envVars = nixcfgLib.toEnvVars schema mockCfg;
      configAttrs = nixcfgLib.toConfigAttrs schema mockCfg;

      # -- rust driver --
      rustSrc = craneLib.cleanCargoSource ./drivers/rust;
      rustCommon = {src = rustSrc;};
      cargoArtifacts = craneLib.buildDepsOnly rustCommon;
    in {
      # nix: option names are correct
      nix-option-names = let
        expected = ["anthropicKeyFile" "cacheWarming" "dataDir" "discordTokenFile" "logLevel" "model"];
        actual = builtins.attrNames opts;
      in
        assert actual == expected;
          pkgs.runCommand "nixcfg-test-option-names" {} "touch $out";

      # nix: secrets transform correctly
      nix-secret-transform =
        assert opts ? discordTokenFile;
        assert opts ? anthropicKeyFile;
        assert !(opts ? discordToken);
        assert !(opts ? anthropicKey);
          pkgs.runCommand "nixcfg-test-secret-transform" {} "touch $out";

      # nix: defaults are preserved
      nix-defaults =
        assert opts.dataDir.default == "/var/lib/mycel";
        assert opts.model.default == "claude-sonnet-4-20250514";
        assert opts.logLevel.default == "info";
        assert opts.cacheWarming.default == false;
        assert opts.anthropicKeyFile.default == null;
          pkgs.runCommand "nixcfg-test-defaults" {} "touch $out";

      # nix: mkModule produces valid NixOS module
      nix-module =
        assert moduleOpts ? enable;
        assert moduleOpts ? dataDir;
        assert moduleOpts ? discordTokenFile;
          pkgs.runCommand "nixcfg-test-module" {} "touch $out";

      # nix: toCliArgs
      nix-cli-args = let
        hasFlag = flag: builtins.elem flag cliArgs;
        hasPair = flag: val:
          let
            indices = lib.imap0 (i: v: {inherit i v;}) cliArgs;
            flagIdx = lib.findFirst (x: x.v == flag) null indices;
          in
            flagIdx != null
            && builtins.elemAt cliArgs (flagIdx.i + 1) == val;
      in
        assert builtins.isList cliArgs;
        assert hasPair "--data-dir" "/var/lib/mycel";
        assert hasPair "--model" "claude-sonnet-4-20250514";
        assert hasPair "--log-level" "info";
        assert hasFlag "--cache-warming";
        assert hasPair "--discord-token-file" "/run/secrets/discord";
        # null anthropic key should be omitted
        assert !(hasFlag "--anthropic-key-file");
          pkgs.runCommand "nixcfg-test-cli-args" {} "touch $out";

      # nix: toEnvVars
      nix-env-vars =
        assert envVars.DATA_DIR == "/var/lib/mycel";
        assert envVars.MODEL == "claude-sonnet-4-20250514";
        assert envVars.CACHE_WARMING == "true";
        assert envVars.DISCORD_TOKEN_FILE == "/run/secrets/discord";
        assert !(envVars ? ANTHROPIC_KEY_FILE);
          pkgs.runCommand "nixcfg-test-env-vars" {} "touch $out";

      # nix: toConfigAttrs
      nix-config-attrs =
        assert configAttrs.data_dir == "/var/lib/mycel";
        assert configAttrs.model == "claude-sonnet-4-20250514";
        assert configAttrs.cache_warming == true;
        assert configAttrs.discord_token_file == "/run/secrets/discord";
        assert !(configAttrs ? anthropic_key_file);
          pkgs.runCommand "nixcfg-test-config-attrs" {} "touch $out";

      # rust: clippy
      rust-clippy = craneLib.cargoClippy (rustCommon
        // {
          inherit cargoArtifacts;
          cargoClippyExtraArgs = "--all-targets -- -D warnings";
        });

      # rust: tests
      rust-test = craneLib.cargoTest (rustCommon // {inherit cargoArtifacts;});

      # rust: formatting
      rust-fmt = craneLib.cargoFmt {src = rustSrc;};
    });
  };
}
