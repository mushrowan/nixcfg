# nixcfg

generate NixOS module options from your program's config types. define your
config once, get typed nix options automatically.

```
config struct ──→ JSON Schema ──→ nix lib ──→ mkOption defs
```

## dilemma

- you write CoolProgram in a language of your choice
- CoolProgram has configuration defined in a file, cli args, env vars
- you are Intelligent, Attractive and Awesome (you use nix)
- you decide to write a nix module for CoolProgram for first-class nix support
- **OH NO!!!** you have to rewrite all that configuration in nix! woe is you
- you write v2 of CoolProgram.
  - one config option changes the types it accepts.
  - one configuration option gets added.
  - one configuration option gets removed. you previously defined a default
    value for this option in the nix module.
- you forget to update the nix module. poor nix module
- **OH NO!!!** the nix module now is completely broken.
  - the removed option causes all non-overridden builds to fail at runtime.
  - the new option is missing. users make angry github issues complaining about
    the laziness of the Maintainer, cursed be zer name.
  - the changed option miraculously breaks the runtime if defined in the nix
    module.

## the possible solutions

- **option 1:** don't expose a settings submodule at all. let users figure out
  how to symlink the raw config into the right place, or tell them to do it
  imperatively.
- **option 2:** expose a configFile option.
- **option 3:** expose an [extra]Settings option, then use
  lib.toTOML/toJSON/toYAML/toWhatever on it. lose all benefits of
  strongly-typed modules.

### **_option 4:_** use NixCfg.

The goal of NixCfg is:  
**the program == the source of truth for its nix module options**

## quick example (rust)

```rust
use schemars::JsonSchema;
use serde::Serialize;

#[derive(JsonSchema, Serialize)]
enum LogLevel { Trace, Debug, Info, Warn, Error }

#[derive(JsonSchema, Serialize)]
struct Config {
    /// data directory
    #[serde(default = "default_data_dir")]
    data_dir: String,

    /// log level
    log_level: LogLevel,

    /// discord bot token
    #[schemars(extend("x-nixcfg-secret" = true))]
    token: String,
}
```

emit the schema and consume in nix:

```rust
use nixcfg::NixSchema;
let schema = NixSchema::from::<Config>("myapp");
println!("{}", schema.to_json_pretty());
```

```nix
{
  imports = [
    nixcfg.lib.mkModule { schema = ./schema.json; }
  ];
}

# produces:
# services.myapp.enable
# services.myapp.dataDir        (str, default "/var/lib/myapp")
# services.myapp.logLevel       (enum)
# services.myapp.tokenPath      (path, secret)
```

## how it works

the schema is standard [JSON Schema (draft 2020-12)](https://json-schema.org/draft/2020-12)
with `x-nixcfg-*` extensions. any language that can emit JSON Schema can use
the nix library. see `schema/v1.md` for the full spec.

nixcfg extensions:

| extension | effect |
|---|---|
| `x-nixcfg-name` | service name for module path |
| `x-nixcfg-secret` | field becomes a file path, name gets `_path` suffix |
| `x-nixcfg-port` | integer becomes `types.port` |

any language with a JSON Schema library (schemars for rust, jsonschema for
python, etc.) can be a driver. no custom proc macros or code generation needed.

## nix lib

### functions

| function            | signature                                                                  |
| ------------------- | -------------------------------------------------------------------------- |
| `mkModule`          | `{ schema, naming?, prefix?, settingsAttr?, overrides?, extraOverrides? } -> NixOS module` |
| `optionsFromSchema` | `{ naming? } -> schema -> options`                                           |
| `optionsFromFile`   | `{ naming? } -> path -> options`                                             |
| `toCliArgs`         | `{ naming?, output? } -> schema -> cfg -> [string]`                           |
| `toEnvVars`         | `{ naming?, output? } -> schema -> cfg -> attrset`                            |
| `toConfigAttrs`     | `{ naming?, output? } -> schema -> cfg -> attrset`                            |

### naming

all naming conventions are available everywhere: `camelCase`, `snake_case`,
`kebab-case`, `SCREAMING_SNAKE_CASE`. the schema is always `snake_case`.

each function has sensible defaults:

| context | parameter | default |
|---|---|---|
| nix options | `naming` | `camelCase` |
| CLI flags | `output` | `kebab-case` |
| env vars | `output` | `SCREAMING_SNAKE_CASE` |
| config file keys | `output` | `snake_case` |

### overrides

```nix
nixcfg.lib.mkModule {
  schema = ./schema.json;
  overrides = {
    data_dir.type = lib.types.either lib.types.path lib.types.str;
  };
  extraOverrides = {
    package = { type = lib.types.package; description = "package to use"; };
  };
}
```

`overrides` keys are validated against the schema. `extraOverrides` adds
nix-only options.

### settingsAttr

by default, generated options are placed directly under the module path
(e.g. `services.myapp.dataDir`). set `settingsAttr` to nest them under a
submodule instead:

```nix
nixcfg.lib.mkModule {
  schema = ./schema.json;
  settingsAttr = "settings";
}
# services.myapp.enable         (always top-level)
# services.myapp.settings.dataDir
# services.myapp.settings.logLevel
```

### debug

inspect the generated module with `nix run .#debug`:

```nix
apps.debug = (nixcfg.lib.mkLib pkgs).mkDebugApp { schema = ./schema.json; };
```

## checks

`nix flake check` runs 30 checks: 27 nix (naming conventions, type mapping,
secrets, defaults, module generation, settingsAttr, CLI/env/config conversion
with output naming, overrides, end-to-end snake_case, name conversions) and 3
rust (cargo test, clippy, fmt).
