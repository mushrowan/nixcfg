# nix lib checks for nixcfg
{
  lib,
  pkgs,
  nixcfgLib,
  craneLib,
}: let
  # -- schemas --
  simple = builtins.fromJSON (builtins.readFile ../examples/mycel.json);
  complex = builtins.fromJSON (builtins.readFile ../examples/complex.json);

  # -- helper --
  ok = name: pkgs.runCommand "nixcfg-${name}" {} "touch $out";

  # find a flag-value pair in a list of CLI args (handles repeated flags)
  hasPair = args: flag: val: let
    len = builtins.length args;
    check = i:
      if i >= len - 1
      then false
      else if builtins.elemAt args i == flag && builtins.elemAt args (i + 1) == val
      then true
      else check (i + 1);
  in check 0;

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
    labels = {env = "production"; tier = "frontend";};
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
    assert o.workers.type.name == "unsignedInt";
    assert o.maxRetries.type.name == "int";
    assert o.dataDir.type.name == "path";
    # enum
    assert o.logLevel.type.name == "enum";
    # optional
    assert o.optionalFeature.type.name == "nullOr";
    # list
    assert o.tags.type.name == "listOf";
    # attrs
    assert o.labels.type.name == "attrsOf";
    # submodule
    assert o.database.type.name == "submodule";
    # nested optional list
    assert o.allowedOrigins.type.name == "nullOr";
    # secrets become path
    assert o.apiKeyPath.type.name == "path";
    # optional secret becomes nullOr path
    assert o.dbPasswordPath.type.name == "nullOr";
      ok "types";

  # ── secrets ───────────────────────────────────────────────────────

  nix-secrets =
    # file suffix applied
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

  nix-defaults =
    assert complexOpts.hostname.default == "localhost";
    assert complexOpts.port.default == 8080;
    assert complexOpts.debug.default == false;
    assert complexOpts.workers.default == 4;
    assert complexOpts.maxRetries.default == (-1);
    assert complexOpts.dataDir.default == "/var/lib/complex";
    assert complexOpts.tags.default == [];
    assert complexOpts.logLevel.default == "info";
    assert complexOpts.optionalFeature.default == null;
      ok "defaults";

  # ── module generation ─────────────────────────────────────────────

  nix-module-simple =
    assert simpleModOpts ? enable;
    assert simpleModOpts ? dataDir;
    assert simpleModOpts ? discordTokenPath;
    assert simpleModOpts ? logLevel;
      ok "module-simple";

  nix-module-complex =
    assert complexModOpts ? enable;
    assert complexModOpts ? hostname;
    assert complexModOpts ? port;
    assert complexModOpts ? database;
    assert complexModOpts ? apiKeyPath;
    assert complexModOpts ? tags;
    assert complexModOpts ? allowedOrigins;
      ok "module-complex";

  nix-module-prefix =
    assert prefixEvaled.options.programs ? mycel;
    assert prefixEvaled.options.programs.mycel ? enable;
      ok "module-prefix";

  # ── CLI args ──────────────────────────────────────────────────────

  nix-cli-simple =
    assert hasPair simpleCli "--data-dir" "/var/lib/mycel";
    assert hasPair simpleCli "--model" "claude-sonnet-4-20250514";
    assert hasPair simpleCli "--log-level" "info";
    assert hasFlag simpleCli "--cache-warming";
    assert hasPair simpleCli "--discord-token-path" "/run/secrets/discord";
    assert lacksFlag simpleCli "--anthropic-key-path";
      ok "cli-simple";

  nix-cli-complex =
    assert hasPair complexCli "--hostname" "0.0.0.0";
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

  nix-env-simple =
    assert simpleEnv.DATA_DIR == "/var/lib/mycel";
    assert simpleEnv.MODEL == "claude-sonnet-4-20250514";
    assert simpleEnv.CACHE_WARMING == "true";
    assert simpleEnv.DISCORD_TOKEN_PATH == "/run/secrets/discord";
    assert !(simpleEnv ? ANTHROPIC_KEY_PATH);
      ok "env-simple";

  nix-env-complex =
    assert complexEnv.HOSTNAME == "0.0.0.0";
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

  nix-config-simple =
    assert simpleConfig.data_dir == "/var/lib/mycel";
    assert simpleConfig.model == "claude-sonnet-4-20250514";
    assert simpleConfig.cache_warming == true;
    assert simpleConfig.discord_token_path == "/run/secrets/discord";
    assert !(simpleConfig ? anthropic_key_path);
      ok "config-simple";

  nix-config-complex =
    assert complexConfig.hostname == "0.0.0.0";
    assert complexConfig.port == 9090;
    assert complexConfig.debug == true;
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

  nix-overrides =
    assert overrideOpts ? dataDir;
    assert overrideOpts.dataDir.description == "overridden description";
      ok "overrides";

  nix-extra-overrides =
    assert overrideOpts ? package;
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

  nix-name-conversions =
    assert nixcfgLib.snakeToCamel "data_dir" == "dataDir";
    assert nixcfgLib.snakeToCamel "a" == "a";
    assert nixcfgLib.snakeToCamel "a_b_c" == "aBC";
    assert nixcfgLib.snakeToKebab "data_dir" == "data-dir";
    assert nixcfgLib.snakeToScreaming "data_dir" == "DATA_DIR";
      ok "name-conversions";
}
