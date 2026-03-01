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
  mapType = type:
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
    then lib.types.nullOr (mapType type.optional)
    else if type ? list
    then lib.types.listOf (mapType type.list)
    else if type ? attrs
    then lib.types.attrsOf (mapType type.attrs)
    else if type ? enum
    then lib.types.enum type.enum
    else if type ? submodule
    then lib.types.submodule {options = mapOptions type.submodule;}
    else throw "nixcfg: unknown type ${builtins.toJSON type}";

  # -- option generation --

  mapOption = name: opt: let
    isSecret = opt.secret or false;
    isOptional = isOptionalType opt.type;

    nixBaseName = snakeToCamel name;
    nixName =
      if isSecret
      then "${nixBaseName}File"
      else nixBaseName;

    nixType =
      if isSecret
      then
        (
          if isOptional
          then lib.types.nullOr lib.types.path
          else lib.types.path
        )
      else mapType opt.type;

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
  in {
    ${nixName} = lib.mkOption (
      {
        type = nixType;
      }
      // lib.optionalAttrs (nixDesc != "") {description = nixDesc;}
      // nixDefault
      // lib.optionalAttrs (opt ? example && !isSecret) {example = opt.example;}
    );
  };

  mapOptions = options:
    lib.foldl' (acc: name: acc // mapOption name options.${name}) {} (builtins.attrNames options);

  # -- public: option generation --

  optionsFromSchema = schema: let
    _ = assert schema.version == 1; null;
  in
    mapOptions schema.options;

  optionsFromFile = path:
    optionsFromSchema (builtins.fromJSON (builtins.readFile path));

  # -- public: NixOS module generation --

  mkModule = {
    schema,
    prefix ? ["services"],
  }: let
    parsed =
      if builtins.isAttrs schema
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    opts = optionsFromSchema parsed;
    optionPath = prefix ++ [parsed.name];
  in
    {config, ...}: {
      options = lib.setAttrByPath optionPath (
        {
          enable = lib.mkEnableOption (parsed.description or parsed.name);
        }
        // opts
      );
    };

  # -- public: config conversion helpers --

  # compute the nix attr name for a schema option
  nixNameFor = name: opt: let
    base = snakeToCamel name;
  in
    if (opt.secret or false)
    then "${base}File"
    else base;

  # convert evaluated NixOS config to a list of CLI argument strings
  #
  # schema: parsed schema (the JSON as a nix attrset)
  # cfg:    the evaluated config attrset (camelCase keys, e.g. config.services.mycel)
  #
  # returns a list of strings suitable for lib.escapeShellArgs
  #
  # rules:
  #   - null values are skipped
  #   - bool true  → ["--flag"],  bool false → [] (omitted)
  #   - list       → ["--flag" "v1" "--flag" "v2" ...]
  #   - secret     → ["--name-file" "/path"]
  #   - everything else → ["--flag" "value"]
  toCliArgs = schema: cfg:
    lib.concatLists (lib.mapAttrsToList (
        name: opt: let
          isSecret = opt.secret or false;
          nixName = nixNameFor name opt;
          flag = "--${snakeToKebab name}${lib.optionalString isSecret "-file"}";
          value = cfg.${nixName} or null;
          leaf = leafType opt.type;
        in
          if value == null
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

  # convert evaluated NixOS config to an attrset of environment variables
  #
  # rules:
  #   - null values are skipped
  #   - bool → "true" / "false"
  #   - list → comma-separated
  #   - names are SCREAMING_SNAKE_CASE, secrets get _FILE suffix
  toEnvVars = schema: cfg:
    lib.foldl' (
      acc: name: let
        opt = schema.options.${name};
        isSecret = opt.secret or false;
        nixName = nixNameFor name opt;
        envName = snakeToScreaming (
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

  # convert evaluated NixOS config back to a JSON-serialisable attrset
  # with snake_case keys (matching the schema), suitable for writing a
  # config file
  #
  # secrets are included as `name_file` keys
  toConfigAttrs = schema: cfg:
    lib.foldl' (
      acc: name: let
        opt = schema.options.${name};
        isSecret = opt.secret or false;
        nixName = nixNameFor name opt;
        attrName =
          if isSecret
          then "${name}_file"
          else name;
        value = cfg.${nixName} or null;
      in
        if value == null
        then acc
        else acc // {${attrName} = value;}
    ) {} (builtins.attrNames schema.options);
in {
  inherit
    optionsFromSchema
    optionsFromFile
    mkModule
    toCliArgs
    toEnvVars
    toConfigAttrs
    mapType
    mapOptions
    snakeToCamel
    snakeToKebab
    snakeToScreaming
    nixNameFor
    ;
}
