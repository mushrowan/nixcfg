# pretty-print a nixcfg JSON Schema as the nix module it would produce
{
  lib,
  nixcfgLib,
}: let
  inherit (nixcfgLib) namingTransform;

  # resolve a $ref against the root schema
  resolveRef = root: ref: let
    path = lib.splitString "/" (lib.removePrefix "#/" ref);
  in lib.getAttrFromPath path root;

  # format a JSON Schema type as a nix type string
  fmtType = root: prop: let
    resolved =
      if prop ? "$ref"
      then (resolveRef root prop."$ref") // (builtins.removeAttrs prop ["$ref"])
      else prop;
    type = resolved.type or null;
    isPort = resolved."x-nixcfg-port" or false;
  in
    if builtins.isList type
    then let
      nonNull = builtins.filter (t: t != "null") type;
      inner = fmtType root (resolved // {type = builtins.head nonNull;});
    in "types.nullOr (${inner})"
    else if isPort then "types.port"
    else if type == "string" && resolved ? enum
    then "types.enum [ ${lib.concatMapStringsSep " " (v: "\"${v}\"") resolved.enum} ]"
    else if type == "string" then "types.str"
    else if type == "boolean" then "types.bool"
    else if type == "integer" then
      if resolved ? minimum && resolved.minimum == 0
      then "types.ints.unsigned"
      else "types.int"
    else if type == "array"
    then "types.listOf (${fmtType root (resolved.items or {type = "string";})})"
    else if type == "object" && resolved ? properties
    then "types.submodule { ... }"
    else if type == "object" && resolved ? additionalProperties
    then "types.attrsOf (${fmtType root resolved.additionalProperties})"
    else if type == "object" then "types.attrsOf types.str"
    else "types.str";

  # format a single option
  fmtOption = root: toNixName: indent: name: prop: let
    pad = lib.concatStrings (builtins.genList (_: " ") indent);
    resolved =
      if prop ? "$ref"
      then (resolveRef root prop."$ref") // (builtins.removeAttrs prop ["$ref"])
      else prop;
    isSecret = resolved."x-nixcfg-secret" or false;
    type = resolved.type or null;
    isNullable = builtins.isList type && builtins.elem "null" type;

    nixName = nixcfgLib.nixNameFor toNixName name resolved;

    nixType =
      if isSecret
      then (if isNullable then "types.nullOr types.path" else "types.path")
      else fmtType root resolved;

    desc = resolved.description or "";
    nixDesc =
      if isSecret
      then "path to file containing ${desc}"
      else desc;

    lines =
      ["${pad}${nixName} = mkOption {"]
      ++ ["${pad}  type = ${nixType};"]
      ++ lib.optional (resolved ? default) "${pad}  default = ${builtins.toJSON resolved.default};"
      ++ lib.optional (nixDesc != "") "${pad}  description = \"${lib.escape ["\"" "\\"] nixDesc}\";"
      ++ lib.optional isSecret "${pad}  # secret: value read from file at runtime"
      ++ ["${pad}};"];
  in
    lib.concatStringsSep "\n" lines;

  # format all properties at a given indent
  fmtProperties = root: toNixName: indent: schema:
    lib.concatStringsSep "\n\n" (
      map (name: fmtOption root toNixName indent name schema.properties.${name})
        (builtins.attrNames (schema.properties or {}))
    );

  # format a full schema
  fmtSchema = {naming ? "camelCase"}: schema: let
    toNixName = namingTransform naming;
    parsed =
      if builtins.isAttrs schema
      then schema
      else builtins.fromJSON (builtins.readFile schema);
    name = parsed."x-nixcfg-name" or parsed.title or "unknown";
    desc = parsed.description or name;
  in ''
    services.${name} = {
      enable = mkEnableOption "${desc}";

    ${fmtProperties parsed toNixName 2 parsed}
    };
  '';
in {
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
