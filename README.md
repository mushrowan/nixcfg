# nixcfg

generate NixOS module options from your program's config types. define your
config once, get typed nix options automatically.

```
config struct ──→ language driver ──→ schema.json ──→ nix lib ──→ mkOption defs
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

## quick example (rust driver)

```rust
use nixcfg::NixCfg;

#[derive(NixCfg)]
enum LogLevel { Trace, Debug, Info, Warn, Error }

#[derive(NixCfg)]
struct Config {
    /// data directory
    #[nixcfg(default = "/var/lib/myapp")]
    data_dir: PathBuf,

    /// log level
    #[nixcfg(default = "info")]
    log_level: LogLevel,

    /// discord bot token
    #[nixcfg(secret)]
    token: String,
}
```

consume in nix:

```nix
{
  imports = [
    nixcfg.lib.mkModule { schema = ./schema.json; }
  ];
}

# produces:
# services.myapp.enable
# services.myapp.dataDir        (path, default "/var/lib/myapp")
# services.myapp.logLevel       (enum, default "info")
# services.myapp.tokenPath      (path, secret)
```

## how it works

the JSON schema is the contract between your program and nix. any language that
can emit the schema can use the nix library. see `schema/v1.md` for the full
spec.

schema types: `string`, `bool`, `int`, `uint`, `path`, `port`, `optional`,
`list`, `attrs`, `enum`, `submodule`

## drivers

a driver is anything that emits the schema JSON from your config types.

**rust** (`drivers/rust/`) - proc macro derive, as shown in the example above.

more drivers (go, python, typescript) are planned. writing one is
straightforward: emit JSON matching `schema/v1.md`.

## nix lib

### functions

| function            | signature                                                                  |
| ------------------- | -------------------------------------------------------------------------- |
| `mkModule`          | `{ schema, naming?, prefix?, settingsAttr?, overrides?, extraOverrides? } → NixOS module` |
| `optionsFromSchema` | `{ naming? } → schema → options`                                           |
| `optionsFromFile`   | `{ naming? } → path → options`                                             |
| `toCliArgs`         | `{ naming?, output? } → schema → cfg → [string]`                           |
| `toEnvVars`         | `{ naming?, output? } → schema → cfg → attrset`                            |
| `toConfigAttrs`     | `{ naming?, output? } → schema → cfg → attrset`                            |

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

```
$ nix run .#debug
services.myapp = {
  enable = mkEnableOption "myapp";

  dataDir = mkOption {
    type = types.path;
    default = "/var/lib/myapp";
    description = "data directory";
  };
  ...
};
```

## checks

`nix flake check` runs 30 checks: 27 nix (naming conventions, type mapping,
secrets, defaults, module generation, settingsAttr, CLI/env/config conversion
with output naming, overrides, end-to-end snake_case, name conversions) and 3
rust (cargo test, clippy, fmt).
