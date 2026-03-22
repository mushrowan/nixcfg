# rust driver checks (cargo test, clippy, fmt) via crane
{
  lib,
  pkgs,
  craneLib,
}: let
  src = lib.cleanSourceWith {
    src = ../drivers/rust;
    filter = path: type:
      (craneLib.filterCargoSources path type);
  };

  commonArgs = {
    inherit src;
    pname = "nixcfg-rs";
    version = "0.2.0";
    strictDeps = true;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in {
  rust-test = craneLib.cargoTest (commonArgs // {inherit cargoArtifacts;});

  rust-clippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoArtifacts;
    cargoClippyExtraArgs = "--all-targets -- -D warnings";
  });

  rust-fmt = craneLib.cargoFmt {
    inherit src;
    pname = "nixcfg-rs";
    version = "0.2.0";
  };
}
