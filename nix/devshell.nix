{
  pkgs,
  shellHook ? "",
}:
pkgs.mkShell {
  inherit shellHook;

  packages = with pkgs; [
    jujutsu
    nixd
  ];
}
