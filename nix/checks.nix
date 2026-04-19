# nix lib checks for nixcfg (JSON Schema edition)
{
  lib,
  pkgs,
  nixcfgLib,
}: let
  # -- schemas --
  simple = builtins.fromJSON (builtins.readFile ../examples/mycel.json);
  complex = builtins.fromJSON (builtins.readFile ../examples/complex.json);

  # -- helper --
  ok = name: pkgs.runCommand "nixcfg-${name}" {} "touch $out";

  # find a flag-value pair in a list of CLI args
  hasPair = args: flag: val: let
    len = builtins.length args;
    check = i:
      if i >= len - 1
      then false
      else if builtins.elemAt args i == flag && builtins.elemAt args (i + 1) == val
      then true
      else check (i + 1);
  in
    check 0;

  hasFlag = args: flag: builtins.elem flag args;
  lacksFlag = args: flag: !(builtins.elem flag args);

  # -- naming: generate options in each convention --
  camelOpts = nixcfgLib.optionsFromSchema {} simple;
  snakeOpts = nixcfgLib.optionsFromSchema {naming = "snake_case";} simple;
  kebabOpts = nixcfgLib.optionsFromSchema {naming = "kebab-case";} simple;
  screamOpts = nixcfgLib.optionsFromSchema {naming = "SCREAMING_SNAKE_CASE";} simple;

  # -- complex schema options --
  complexOpts = nixcfgLib.optionsFromSchema {} complex;

  # -- module evaluation --
  simpleMod = nixcfgLib.mkModule {schema = ../examples/mycel.json;};
  simpleEvaled = lib.evalModules {modules = [simpleMod];};
  simpleModOpts = simpleEvaled.options.services.mycel;

  complexMod = nixcfgLib.mkModule {schema = ../examples/complex.json;};
  complexEvaled = lib.evalModules {modules = [complexMod];};
  complexModOpts = complexEvaled.options.services.complex-app;

  # -- custom prefix --
  prefixMod = nixcfgLib.mkModule {
    schema = ../examples/mycel.json;
    prefix = ["programs"];
  };
  prefixEvaled = lib.evalModules {modules = [prefixMod];};

  # -- mock configs --
  simpleCfg = {
    dataDir = "/var/lib/mycel";
    model = "claude-sonnet-4-20250514";
    logLevel = "info";
    cacheWarming = true;
    discordTokenPath = "/run/secrets/discord";
    anthropicKeyPath = null;
  };

  complexCfg = {
    hostname = "0.0.0.0";
    port = 9090;
    debug = true;
    workers = 8;
    maxRetries = -1;
    dataDir = "/var/lib/complex";
    tags = ["web" "prod"];
    labels = {
      env = "production";
      tier = "frontend";
    };
    logLevel = "warn";
    optionalFeature = null;
    database = {
      host = "db.internal";
      port = 5432;
      name = "mydb";
      poolSize = 10;
    };
    apiKeyPath = "/run/secrets/api";
    dbPasswordPath = null;
    allowedOrigins = ["https://example.com" "https://app.example.com"];
  };

  # -- conversion outputs --
  simpleCli = nixcfgLib.toCliArgs {} simple simpleCfg;
  simpleEnv = nixcfgLib.toEnvVars {} simple simpleCfg;
  simpleConfig = nixcfgLib.toConfigAttrs {} simple simpleCfg;

  complexCli = nixcfgLib.toCliArgs {} complex complexCfg;
  complexEnv = nixcfgLib.toEnvVars {} complex complexCfg;
  complexConfig = nixcfgLib.toConfigAttrs {} complex complexCfg;

  # -- override test --
  overrideMod = nixcfgLib.mkModule {
    schema = ../examples/mycel.json;
    overrides = {
      data_dir.type = lib.types.either lib.types.path lib.types.str;
      data_dir.description = "overridden description";
    };
    extraOverrides = {
      package = {
        type = lib.types.package;
        description = "package to use";
      };
    };
  };
  overrideEvaled = lib.evalModules {modules = [overrideMod];};
  overrideOpts = overrideEvaled.options.services.mycel;
