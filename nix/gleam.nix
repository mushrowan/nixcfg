# gleam driver: build the example app + schema drift check + unit tests
{
  pkgs,
  nix-gleam,
}: let
  inherit (nix-gleam.packages.${pkgs.system}) buildGleamApplication;

  referenceSchema = ../gleam/nixcfg/schema.json;

  # nix-gleam's default entrypoint runs the package's main module, which
  # is `nixcfg` here. we want a binary that runs `example_mycel:main/0`,
  # so inject one via postInstall
  exampleApp = buildGleamApplication {
    pname = "example-mycel-gleam";
    version = "0.3.0";
    src = ../gleam/nixcfg;
    postInstall = ''
      cat > $out/bin/example_mycel <<EOF
      #!/usr/bin/env sh
      exec ${pkgs.erlang}/bin/erl \\
        -pa $out/lib/*/ebin \\
        -eval 'nixcfg@@main:run(example_mycel)' \\
        -noshell \\
        -extra "\$@"
      EOF
      chmod +x $out/bin/example_mycel
    '';
  };

  # separate derivation that runs `gleam test` against the library.
  # shares the same source setup as the example app (vendored deps,
  # rebar cache) but replaces the buildPhase with a test run
  testRunner = buildGleamApplication {
    pname = "nixcfg-gleam-test";
    version = "0.3.0";
    src = ../gleam/nixcfg;
    buildPhase = ''
      runHook preBuild
      export REBAR_CACHE_DIR="$TMP/.rebar-cache"
      gleam test
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      echo "gleam tests passed" > $out/result
      runHook postInstall
    '';
  };
in {
  inherit exampleApp testRunner;

  # catches drift between the gleam example source and its checked-in
  # schema.json. if the example changes, this fails until someone
  # re-runs `gleam run --module example_mycel > schema.json` inside
  # the project directory
  schemaCheck = pkgs.runCommand "nixcfg-gleam-schema-check" {} ''
    ${exampleApp}/bin/example_mycel > $TMPDIR/generated.json
    ${pkgs.diffutils}/bin/diff -u ${referenceSchema} $TMPDIR/generated.json
    touch $out
  '';

  # gleam unit tests: runs gleeunit against the nixcfg module
  testCheck = pkgs.runCommand "nixcfg-gleam-test-check" {} ''
    cat ${testRunner}/result
    touch $out
  '';
}
