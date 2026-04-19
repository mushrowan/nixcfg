# nixcfg nix driver - generate JSON Schema from NixOS module options
#
# takes evaluated module options and reverse-maps nix types to JSON Schema.
# this lets you take any existing NixOS module and get a schema for it,
# which can then be used to generate modular services, CLI args, env vars, etc
{lib}: let
  # reverse-map a nix option type to a JSON Schema property
  typeToSchema = type: let
    name = type.name or "";
    # nested type (for listOf, attrsOf, nullOr etc)
    nestedTypes = type.nestedTypes or {};
  in
    if name == "str" || name == "string"
    then {type = "string";}
    else if name == "bool"
    then {type = "boolean";}
    else if name == "int"
    then {type = "integer";}
    else if name == "unsignedInt"
    then {
      type = "integer";
      minimum = 0;
    }
    else if name == "unsignedInt8"
    then {
      type = "integer";
      format = "uint8";
      minimum = 0;
      maximum = 255;
    }
    else if name == "unsignedInt16"
    then {
      type = "integer";
      format = "uint16";
      minimum = 0;
      maximum = 65535;
    }
    else if name == "unsignedInt32"
    then {
      type = "integer";
      format = "uint32";
      minimum = 0;
      maximum = 4294967295;
    }
    else if name == "signedInt8"
    then {
      type = "integer";
      format = "int8";
      minimum = -128;
      maximum = 127;
    }
    else if name == "signedInt16"
    then {
      type = "integer";
      format = "int16";
      minimum = -32768;
      maximum = 32767;
    }
    else if name == "signedInt32"
    then {
      type = "integer";
      format = "int32";
      minimum = -2147483648;
      maximum = 2147483647;
    }
    else if name == "float"
    then {type = "number";}
    else if name == "intBetween"
    then {
      type = "integer";
      minimum = (type.functor.payload or {}).min or 0;
      maximum = (type.functor.payload or {}).max or 0;
    }
    else if name == "path"
    then {
      type = "string";
      "x-nixcfg-path" = true;
    }
    else if name == "enum"
    then {
      type = "string";
      enum = (type.functor.payload or {}).values or [];
    }
    else if name == "nullOr"
    then let
      inner = typeToSchema nestedTypes.elemType;
    in
      # use the array form for nullable
      if inner ? type && builtins.isString inner.type
      then inner // {type = [inner.type "null"];}
      # for complex inner types, use anyOf
      else {anyOf = [inner {type = "null";}];}
    else if name == "listOf"
    then {
      type = "array";
      items = typeToSchema nestedTypes.elemType;
    }
    else if name == "attrsOf"
    then {
      type = "object";
      additionalProperties = typeToSchema nestedTypes.elemType;
    }
    else if name == "submodule"
    then submoduleToSchema type
    else if lib.hasPrefix "either" name
    then
      # either → just use the first type for schema purposes
      # (JSON Schema can't easily represent union types without anyOf)
      typeToSchema nestedTypes.left or (typeToSchema nestedTypes.right or {type = "string";})
    # coercedTo, uniq, lazy wrappers - unwrap
    else if nestedTypes ? elemType
    then typeToSchema nestedTypes.elemType
    # fallback
    else {type = "string";};

  # convert a submodule type to a JSON Schema object
  submoduleToSchema = type: let
    # evaluate the submodule to get its options
    # the submodule type has getSubOptions which returns the option set
    subOpts = type.getSubOptions [];
  in {
    type = "object";
    properties = optionsToProperties subOpts;
  };

  # convert an option set to JSON Schema properties
  optionsToProperties = opts: let
    names = builtins.attrNames opts;
    go = name: let
      opt = opts.${name};
    in
      # skip internal/invisible options
      if (opt._type or "") == "option"
      then let
        prop =
          typeToSchema opt.type
          // lib.optionalAttrs (opt ? description && opt.description != null) {
            description = let
              d = opt.description;
            in
              if builtins.isString d
              then d
              else d.text or (builtins.toString d);
          }
          // lib.optionalAttrs (opt ? default) {
            inherit (opt) default;
          }
          // lib.optionalAttrs (opt ? example) {
            example = let
              e = opt.example;
            in
              e.text or e;
          };
      in {${name} = prop;}
      # nested option group (not an option itself, but a set of sub-options)
      else if builtins.isAttrs opt
      then let
        sub = optionsToProperties opt;
      in
        if sub != {}
        then {
          ${name} = {
            type = "object";
            properties = sub;
          };
        }
        else {}
      else {};
  in
    lib.foldl' (acc: name: acc // (go name)) {} names;

  # main entry point: convert evaluated options to a JSON Schema
  schemaFromOptions = {
    options,
    name,
    description ? null,
    # path into the options tree to extract (e.g. ["services" "postgresql"])
    path ? [],
  }: let
    targetOpts =
      if path == []
      then options
      else lib.getAttrFromPath path options;
    props = optionsToProperties targetOpts;
  in
    {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = name;
      type = "object";
      "x-nixcfg-name" = name;
      properties = props;
    }
    // lib.optionalAttrs (description != null) {inherit description;};

  # convenience: evaluate a module and extract its options as a schema
  schemaFromModule = {
    module,
    name,
    description ? null,
    path ? [],
    extraModules ? [],
  }: let
    evaled = lib.evalModules {
      modules = [module] ++ extraModules;
    };
  in
    schemaFromOptions {
      inherit name description path;
      inherit (evaled) options;
    };
in {
  inherit
    schemaFromOptions
    schemaFromModule
    typeToSchema
    optionsToProperties
    ;
}
