{
  pkgs,
  craneLib,
  checks ? {},
  cargoArtifacts ? null,
  shellHook ? "",
}:
craneLib.devShell {
  inherit checks cargoArtifacts shellHook;

  packages = with pkgs; [
    cargo-deny
    cargo-edit
    cargo-machete
    cargo-nextest
    cargo-watch
    jujutsu
    # gleam driver
    gleam
    erlang
    rebar3
  ];
}