in {
  # ── naming conventions ────────────────────────────────────────────

  nix-naming-camel = let
    expected = ["anthropicKeyPath" "cacheWarming" "dataDir" "discordTokenPath" "logLevel" "model"];
  in
    assert builtins.attrNames camelOpts == expected;
      ok "naming-camel";

  nix-naming-snake = let
    expected = ["anthropic_key_path" "cache_warming" "data_dir" "discord_token_path" "log_level" "model"];
  in
    assert builtins.attrNames snakeOpts == expected;
      ok "naming-snake";

  nix-naming-kebab = let
    expected = ["anthropic-key-path" "cache-warming" "data-dir" "discord-token-path" "log-level" "model"];
  in
    assert builtins.attrNames kebabOpts == expected;
      ok "naming-kebab";

  nix-naming-screaming = let
    expected = ["ANTHROPIC_KEY_PATH" "CACHE_WARMING" "DATA_DIR" "DISCORD_TOKEN_PATH" "LOG_LEVEL" "MODEL"];
  in
    assert builtins.attrNames screamOpts == expected;
      ok "naming-screaming";

  # ── type mapping ──────────────────────────────────────────────────

  nix-types = let
    o = complexOpts;
  in
    # simple types
    assert o.hostname.type.name == "str";
    assert o.port.type.name == "unsignedInt16";
    assert o.debug.type.name == "bool";
    # format-aware: workers has format "uint32" → types.ints.u32
    assert o.workers.type.name == "unsignedInt32";
    # format-aware: max_retries has format "int32" → types.ints.s32
    assert o.maxRetries.type.name == "signedInt32";
    assert o.dataDir.type.name == "str";
    # enum (via $ref)
    assert o.logLevel.type.name == "enum";
    # optional (nullable)
    assert o.optionalFeature.type.name == "nullOr";
    # list (array)
    assert o.tags.type.name == "listOf";
    # attrs (additionalProperties)
    assert o.labels.type.name == "attrsOf";
    # submodule (object with properties, via $ref)
    assert o.database.type.name == "submodule";
    # nullable array
    assert o.allowedOrigins.type.name == "nullOr";
    # secrets become path
    assert o.apiKeyPath.type.name == "path";
    # optional secret becomes nullOr path
    assert o.dbPasswordPath.type.name == "nullOr";
      ok "types";

  # ── secrets ───────────────────────────────────────────────────────

  nix-secrets =
    # path suffix applied
    assert complexOpts ? apiKeyPath;
    assert complexOpts ? dbPasswordPath;
    assert !(complexOpts ? apiKey);
    assert !(complexOpts ? dbPassword);
    # optional secret defaults to null
    assert complexOpts.dbPasswordPath.default == null;
    # required secret has no default
    assert !(complexOpts.apiKeyPath ? default);
    # description prefixed
    assert lib.hasPrefix "path to file containing" complexOpts.apiKeyPath.description;
      ok "secrets";

  # ── defaults ──────────────────────────────────────────────────────

  nix-defaults = assert complexOpts.hostname.default == "localhost";
  assert complexOpts.port.default == 8080;
  assert !complexOpts.debug.default;
  assert complexOpts.workers.default == 4;
  assert complexOpts.maxRetries.default == (-1);
  assert complexOpts.dataDir.default == "/var/lib/complex";
  assert complexOpts.tags.default == [];
  assert complexOpts.logLevel.default == "info";
  assert complexOpts.optionalFeature.default == null;
    ok "defaults";

  # ── module generation ─────────────────────────────────────────────

  nix-module-simple = assert simpleModOpts ? enable;
  assert simpleModOpts ? dataDir;
  assert simpleModOpts ? discordTokenPath;
  assert simpleModOpts ? logLevel;
    ok "module-simple";

  nix-module-complex = assert complexModOpts ? enable;
  assert complexModOpts ? hostname;
  assert complexModOpts ? port;
  assert complexModOpts ? database;
  assert complexModOpts ? apiKeyPath;
  assert complexModOpts ? tags;
  assert complexModOpts ? allowedOrigins;
    ok "module-complex";

  nix-module-prefix = assert prefixEvaled.options.programs ? mycel;
  assert prefixEvaled.options.programs.mycel ? enable;
    ok "module-prefix";

  # ── CLI args ──────────────────────────────────────────────────────

  nix-cli-simple = assert hasPair simpleCli "--data-dir" "/var/lib/mycel";
  assert hasPair simpleCli "--model" "claude-sonnet-4-20250514";
  assert hasPair simpleCli "--log-level" "info";
  assert hasFlag simpleCli "--cache-warming";
  assert hasPair simpleCli "--discord-token-path" "/run/secrets/discord";
  assert lacksFlag simpleCli "--anthropic-key-path";
    ok "cli-simple";

  nix-cli-complex = assert hasPair complexCli "--hostname" "0.0.0.0";
  assert hasPair complexCli "--port" "9090";
  assert hasFlag complexCli "--debug";
  assert hasPair complexCli "--workers" "8";
  assert hasPair complexCli "--max-retries" "-1";
  assert hasPair complexCli "--api-key-path" "/run/secrets/api";
  # null values omitted
  assert lacksFlag complexCli "--optional-feature";
  assert lacksFlag complexCli "--db-password-path";
  # list values repeat the flag
  assert hasPair complexCli "--tags" "web";
  assert hasPair complexCli "--tags" "prod";
    ok "cli-complex";

  nix-cli-bool-false = let
    falseCfg = simpleCfg // {cacheWarming = false;};
    args = nixcfgLib.toCliArgs {} simple falseCfg;
  in
    assert lacksFlag args "--cache-warming";
      ok "cli-bool-false";

  # custom output naming for CLI
  nix-cli-output-naming = let
    args = nixcfgLib.toCliArgs {output = "snake_case";} simple simpleCfg;
  in
    assert hasPair args "--data_dir" "/var/lib/mycel";
    assert hasPair args "--discord_token_path" "/run/secrets/discord";
      ok "cli-output-naming";

  # ── env vars ──────────────────────────────────────────────────────

  nix-env-simple = assert simpleEnv.DATA_DIR == "/var/lib/mycel";
  assert simpleEnv.MODEL == "claude-sonnet-4-20250514";
  assert simpleEnv.CACHE_WARMING == "true";
  assert simpleEnv.DISCORD_TOKEN_PATH == "/run/secrets/discord";
  assert !(simpleEnv ? ANTHROPIC_KEY_PATH);
    ok "env-simple";

  nix-env-complex = assert complexEnv.HOSTNAME == "0.0.0.0";
  assert complexEnv.PORT == "9090";
  assert complexEnv.DEBUG == "true";
  assert complexEnv.WORKERS == "8";
  assert complexEnv.API_KEY_PATH == "/run/secrets/api";
  assert !(complexEnv ? DB_PASSWORD_PATH);
  assert !(complexEnv ? OPTIONAL_FEATURE);
  # list is comma-separated
  assert complexEnv.TAGS == "web,prod";
    ok "env-complex";

  # custom output naming for env
  nix-env-output-naming = let
    env = nixcfgLib.toEnvVars {output = "kebab-case";} simple simpleCfg;
  in
    assert env ? data-dir;
    assert env.data-dir == "/var/lib/mycel";
    assert env ? discord-token-path;
      ok "env-output-naming";

  # ── config attrs ──────────────────────────────────────────────────

  nix-config-simple = assert simpleConfig.data_dir == "/var/lib/mycel";
  assert simpleConfig.model == "claude-sonnet-4-20250514";
  assert simpleConfig.cache_warming;
  assert simpleConfig.discord_token_path == "/run/secrets/discord";
  assert !(simpleConfig ? anthropic_key_path);
    ok "config-simple";

  nix-config-complex = assert complexConfig.hostname == "0.0.0.0";
  assert complexConfig.port == 9090;
  assert complexConfig.debug;
  assert complexConfig.workers == 8;
  assert complexConfig.max_retries == (-1);
  assert complexConfig.tags == ["web" "prod"];
  assert complexConfig.api_key_path == "/run/secrets/api";
  assert !(complexConfig ? db_password_path);
  assert !(complexConfig ? optional_feature);
    ok "config-complex";

  # custom output naming for config
  nix-config-output-naming = let
    cfg = nixcfgLib.toConfigAttrs {output = "camelCase";} simple simpleCfg;
  in
    assert cfg ? dataDir;
    assert cfg.dataDir == "/var/lib/mycel";
    assert cfg ? discordTokenPath;
      ok "config-output-naming";

  # ── overrides ─────────────────────────────────────────────────────

  nix-overrides = assert overrideOpts ? dataDir;
  assert overrideOpts.dataDir.description == "overridden description";
    ok "overrides";

  nix-extra-overrides = assert overrideOpts ? package;
  assert overrideOpts.package.description == "package to use";
    ok "extra-overrides";

  nix-override-validation = let
    badModule = nixcfgLib.mkModule {
      schema = ../examples/mycel.json;
      overrides.nonexistent_field.type = lib.types.str;
    };
    threw = builtins.tryEval (
      builtins.deepSeq (lib.evalModules {modules = [badModule];}) true
    );
  in
    assert !threw.success;
      ok "override-validation";

  # ── snake_case naming end-to-end ──────────────────────────────────

  nix-snake-e2e = let
    snakeMod = nixcfgLib.mkModule {
      schema = ../examples/mycel.json;
      naming = "snake_case";
    };
    snakeEvaled = lib.evalModules {modules = [snakeMod];};
    snakeModOpts = snakeEvaled.options.services.mycel;

    snakeCfg = {
      data_dir = "/var/lib/mycel";
      model = "claude-sonnet-4-20250514";
      log_level = "info";
      cache_warming = true;
      discord_token_path = "/run/secrets/discord";
      anthropic_key_path = null;
    };

    cli = nixcfgLib.toCliArgs {naming = "snake_case";} simple snakeCfg;
    env = nixcfgLib.toEnvVars {naming = "snake_case";} simple snakeCfg;
    cfg = nixcfgLib.toConfigAttrs {naming = "snake_case";} simple snakeCfg;
  in
    # module options use snake_case
    assert snakeModOpts ? data_dir;
    assert snakeModOpts ? discord_token_path;
    assert !(snakeModOpts ? dataDir);
    # CLI still defaults to kebab-case output
    assert hasPair cli "--data-dir" "/var/lib/mycel";
    # env still defaults to screaming
    assert env.DATA_DIR == "/var/lib/mycel";
    # config still defaults to snake_case
    assert cfg.data_dir == "/var/lib/mycel";
      ok "snake-e2e";

  # ── settingsAttr ───────────────────────────────────────────────────

  nix-settings-attr = let
    settingsMod = nixcfgLib.mkModule {
      schema = ../examples/mycel.json;
      settingsAttr = "settings";
    };
    settingsEvaled = lib.evalModules {modules = [settingsMod];};
    settingsModOpts = settingsEvaled.options.services.mycel;
  in
    # enable stays at top level
    assert settingsModOpts ? enable;
    # schema options are nested under settings
    assert settingsModOpts ? settings;
    assert !(settingsModOpts ? dataDir);
    assert settingsModOpts.settings.type.name == "submodule";
      ok "settings-attr";

  nix-settings-attr-custom-name = let
    settingsMod = nixcfgLib.mkModule {
      schema = ../examples/mycel.json;
      settingsAttr = "config";
    };
    settingsEvaled = lib.evalModules {modules = [settingsMod];};
    settingsModOpts = settingsEvaled.options.services.mycel;
  in
    assert settingsModOpts ? enable;
    assert settingsModOpts ? config;
    assert !(settingsModOpts ? settings);
      ok "settings-attr-custom-name";

  # ── name conversion functions ─────────────────────────────────────

  nix-name-conversions = assert nixcfgLib.snakeToCamel "data_dir" == "dataDir";
  assert nixcfgLib.snakeToCamel "a" == "a";
  assert nixcfgLib.snakeToCamel "a_b_c" == "aBC";
  assert nixcfgLib.snakeToKebab "data_dir" == "data-dir";
  assert nixcfgLib.snakeToScreaming "data_dir" == "DATA_DIR";
    ok "name-conversions";

  # ── nix driver (from-options) ─────────────────────────────────────

  nix-driver-types = let
    # simple type mapping tests
    t = nixcfgLib.typeToSchema;
  in
    assert (t lib.types.str).type == "string";
    assert (t lib.types.bool).type == "boolean";
    assert (t lib.types.int).type == "integer";
    assert (t lib.types.ints.unsigned).minimum == 0;
    # port is indistinguishable from u16 in the type system
    assert (t lib.types.port).minimum == 0;
    assert (t lib.types.port).maximum == 65535;
    assert (t (lib.types.enum ["a" "b"])).enum == ["a" "b"];
    assert (t (lib.types.listOf lib.types.str)).type == "array";
    assert (t (lib.types.attrsOf lib.types.str)).type == "object";
    assert (t (lib.types.attrsOf lib.types.str)) ? additionalProperties;
    assert (t (lib.types.nullOr lib.types.str)).type == ["string" "null"];
      ok "driver-types";

  nix-driver-module = let
    testModule = {lib, ...}: {
      options.test-app = {
        host = lib.mkOption {
          type = lib.types.str;
          default = "localhost";
          description = "server hostname";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 8080;
          description = "listen port";
        };
        debug = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable debug mode";
        };
        tags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "metadata tags";
        };
        level = lib.mkOption {
          type = lib.types.enum ["info" "warn" "error"];
          default = "info";
          description = "log level";
        };
        extra = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "optional extra";
        };
        labels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "key-value labels";
        };
      };
    };

    schema = nixcfgLib.schemaFromModule {
      module = testModule;
      name = "test-app";
      description = "test application";
      path = ["test-app"];
    };

    p = schema.properties;
  in
    # schema metadata
    assert schema."x-nixcfg-name" == "test-app";
    assert schema.description == "test application";
    assert schema.type == "object";
    # types mapped correctly
    assert p.host.type == "string";
    assert p.host.default == "localhost";
    assert p.port.type == "integer";
    assert p.port.minimum == 0;
    assert p.port.default == 8080;
    assert p.debug.type == "boolean";
    assert p.tags.type == "array";
    assert p.level ? enum;
    assert p.level.enum == ["info" "warn" "error"];
    assert p.extra.type == ["string" "null"];
    assert p.labels.type == "object";
    assert p.labels ? additionalProperties;
      ok "driver-module";

  nix-driver-roundtrip = let
    # generate schema from a nix module, then consume it back with mkModule
    testModule = {lib, ...}: {
      options.roundtrip = {
        host = lib.mkOption {
          type = lib.types.str;
          default = "0.0.0.0";
          description = "bind address";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 3000;
          description = "listen port";
        };
        verbose = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "verbose output";
        };
      };
    };

    # step 1: nix options → JSON Schema
    schema = nixcfgLib.schemaFromModule {
      module = testModule;
      name = "roundtrip";
      description = "roundtrip test";
      path = ["roundtrip"];
    };

    # step 2: JSON Schema → nix module (via mkModule)
    generatedMod = nixcfgLib.mkModule {
      inherit schema;
      naming = "snake_case";
    };

    evaled = lib.evalModules {modules = [generatedMod];};
    opts = evaled.options.services.roundtrip;
  in
    assert opts ? enable;
    assert opts ? host;
    assert opts ? port;
    assert opts ? verbose;
    assert opts.host.default == "0.0.0.0";
    assert opts.port.default == 3000;
    # with format-aware mapping, port roundtrips perfectly as unsignedInt16
    # (from-options emits format: "uint16", mapType picks types.ints.u16)
    assert opts.port.type.name == "unsignedInt16";
    assert !opts.verbose.default;
      ok "driver-roundtrip";

  # ── config format extension ───────────────────────────────────────

  nix-config-format-toml = let
    schema = builtins.fromJSON (builtins.toJSON (simple
      // {
        "x-nixcfg-config-format" = "toml";
      }));
    result = nixcfgLib.mkConfigFile {
      inherit schema pkgs;
      settings = {
        dataDir = "/var/lib/mycel";
        model = "claude-sonnet-4-20250514";
        logLevel = "info";
        cacheWarming = true;
        discordTokenPath = "/run/secrets/token";
      };
    };
  in
    # result is a store path derivation
    assert result != null;
    assert lib.hasSuffix "mycel-config.toml" (builtins.unsafeDiscardStringContext "${result}");
      ok "config-format-toml";

  nix-config-format-json = let
    schema = builtins.fromJSON (builtins.toJSON (simple
      // {
        "x-nixcfg-config-format" = "json";
      }));
    result = nixcfgLib.mkConfigFile {
      inherit schema pkgs;
      settings = {
        dataDir = "/tmp/test";
        model = "test";
        logLevel = "info";
        cacheWarming = false;
        discordTokenPath = "/run/secrets/token";
      };
    };
  in
    assert result != null;
    assert lib.hasSuffix "mycel-config.json" (builtins.unsafeDiscardStringContext "${result}");
      ok "config-format-json";

  # ── modular service generation ──────────────────────────────────────

  nix-modular-service = let
    svc = nixcfgLib.mkModularService {
      schema = ../examples/mycel.json;
      naming = "snake_case";
      mkArgv = cfg: [
        "mycel"
        "--data-dir"
        cfg.data_dir
        "--model"
        cfg.model
      ];
    };
    # evaluate as a standalone module (without nixpkgs portable service infra)
    # just check that the module function produces the right structure
    mod = svc {
      config = {
        mycel = {
          data_dir = "/var/lib/mycel";
          model = "claude-sonnet-4-20250514";
          log_level = "info";
          cache_warming = false;
          discord_token_path = "/run/secrets/token";
          anthropic_key_path = null;
          package = pkgs.hello;
        };
      };
      options = {};
      inherit lib;
    };
  in
    assert mod._class == "service";
    assert mod ? options;
    assert mod.options ? mycel;
    assert mod.options.mycel ? data_dir;
    assert mod.options.mycel ? package;
    assert mod.config.process.argv == ["mycel" "--data-dir" "/var/lib/mycel" "--model" "claude-sonnet-4-20250514"];
      ok "modular-service";

  # ── x-nixcfg-skip ──────────────────────────────────────────────────

  nix-x-nixcfg-skip = let
    schemaWithSkip = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "SkipTest";
      type = "object";
      "x-nixcfg-name" = "skip-test";
      properties = {
        normal_field = {
          type = "string";
          description = "shown in nix module";
          default = "hi";
        };
        runtime_handle = {
          type = "object";
          description = "runtime-only, excluded from module";
          "x-nixcfg-skip" = true;
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schemaWithSkip;
    # cli / env / config transforms still iterate all properties; if cfg
    # happens to carry a value (e.g. via extraOverrides), it's emitted
    cfg = {
      normalField = "ok";
      runtimeHandle = null;
    };
    cli = nixcfgLib.toCliArgs {} schemaWithSkip cfg;
  in
    # skipped field does not appear in module options
    assert opts ? normalField;
    assert !(opts ? runtimeHandle);
    # cli gracefully omits the skipped field (null value)
    assert hasPair cli "--normal-field" "ok";
    assert lacksFlag cli "--runtime-handle";
      ok "x-nixcfg-skip";

  # ── x-nixcfg-path ──────────────────────────────────────────────────

  nix-x-nixcfg-path = let
    schemaWithPath = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "PathTest";
      type = "object";
      "x-nixcfg-name" = "path-test";
      properties = {
        config_path = {
          type = "string";
          description = "path to config file";
          "x-nixcfg-path" = true;
        };
        optional_path = {
          type = ["string" "null"];
          description = "optional override path";
          "x-nixcfg-path" = true;
        };
        # schemars emits format: "path" for PathBuf, auto-detected
        auto_path = {
          type = "string";
          format = "path";
          description = "auto-detected path via format";
        };
        plain_str = {
          type = "string";
          description = "still just a string";
          default = "hi";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schemaWithPath;
  in
    assert opts.configPath.type.name == "path";
    assert opts.optionalPath.type.name == "nullOr";
    assert opts.optionalPath.type.nestedTypes.elemType.name == "path";
    assert opts.autoPath.type.name == "path";
    # non-path strings are unaffected
    assert opts.plainStr.type.name == "str";
      ok "x-nixcfg-path";

  # ── anyOf bool-or-enum (legacy union handling) ─────────────────────

  nix-anyof-bool-enum = let
    schemaWithUnion = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "UnionTest";
      type = "object";
      "x-nixcfg-name" = "union-test";
      "$defs" = {
        ThinkingLevel = {
          type = "string";
          enum = ["low" "medium" "high"];
        };
      };
      properties = {
        # real-world schemars shape: config accepts true / false / "high" /
        # "medium" / "low" for back-compat
        thinking = {
          anyOf = [
            {type = "boolean";}
            {"$ref" = "#/$defs/ThinkingLevel";}
          ];
          description = "thinking level or bool toggle";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schemaWithUnion;
    t = opts.thinking.type;
  in
    # chained either gives types.either bool (types.enum [...])
    assert t.name == "either";
    assert t.nestedTypes.left.name == "bool";
    assert t.nestedTypes.right.name == "enum";
      ok "anyof-bool-enum";

  # ── format-aware integer mapping ──────────────────────────────────

  nix-integer-formats = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "IntFormats";
      type = "object";
      "x-nixcfg-name" = "int-formats";
      properties = {
        small_unsigned = {
          type = "integer";
          format = "uint8";
          description = "byte";
        };
        small_signed = {
          type = "integer";
          format = "int8";
          description = "signed byte";
        };
        sample_count = {
          type = "integer";
          format = "uint16";
          description = "count";
        };
        big_unsigned = {
          type = "integer";
          format = "uint32";
          description = "large count";
        };
        # bounds-only fallback (no format): should give ints.between
        percent = {
          type = "integer";
          minimum = 0;
          maximum = 100;
          description = "percentage";
        };
        # minimum 0 only: unsigned
        any_positive = {
          type = "integer";
          minimum = 0;
          description = "any non-negative";
        };
        # no bounds: plain int
        arbitrary = {
          type = "integer";
          description = "any integer";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
  in
    assert opts.smallUnsigned.type.name == "unsignedInt8";
    assert opts.smallSigned.type.name == "signedInt8";
    assert opts.sampleCount.type.name == "unsignedInt16";
    assert opts.bigUnsigned.type.name == "unsignedInt32";
    assert opts.percent.type.name == "intBetween";
    assert opts.anyPositive.type.name == "unsignedInt";
    assert opts.arbitrary.type.name == "int";
      ok "integer-formats";

  # ── description / example overrides ───────────────────────────────

  nix-description-override = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "DescTest";
      type = "object";
      "x-nixcfg-name" = "desc-test";
      properties = {
        terse = {
          type = "string";
          description = "cwd";
          "x-nixcfg-description" = "working directory used when invoking configured lifecycle hooks. defaults to the directory the app was launched from";
          default = ".";
        };
        no_override = {
          type = "string";
          description = "unchanged";
          default = "x";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
  in
    # override wins
    assert lib.hasPrefix "working directory used" opts.terse.description;
    # no override: description passes through
    assert opts.noOverride.description == "unchanged";
      ok "description-override";

  nix-example-override = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "ExampleTest";
      type = "object";
      "x-nixcfg-name" = "example-test";
      properties = {
        # explicit override takes precedence
        with_override = {
          type = "string";
          examples = ["from-examples-array"];
          "x-nixcfg-example" = "from-extension";
          default = "x";
        };
        # fallback: first of examples
        from_examples = {
          type = "string";
          examples = ["first" "second"];
          default = "x";
        };
        # no example data at all
        no_example = {
          type = "string";
          default = "x";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
  in
    assert opts.withOverride.example == "from-extension";
    assert opts.fromExamples.example == "first";
    assert !(opts.noExample ? example);
      ok "example-override";

  # ── string validation (pattern, minLength, maxLength) ─────────────

  nix-string-pattern = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "PatternTest";
      type = "object";
      "x-nixcfg-name" = "pattern-test";
      properties = {
        username = {
          type = "string";
          pattern = "^[a-z]+$";
          description = "lowercase only";
          default = "admin";
        };
        plain = {
          type = "string";
          description = "no pattern";
          default = "x";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
  in
    # pattern → types.strMatching (name includes the pattern: `strMatching "..."`)
    assert lib.hasPrefix "strMatching" opts.username.type.name;
    assert opts.username.type.check "hello";
    assert !(opts.username.type.check "Hello123");
    # no pattern → plain str
    assert opts.plain.type.name == "str";
      ok "string-pattern";

  nix-string-length = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "LengthTest";
      type = "object";
      "x-nixcfg-name" = "length-test";
      properties = {
        short_name = {
          type = "string";
          minLength = 1;
          maxLength = 8;
          description = "1-8 chars";
          default = "x";
        };
        min_only = {
          type = "string";
          minLength = 3;
          default = "abc";
        };
        max_only = {
          type = "string";
          maxLength = 5;
          default = "hi";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
  in
    # addCheck preserves the base type's name ("str")
    assert opts.shortName.type.name == "str";
    assert opts.shortName.type.check "hi";
    assert !(opts.shortName.type.check "");
    assert !(opts.shortName.type.check "way-too-long");
    # min only: rejects empty
    assert !(opts.minOnly.type.check "ab");
    assert opts.minOnly.type.check "abc";
    # max only: rejects overlong
    assert opts.maxOnly.type.check "short";
    assert !(opts.maxOnly.type.check "too-long");
      ok "string-length";

  nix-string-pattern-and-length = let
    schema = {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "SlugTest";
      type = "object";
      "x-nixcfg-name" = "slug-test";
      properties = {
        slug = {
          type = "string";
          pattern = "^[a-z0-9-]+$";
          minLength = 3;
          maxLength = 16;
          description = "url slug";
          default = "abc";
        };
      };
    };
    opts = nixcfgLib.optionsFromSchema {} schema;
    t = opts.slug.type;
  in
    # combined: strMatching base with length addChecks on top
    assert lib.hasPrefix "strMatching" t.name;
    # valid: matches pattern and within bounds
    assert t.check "hello-world";
    # fails pattern
    assert !(t.check "HELLO");
    # fails min length
    assert !(t.check "ab");
    # fails max length
    assert !(t.check "a-very-long-slug-that-exceeds");
      ok "string-pattern-and-length";
}
