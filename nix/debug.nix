# pretty-print a nixcfg schema as the nix module it would produce
{
  lib,
  nixcfgLib,
}: let
  inherit (nixcfgLib) snakeToCamel namingTransform;

  # format a schema type as a nix type string
  fmtType = type:
    if builtins.isString type
    then
      {
        "string" = "types.str";
        "bool" = "types.bool";
        "int" = "types.int";
        "uint" = "types.ints.unsigned";
        "path" = "types.path";
        "port" = "types.port";
      }
      .${type}
      or "types.${type}"
    else if type ? optional
    then "types.nullOr (${fmtType type.optional})"
    else if type ? list
    then "types.listOf (${fmtType type.list})"
    else if type ? attrs
    then "types.attrsOf (${fmtType type.attrs})"
    else if type ? enum
    then "types.enum [ ${lib.concatMapStringsSep " " (v: "\"${v}\"") type.enum} ]"
    else if type ? submodule
    then "types.submodule { ... }"
    else "???";

  # format a single option
  fmtOption = toNixName: indent: name: opt: let
    pad = lib.concatStrings (builtins.genList (_: " ") indent);
    isSecret = opt.secret or false;
    isOptional = builtins.isAttrs opt.type && opt.type ? optional;

    nixName = nixcfgLib.nixNameFor toNixName name opt;

    nixType =
      if isSecret
      then
        (
          if isOptional
          then "types.nullOr types.path"
          else "types.path"
        )
      else fmtType opt.type;

    desc = opt.description or "";
    nixDesc =
      if isSecret
      then "path to file containing ${desc}"
      else desc;

    lines =
      ["${pad}${nixName} = mkOption {"]
      ++ ["${pad}  type = ${nixType};"]
      ++ lib.optional (opt ? default) "${pad}  default = ${builtins.toJSON opt.default};"
      ++ lib.optional (nixDesc != "") "${pad}  description = \"${lib.escape ["\"" "\\"] nixDesc}\";"
      ++ lib.optional isSecret "${pad}  # secret: value read from file at runtime"
      ++ ["${pad}};"];

    # recurse into submodules
    sub =
      if builtins.isAttrs opt.type && opt.type ? submodule && !isSecret
      then fmtOptions toNixName (indent + 2) opt.type.submodule
      else if builtins.isAttrs opt.type && opt.type ? optional && builtins.isAttrs opt.type.optional && opt.type.optional ? submodule && !isSecret
      then fmtOptions toNixName (indent + 2) opt.type.optional.submodule
      else "";
  in
    lib.concatStringsSep "\n" lines
    + (
      if sub != ""
      then "\n${pad}# submodule contents:\n${sub}"
      else ""
    );

  # format all options at a given indent
  fmtOptions = toNixName: indent: options:
    lib.concatStringsSep "\n\n" (
      map (name: fmtOption toNixName indent name options.${name}) (builtins.attrNames options)
    );

  # format a full schema
  fmtSchema = {naming ? "camelCase"}: schema: let
    toNixName = namingTransform naming;
    parsed =
      if builtins.isAttrs schema
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    desc = parsed.description or parsed.name;
  in ''
    services.${parsed.name} = {
      enable = mkEnableOption "${desc}";

    ${fmtOptions toNixName 2 parsed.options}
    };
  '';
in {
  # build a debug app that pretty-prints the module
  mkDebugApp = {
    schema,
    pkgs,
    naming ? "camelCase",
  }: let
    output = fmtSchema {inherit naming;} schema;
    script = pkgs.writeShellScript "nixcfg-debug" ''
      cat <<'NIXCFG_EOF'
      ${output}
      NIXCFG_EOF
    '';
  in {
    type = "app";
    program = "${script}";
  };

  inherit fmtSchema;
}
