# generate a modular service module from a JSON Schema
#
# produces a module with:
#   _class = "service"
#   <name>.* options from the schema
#   process.argv wired up from config
#
# compatible with nixpkgs system.services.<instance>
{lib, nixcfgLib}: let

  mkModularService = {
    # JSON Schema (attrset or path to JSON file)
    schema,
    # how to build process.argv from the config
    # function: cfg -> [string]
    # or null to skip (user provides their own process.argv)
    mkArgv ? null,
    # naming convention for options (schema is always snake_case)
    naming ? "snake_case",
    # extra modules to import into the service
    extraModules ? [],
  }: let
    parsed =
      if builtins.isAttrs schema && schema ? properties
      then schema
      else builtins.fromJSON (builtins.readFile schema);

    name = parsed."x-nixcfg-name" or parsed.title or "unknown";
    desc = parsed.description or name;
    toNixName = nixcfgLib.namingTransform naming;

    schemaOpts = nixcfgLib.mapProperties parsed toNixName parsed {};
  in
    {config, options, lib, ...}: {
      _class = "service";

      imports = extraModules;

      options.${name} = schemaOpts // {
        package = lib.mkOption {
          type = lib.types.package;
          description = "package providing ${name}";
        };
      };

      config = {
        process.argv =
          if mkArgv != null
          then mkArgv config.${name}
          else [
            (lib.getExe config.${name}.package)
          ];
      }
      // lib.optionalAttrs (options ? systemd) {
        systemd.service = {
          after = ["network.target"];
          wants = ["network.target"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Restart = "always";
            DynamicUser = true;
          };
        };
      };
    };

in {
  inherit mkModularService;
}
