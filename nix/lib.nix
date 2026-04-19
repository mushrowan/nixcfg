# nixcfg - generate NixOS module options from JSON Schema
#
# consumes standard JSON Schema (draft 2020-12) with nixcfg extensions:
#   x-nixcfg-name:        service/program name
#   x-nixcfg-secret:      marks a field as a secret (type → path, name gets _path suffix)
#   x-nixcfg-port:        marks an integer as a port (type → types.port)
#   x-nixcfg-path:        marks a string as a path (type → types.path)
#   x-nixcfg-skip:        omit property from nix module options
#   x-nixcfg-description: override description (takes precedence over description)
#   x-nixcfg-example:     override example (takes precedence over first of examples)
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
  namingTransform = naming:
    {
      "camelCase" = snakeToCamel;
      "snake_case" = s: s;
      "kebab-case" = snakeToKebab;
      "SCREAMING_SNAKE_CASE" = snakeToScreaming;
    }.${
      naming
    } or (throw "nixcfg: unknown naming convention '${naming}', expected one of: camelCase, snake_case, kebab-case, SCREAMING_SNAKE_CASE");

  # -- $ref resolution --

  # resolve a $ref string like "#/$defs/Foo" against the root schema
  resolveRef = root: ref: let
    # strip leading "#/"
    path = lib.splitString "/" (lib.removePrefix "#/" ref);
  in
    lib.getAttrFromPath path root;

  # -- type mapping --

  # map a JSON Schema property to a nix type
  # root: the full schema (for $ref resolution)
  # toNixName: naming transform function
  # prop: the property schema object
  mapType = root: toNixName: prop: let
    # resolve $ref first (merge with any sibling properties like description)
    resolved =
      if prop ? "$ref"
      then (resolveRef root prop."$ref") // (builtins.removeAttrs prop ["$ref"])
      else prop;

    type = resolved.type or null;
    isPort = resolved."x-nixcfg-port" or false;
    # opt-in via extension, or auto-detected from schemars PathBuf (format: "path")
    isPath =
      (resolved."x-nixcfg-path" or false)
      || (resolved.format or "") == "path";
  in
    # nullable type: ["string", "null"] or ["integer", "null"] etc
    if builtins.isList type
    then let
      nonNull = builtins.filter (t: t != "null") type;
      inner = mapType root toNixName (resolved // {type = builtins.head nonNull;});
    in
      lib.types.nullOr inner
    # port override
    else if isPort
    then lib.types.port
    # path override (explicit x-nixcfg-path or schemars format: "path")
    else if isPath
    then lib.types.path
    # simple types
    else if type == "string" && resolved ? enum
    then lib.types.enum resolved.enum
    else if type == "string"
    then let
      # base string type: pattern → strMatching, else str
      baseStr =
        if resolved ? pattern
        then lib.types.strMatching resolved.pattern
        else lib.types.str;
      # compose minLength / maxLength via addCheck
      withMin =
        if resolved ? minLength
        then lib.types.addCheck baseStr (s: builtins.stringLength s >= resolved.minLength)
        else baseStr;
    in
      if resolved ? maxLength
      then lib.types.addCheck withMin (s: builtins.stringLength s <= resolved.maxLength)
      else withMin
    else if type == "boolean"
    then lib.types.bool
    else if type == "integer"
    then let
      fmt = resolved.format or "";
      hasMin = resolved ? minimum;
      hasMax = resolved ? maximum;
    in
      # schemars emits format strings matching rust primitive names
      if fmt == "int8"
      then lib.types.ints.s8
      else if fmt == "int16"
      then lib.types.ints.s16
      else if fmt == "int32"
      then lib.types.ints.s32
      else if fmt == "uint8"
      then lib.types.ints.u8
      else if fmt == "uint16"
      then lib.types.ints.u16
      else if fmt == "uint32"
      then lib.types.ints.u32
      # bounds-aware fallback: full min/max range as ints.between
      else if hasMin && hasMax
      then lib.types.ints.between resolved.minimum resolved.maximum
      # minimum 0 only → unsigned
      else if hasMin && resolved.minimum == 0
      then lib.types.ints.unsigned
      # fallback: plain signed int
      else lib.types.int
    # array
    else if type == "array"
    then lib.types.listOf (mapType root toNixName (resolved.items or {type = "string";}))
    # object with properties → submodule
    else if type == "object" && resolved ? properties
    then
      lib.types.submodule {
        options = mapProperties root toNixName resolved {};
      }
    # object with additionalProperties → attrsOf
    else if type == "object" && resolved ? additionalProperties
    then lib.types.attrsOf (mapType root toNixName resolved.additionalProperties)
    # object (bare) → attrsOf str
    else if type == "object"
    then lib.types.attrsOf lib.types.str
    # anyOf: nullable refs like [{$ref: ...}, {type: "null"}], or unions
    # like [{type: "boolean"}, {$ref: "#/$defs/Level"}] (bool-or-enum legacy)
    else if resolved ? anyOf
    then let
      variants = resolved.anyOf;
      nullVariants = builtins.filter (v: (v.type or null) == "null") variants;
      nonNull = builtins.filter (v: (v.type or null) != "null") variants;
      isNullable = builtins.length nullVariants > 0;
      inner =
        if builtins.length nonNull == 1
        then mapType root toNixName (builtins.head nonNull)
        # multiple non-null variants: chain types.either across all of them.
        # for the common bool-or-enum case this yields
        # `types.either types.bool (types.enum [...])`
        else let
          mapped = map (mapType root toNixName) nonNull;
        in
          lib.foldl' (acc: t: lib.types.either acc t)
          (builtins.head mapped) (builtins.tail mapped);
    in
      if isNullable
      then lib.types.nullOr inner
      else inner
    # oneOf: string enums (all variants have const + type:string) or tagged unions
    else if resolved ? oneOf
    then let
      variants = resolved.oneOf;
      # check if this is a simple string enum (all variants are {const: "...", type: "string"})
      isStringEnum =
        builtins.all (
          v:
            v ? const && (v.type or null) == "string"
        )
        variants;
    in
      if isStringEnum
      then lib.types.enum (map (v: v.const) variants)
      else lib.types.attrsOf lib.types.anything
    # fallback: try as string
    else lib.types.str;

  # -- option generation --

  # compute the nix attr name for a schema property
  nixNameFor = toNixName: name: prop:
    if (prop."x-nixcfg-secret" or false)
    then toNixName "${name}_path"
    else toNixName name;

  # map a single property to a nix option
  mapProperty = root: toNixName: name: prop: override: let
    # resolve $ref
    resolved =
      if prop ? "$ref"
      then (resolveRef root prop."$ref") // (builtins.removeAttrs prop ["$ref"])
      else prop;

    isSkipped = resolved."x-nixcfg-skip" or false;
  in
    # skipped properties are present in the schema (for other consumers like
    # cli/env/config) but excluded from nix module options entirely
    if isSkipped
    then {}
    else let
      isSecret = resolved."x-nixcfg-secret" or false;
      type = resolved.type or null;
      isNullable =
        (builtins.isList type && builtins.elem "null" type)
        || (resolved ? anyOf && builtins.any (v: (v.type or null) == "null") resolved.anyOf);

      nixName = nixNameFor toNixName name resolved;

      nixType =
        if isSecret
        then
          (
            if isNullable
            then lib.types.nullOr lib.types.path
            else lib.types.path
          )
        else mapType root toNixName resolved;

      baseDesc = resolved."x-nixcfg-description" or resolved.description or "";
      nixDesc =
        if isSecret
        then "path to file containing ${baseDesc}"
        else baseDesc;

      # determine if this is a structural type for default computation
      resolvedType = resolved.type or null;
      isObject = resolvedType == "object";
      isArray = resolvedType == "array";

      nixDefault =
        if isSecret && isNullable
        then {default = null;}
        else if isSecret
        then {}
        else if resolved ? default
        then {inherit (resolved) default;}
        else if isNullable
        then {default = null;}
        else if isObject && resolved ? properties
        then {default = {};}
        else if isArray
        then {default = [];}
        else if isObject
        then {default = {};}
        else {};

      # x-nixcfg-example takes precedence over the first of examples
      nixExample =
        if resolved ? "x-nixcfg-example"
        then {example = resolved."x-nixcfg-example";}
        else if resolved ? examples && !isSecret
        then {example = builtins.head resolved.examples;}
        else {};

      baseArgs =
        {type = nixType;}
        // lib.optionalAttrs (nixDesc != "") {description = nixDesc;}
        // nixDefault
        // nixExample;

      finalArgs = baseArgs // override;
    in {
      ${nixName} = lib.mkOption finalArgs;
    };

  # map all properties in a schema object to nix options
  mapProperties = root: toNixName: schema: overrides:
    lib.foldl' (
      acc: name:
        acc // mapProperty root toNixName name schema.properties.${name} (overrides.${name} or {})
    ) {} (builtins.attrNames (schema.properties or {}));

  # -- public: option generation --

  optionsFromSchema = {naming ? "camelCase"}: schema:
    mapProperties schema (namingTransform naming) schema {};

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
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);

    toNixName = namingTransform naming;
    name = parsed."x-nixcfg-name" or parsed.title or "unknown";

    # validate override keys exist in schema properties
    unknownOverrides =
      builtins.filter
      (k: !(parsed.properties ? ${k}))
      (builtins.attrNames overrides);
    validation =
      if unknownOverrides != []
      then builtins.throw "nixcfg: override keys not found in schema: ${builtins.concatStringsSep ", " unknownOverrides}. use extraOverrides for non-schema options"
      else true;

    opts = builtins.seq validation (mapProperties parsed toNixName parsed overrides);

    extraOpts = lib.mapAttrs (_: attrs: lib.mkOption attrs) extraOverrides;

    optionPath = prefix ++ [name];

    schemaOpts = opts // extraOpts;
    topLevel =
      {enable = lib.mkEnableOption (parsed.description or name);}
      // (
        if settingsAttr != null
        then {
          ${settingsAttr} = lib.mkOption {
            type = lib.types.submodule {options = schemaOpts;};
            default = {};
            description = "configuration options for ${name}";
          };
        }
        else schemaOpts
      );
  in
    _: {
      options = lib.setAttrByPath optionPath topLevel;
    };

  # generate a config file derivation from a schema and settings attrset
  #
  # returns a derivation (store path) for the generated config file.
  # filters out null, empty lists, and empty attrs before serialisation
  #
  # usage: mkConfigFile { inherit pkgs schema; settings = cfg.settings; }
  mkConfigFile = {
    pkgs,
    schema,
    settings,
  }: let
    parsed =
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);

    configFormat = parsed."x-nixcfg-config-format" or
      (builtins.throw "nixcfg: mkConfigFile requires x-nixcfg-config-format in schema");
    name = parsed."x-nixcfg-name" or parsed.title or "config";

    filterSettings = s:
      lib.filterAttrsRecursive (
        _: v: v != null && !(builtins.isList v && v == []) && !(builtins.isAttrs v && v == {})
      )
      s;

    fmt =
      {
        "toml" = pkgs.formats.toml {};
        "json" = pkgs.formats.json {};
        "yaml" = pkgs.formats.yaml {};
      }.${
        configFormat
      } or (builtins.throw "nixcfg: unknown config format '${configFormat}', expected one of: toml, json, yaml");
  in
    fmt.generate "${name}-config.${configFormat}" (filterSettings settings);

  # -- public: config conversion helpers --

  # helper to check if a property is nullable

  # determine the "leaf type" for a property (for bool/list special handling)
  leafType = root: prop: let
    resolved =
      if prop ? "$ref"
      then (resolveRef root prop."$ref") // (builtins.removeAttrs prop ["$ref"])
      else prop;
    type = resolved.type or null;
  in
    if builtins.isList type
    then leafType root (resolved // {type = builtins.head (builtins.filter (t: t != "null") type);})
    else if resolved ? anyOf
    then "scalar"
    else if resolved ? oneOf
    then "scalar"
    else if type == "boolean"
    then "bool"
    else if type == "array"
    then "list"
    else if type == "object" && resolved ? properties
    then "submodule"
    else if type == "object"
    then "attrs"
    else "scalar";

  toCliArgs = {
    naming ? "camelCase",
    output ? "kebab-case",
  }: schema: cfg: let
    parsed =
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
    outputName = name: prop: let
      isSecret = prop."x-nixcfg-secret" or false;
    in
      toOutput (
        if isSecret
        then "${name}_path"
        else name
      );
  in
    lib.concatLists (lib.mapAttrsToList (
        name: prop: let
          resolved =
            if prop ? "$ref"
            then (resolveRef parsed prop."$ref") // (builtins.removeAttrs prop ["$ref"])
            else prop;
          isSecret = resolved."x-nixcfg-secret" or false;
          nixName = nixNameFor toNixName name resolved;
          flag = "--${outputName name resolved}";
          value = cfg.${nixName} or null;
          leaf = leafType parsed resolved;
        in
          if value == null
          then []
          else if leaf == "submodule" || leaf == "attrs"
          then []
          else if isSecret
          then [flag (toString value)]
          else if leaf == "bool"
          then lib.optional value flag
          else if leaf == "list"
          then lib.concatMap (v: [flag (toString v)]) value
          else [flag (toString value)]
      )
      (parsed.properties or {}));

  toEnvVars = {
    naming ? "camelCase",
    output ? "SCREAMING_SNAKE_CASE",
  }: schema: cfg: let
    parsed =
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
  in
    lib.foldl' (
      acc: name: let
        prop = parsed.properties.${name};
        resolved =
          if prop ? "$ref"
          then (resolveRef parsed prop."$ref") // (builtins.removeAttrs prop ["$ref"])
          else prop;
        isSecret = resolved."x-nixcfg-secret" or false;
        nixName = nixNameFor toNixName name resolved;
        envName = toOutput (
          if isSecret
          then "${name}_path"
          else name
        );
        value = cfg.${nixName} or null;
        leaf = leafType parsed resolved;
      in
        if value == null
        then acc
        else if leaf == "bool"
        then acc // {${envName} = lib.boolToString value;}
        else if leaf == "list"
        then acc // {${envName} = lib.concatMapStringsSep "," toString value;}
        else acc // {${envName} = toString value;}
    ) {} (builtins.attrNames (parsed.properties or {}));

  toConfigAttrs = {
    naming ? "camelCase",
    output ? "snake_case",
  }: schema: cfg: let
    parsed =
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    toNixName = namingTransform naming;
    toOutput = namingTransform output;
  in
    lib.foldl' (
      acc: name: let
        prop = parsed.properties.${name};
        resolved =
          if prop ? "$ref"
          then (resolveRef parsed prop."$ref") // (builtins.removeAttrs prop ["$ref"])
          else prop;
        isSecret = resolved."x-nixcfg-secret" or false;
        nixName = nixNameFor toNixName name resolved;
        attrName = toOutput (
          if isSecret
          then "${name}_path"
          else name
        );
        value = cfg.${nixName} or null;
      in
        if value == null
        then acc
        else acc // {${attrName} = value;}
    ) {} (builtins.attrNames (parsed.properties or {}));

  debugLib = import ./debug.nix {inherit lib nixcfgLib;};
  fromOptionsLib = import ./from-options.nix {inherit lib;};
  modularServiceLib = import ./modular-service.nix {inherit nixcfgLib;};

  nixcfgLib = {
    inherit
      optionsFromSchema
      optionsFromFile
      mkModule
      mkConfigFile
      toCliArgs
      toEnvVars
      toConfigAttrs
      mapType
      mapProperties
      namingTransform
      snakeToCamel
      snakeToKebab
      snakeToScreaming
      nixNameFor
      ;

    # nix driver: generate JSON Schema from nix module options
    inherit
      (fromOptionsLib)
      schemaFromOptions
      schemaFromModule
      typeToSchema
      optionsToProperties
      ;

    # modular services (nixpkgs system.services)
    inherit (modularServiceLib) mkModularService;

    inherit (debugLib) fmtSchema;

    mkLib = pkgs:
      nixcfgLib
      // {
        mkDebugApp = {
          schema,
          naming ? "camelCase",
        }:
          debugLib.mkDebugApp {inherit schema pkgs naming;};
      };
  };
in
  nixcfgLib
