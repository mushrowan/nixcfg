# nixcfg - generate NixOS module options from a language-agnostic schema
{lib}: let
  # -- name conversions --

  snakeToCamel = s: let
    parts = lib.splitString "_" s;
    capitalize = str:
      lib.toUpper (builtins.substring 0 1 str)
      + builtins.substring 1 (builtins.stringLength str - 1) str;
  in
    builtins.head parts + lib.concatMapStrings capitalize (builtins.tail parts);

  snakeToKebab = builtins.replaceStrings ["_"] ["-"];

  snakeToScreaming = s: lib.toUpper s;

  # resolve a naming convention string to a transform function
  # all transforms take a snake_case input (the schema convention)
  namingTransform = naming: {
    "camelCase" = snakeToCamel;
    "snake_case" = s: s;
    "kebab-case" = snakeToKebab;
    "SCREAMING_SNAKE_CASE" = snakeToScreaming;
  }.${naming} or (throw "nixcfg: unknown naming convention '${naming}', expected one of: camelCase, snake_case, kebab-case, SCREAMING_SNAKE_CASE");

  # -- type helpers --

  isOptionalType = type:
    builtins.isAttrs type && type ? optional;

  # the "leaf" type for special-casing bools/lists in config generation
  leafType = type:
    if builtins.isString type
    then type
    else if type ? optional
    then leafType type.optional
    else "complex";

  # map a schema type to a nix type
  # toNixName is threaded through so submodule children use the same naming
  mapType = toNixName: type:
    if builtins.isString type
    then
      {
        "string" = lib.types.str;
        "bool" = lib.types.bool;
        "int" = lib.types.int;
        "uint" = lib.types.ints.unsigned;
        "path" = lib.types.path;
        "port" = lib.types.port;
      }
      .${type}
      or (throw "nixcfg: unknown simple type '${type}'")
    else if type ? optional
    then lib.types.nullOr (mapType toNixName type.optional)
    else if type ? list
    then lib.types.listOf (mapType toNixName type.list)
    else if type ? attrs
    then lib.types.attrsOf (mapType toNixName type.attrs)
    else if type ? enum
    then lib.types.enum type.enum
    else if type ? submodule
    then lib.types.submodule {options = mapOptions toNixName type.submodule {};}
    else throw "nixcfg: unknown type ${builtins.toJSON type}";

  # -- option generation --

  # compute the nix attr name for a schema option
  # the secret suffix style matches the naming convention:
  #   camelCase  → discord_token → discordTokenFile
  #   snake_case → discord_token → discord_token_file
  nixNameFor = toNixName: name: opt:
    if (opt.secret or false)
    then toNixName "${name}_file"
    else toNixName name;

  mapOption = toNixName: name: opt: override: let
    isSecret = opt.secret or false;
    isOptional = isOptionalType opt.type;

    nixName = nixNameFor toNixName name opt;

    nixType =
      if isSecret
      then
        (
          if isOptional
          then lib.types.nullOr lib.types.path
          else lib.types.path
        )
      else mapType toNixName opt.type;

    baseDesc = opt.description or "";
    nixDesc =
      if isSecret
      then "path to file containing ${baseDesc}"
      else baseDesc;

    nixDefault =
      if isSecret && isOptional
      then {default = null;}
      else if isSecret
      then {}
      else if opt ? default
      then {default = opt.default;}
      else if isOptional
      then {default = null;}
      else {};
    baseArgs =
      {
        type = nixType;
      }
      // lib.optionalAttrs (nixDesc != "") {description = nixDesc;}
      // nixDefault
      // lib.optionalAttrs (opt ? example && !isSecret) {example = opt.example;};

    # merge override attrs on top of generated args
    finalArgs = baseArgs // override;
  in {
    ${nixName} = lib.mkOption finalArgs;
  };

  mapOptions = toNixName: options: overrides:
    lib.foldl' (acc: name:
      acc // mapOption toNixName name options.${name} (overrides.${name} or {})
    ) {} (builtins.attrNames options);

  # -- public: option generation --

  optionsFromSchema = {naming ? "camelCase"}: schema: let
    _ = assert schema.version == 1; null;
  in
    mapOptions (namingTransform naming) schema.options {};

  optionsFromFile = {naming ? "camelCase"}: path:
    optionsFromSchema {inherit naming;} (builtins.fromJSON (builtins.readFile path));

  # -- public: NixOS module generation --

  mkModule = {
    schema,
    naming ? "camelCase",
    prefix ? ["services"],
    settingsAttr ? null,
    overrides ? {},
    extraOverrides ? {},
  }: let
    parsed =
      if builtins.isAttrs schema
      then schema
      else builtins.fromJSON (builtins.readFile schema);

    toNixName = namingTransform naming;

    # validate override keys exist in schema
    unknownOverrides = builtins.filter
      (k: !(parsed.options ? ${k}))
      (builtins.attrNames overrides);
    validation =
      if unknownOverrides != []
      then builtins.throw "nixcfg: override keys not found in schema: ${builtins.concatStringsSep ", " unknownOverrides}. use extraOverrides for non-schema options"
      else true;

    opts = builtins.seq validation (mapOptions toNixName parsed.options overrides);

    # extraOverrides are added as-is (keys used directly as option names)
    extraOpts = lib.mapAttrs (_: attrs: lib.mkOption attrs) extraOverrides;

    optionPath = prefix ++ [parsed.name];

    # schema options go either flat or nested under settingsAttr
    schemaOpts = opts // extraOpts;
    topLevel =
      {enable = lib.mkEnableOption (parsed.description or parsed.name);}
      // (
        if settingsAttr != null
        then {
          ${settingsAttr} = lib.mkOption {
            type = lib.types.submodule {options = schemaOpts;};
            default = {};
            description = "configuration options for ${parsed.name}";
          };
        }
        else schemaOpts
      );
  in
    {config, ...}: {
      options = lib.setAttrByPath optionPath topLevel;
    };

  # -- public: config conversion helpers --

  toCliArgs = {naming ? "camelCase", output ? "kebab-case"}: schema: cfg: let
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
    outputName = name: opt:
      let isSecret = opt.secret or false;
      in toOutput (if isSecret then "${name}_file" else name);
  in
    lib.concatLists (lib.mapAttrsToList (
        name: opt: let
          isSecret = opt.secret or false;
          nixName = nixNameFor toNixName name opt;
          flag = "--${outputName name opt}";
          value = cfg.${nixName} or null;
          leaf = leafType opt.type;
        in
          if value == null
          then []
          # submodules and attrs don't have a CLI representation
          else if opt.type ? submodule || opt.type ? attrs
          then []
          else if isSecret
          then [flag (toString value)]
          else if leaf == "bool"
          then lib.optional value flag
          else if opt.type ? list
          then lib.concatMap (v: [flag (toString v)]) value
          else [flag (toString value)]
      )
      schema.options);

  toEnvVars = {naming ? "camelCase", output ? "SCREAMING_SNAKE_CASE"}: schema: cfg: let
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
  in
    lib.foldl' (
      acc: name: let
        opt = schema.options.${name};
        isSecret = opt.secret or false;
        nixName = nixNameFor toNixName name opt;
        envName = toOutput (
          if isSecret
          then "${name}_file"
          else name
        );
        value = cfg.${nixName} or null;
        leaf = leafType opt.type;
      in
        if value == null
        then acc
        else if leaf == "bool"
        then acc // {${envName} = lib.boolToString value;}
        else if opt.type ? list
        then acc // {${envName} = lib.concatMapStringsSep "," toString value;}
        else acc // {${envName} = toString value;}
    ) {} (builtins.attrNames schema.options);

  toConfigAttrs = {naming ? "camelCase", output ? "snake_case"}: schema: cfg: let
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
  in
    lib.foldl' (
      acc: name: let
        opt = schema.options.${name};
        isSecret = opt.secret or false;
        nixName = nixNameFor toNixName name opt;
        attrName = toOutput (
          if isSecret
          then "${name}_file"
          else name
        );
        value = cfg.${nixName} or null;
      in
        if value == null
        then acc
        else acc // {${attrName} = value;}
    ) {} (builtins.attrNames schema.options);

  debugLib = import ./debug.nix {inherit lib nixcfgLib;};

  nixcfgLib = {
    inherit
      optionsFromSchema
      optionsFromFile
      mkModule
      toCliArgs
      toEnvVars
      toConfigAttrs
      mapType
      mapOptions
      namingTransform
      snakeToCamel
      snakeToKebab
      snakeToScreaming
      nixNameFor
      ;

    # pure debug helpers (no pkgs needed)
    inherit (debugLib) fmtSchema;

    # create a pkgs-bound lib (like crane.mkLib)
    mkLib = pkgs: nixcfgLib // {
      # debug app that pretty-prints a schema as nix options
      mkDebugApp = {schema, naming ? "camelCase"}: debugLib.mkDebugApp {inherit schema pkgs naming;};
    };
  };
in
  nixcfgLib
