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

the goal of NixCfg is:
**the program == the source of truth for its nix module options**

## quick example (rust)

```rust
use nixcfg::{JsonSchema, NixSchema, nixcfg};
use serde::Serialize;

#[nixcfg]
#[derive(JsonSchema, Serialize)]
/// my service configuration
struct Config {
    /// data directory
    data_dir: String,

    /// listen port
    #[nixcfg(port)]
    listen_port: u16,

    /// API authentication token
    #[nixcfg(secret)]
    api_token: String,

    /// log level
    log_level: LogLevel,
}

#[derive(JsonSchema, Serialize)]
#[serde(rename_all = "lowercase")]
enum LogLevel { Trace, Debug, Info, Warn, Error }
```

emit the schema and consume in nix:

```rust
// one-liner when Config: Default + Serialize
fn main() {
    print!("{}", nixcfg::emit::<Config>("myapp"));
}

// or step-by-step if you need to add extensions / tweak output
let defaults = serde_json::to_value(Config::default()).unwrap();
let schema = nixcfg::NixSchema::from::<Config>("myapp").with_defaults(defaults);
println!("{}", schema.to_json_pretty());
```

```nix
{
  imports = [ (nixcfg.lib.mkModule { schema = ./schema.json; }) ];
}

# produces:
# services.myapp.enable
# services.myapp.dataDir        (str, with default)
# services.myapp.listenPort     (types.port)
# services.myapp.apiTokenPath   (path, secret)
# services.myapp.logLevel       (enum)
```

see `rust/example-mycel/` for a complete demo, including a flake
check that diffs the binary's output against a checked-in `schema.json` so
the struct and the schema can't drift apart.

## drivers

| language | location | notes |
|---|---|---|
| rust | `rust/` | uses [schemars](https://graham.cool/schemars/) + `#[nixcfg]` macro |
| gleam | `gleam/` | builder DSL, runs on BEAM |

any language with a JSON Schema library can be a driver.

## how it works

the schema is standard [JSON Schema (draft 2020-12)](https://json-schema.org/draft/2020-12)
with `x-nixcfg-*` extensions. any language that can emit JSON Schema can use
the nix library. see `schema/v1.md` for the full spec.

### extensions

| extension | effect |
|---|---|
| `x-nixcfg-name` | service name for module path |
| `x-nixcfg-secret` | field becomes `types.path`, name gets `_path` suffix |
| `x-nixcfg-port` | integer becomes `types.port` |
| `x-nixcfg-path` | string becomes `types.path` (schemars PathBuf auto-detected) |
| `x-nixcfg-skip` | omit from nix module options (keep in schema for cli/env/config) |
| `x-nixcfg-description` | override description (for nix-facing prose) |
| `x-nixcfg-example` | override single example value |
| `x-nixcfg-config-format` | `toml` / `json` / `yaml` for `mkConfigFile` |

### rust driver

the `nixcfg` crate re-exports a `#[nixcfg]` attribute macro that rewrites
field attributes into the schemars `extend` form:

```rust
#[nixcfg]
#[derive(JsonSchema, Serialize)]
struct Config {
    #[nixcfg(secret)] api_key: String,
    #[nixcfg(port)] listen_port: u16,
    #[nixcfg(path)] data_dir: std::path::PathBuf,
    #[nixcfg(skip)] runtime_handle: std::sync::Arc<()>,
    #[nixcfg(secret, path)] pem_path: String,
    #[nixcfg(description = "...", example = "...")] hooks_cwd: String,
}
```

flags: `secret`, `port`, `path`, `skip`. key=value: `description`, `example`.

for types that can't impl `JsonSchema` locally, use schemars's
`#[schemars(schema_with = "fn_path")]` to hand-roll the schema fragment.
nixcfg extensions embedded in it pass through untouched.

### gleam driver

the `nixcfg` gleam package provides a builder DSL. since gleam doesn't
have macros, you construct the schema explicitly:

```gleam
import gleam/io
import gleam/json
import nixcfg

pub fn main() {
  nixcfg.new("myapp", "my service configuration")
  |> nixcfg.prop(
    "data_dir",
    nixcfg.string()
      |> nixcfg.default(json.string("/var/lib/myapp"))
      |> nixcfg.description("data directory"),
  )
  |> nixcfg.prop("listen_port", nixcfg.u16() |> nixcfg.port())
  |> nixcfg.prop("api_token", nixcfg.string() |> nixcfg.secret())
  |> nixcfg.prop(
    "log_level",
    nixcfg.enum_of(["trace", "debug", "info", "warn", "error"])
      |> nixcfg.default(json.string("info")),
  )
  |> nixcfg.to_json
  |> io.println
}
```

constructors: `string`, `boolean`, `integer`, `unsigned`, `u8` / `u16` /
`u32`, `i8` / `i16` / `i32`, `enum_of`, `list_of`, `nullable`, `raw`
(escape hatch for unusual types).

modifiers: `default`, `description`, `example`, `pattern`, `min_length`,
`max_length`, `secret`, `port`, `path`, `skip`, `override_description`,
`override_example`.

see `gleam/nixcfg/src/example_mycel.gleam` for a complete demo.

### other languages

any language with a JSON Schema library (go's `jsonschema`, python's
`pydantic`, zig's comptime, lua schemas) can be a driver. no custom proc
macros or code generation needed.

## nix lib

### functions

| function | signature |
|---|---|
| `mkModule` | `{ schema, naming?, prefix?, settingsAttr?, overrides?, extraOverrides? } -> NixOS module` |
| `mkConfigFile` | `{ pkgs, schema, settings } -> derivation` (toml/json/yaml via `x-nixcfg-config-format`) |
| `mkModularService` | `{ schema, naming?, mkArgv?, extraModules? } -> portable service module` |
| `optionsFromSchema` | `{ naming? } -> schema -> options` |
| `optionsFromFile` | `{ naming? } -> path -> options` |
| `toCliArgs` | `{ naming?, output? } -> schema -> cfg -> [string]` |
| `toEnvVars` | `{ naming?, output? } -> schema -> cfg -> attrset` |
| `toConfigAttrs` | `{ naming?, output? } -> schema -> cfg -> attrset` |
| `schemaFromOptions` / `schemaFromModule` | reverse driver: nix options → JSON Schema |

### naming

all naming conventions are available everywhere: `camelCase`, `snake_case`,
`kebab-case`, `SCREAMING_SNAKE_CASE`. the schema is always `snake_case`.

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
    # direct override of a top-level option
    data_dir.type = lib.types.either lib.types.path lib.types.str;
    # dotted path reaches into a nested submodule option
    "database.host".type = lib.types.str;
  };
  # nix-only options inside `services.myapp.settings.*` (when settingsAttr
  # is set), or alongside schema opts otherwise
  extraOverrides = {
    socketPath = { type = lib.types.path; description = "unix socket"; };
  };
  # nix-only options at `services.myapp.*` top level, next to `enable`.
  # useful for things like `package` that shouldn't live inside settings
  topLevelExtraOverrides = {
    package = { type = lib.types.package; description = "package to use"; };
  };
}
```

`overrides` keys are validated against the schema (catches drift when fields
are renamed). dotted keys are validated by first segment only; deeper
segments are checked by the submodule type system at eval time.

- `extraOverrides` adds nix-only options alongside schema opts. when
  `settingsAttr` is set, they land inside the settings submodule
- `topLevelExtraOverrides` adds nix-only options at the top level (next
  to `enable`), regardless of `settingsAttr`. use for options that
  shouldn't be serialised into the config file

### settingsAttr

by default, options sit directly under the module path
(`services.myapp.dataDir`). set `settingsAttr` to nest them:

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

### validation

nixcfg maps JSON Schema validation keywords to nix type checks at eval time:

- **strings**: `pattern` → `types.strMatching`, `minLength` / `maxLength`
  → composed via `addCheck` + `builtins.stringLength`
- **integers**: schemars format strings (`uint8` / `uint16` / `uint32` /
  `int8` / `int16` / `int32`) map to bounded `types.ints.u8` etc.
  `minimum`+`maximum` maps to `types.ints.between`, `minimum: 0` alone
  maps to `types.ints.unsigned`

## gotchas

### `#[schemars(extend)]` on the type vs on the field

extensions on a type definition (`#[schemars(extend("x-nixcfg-secret" =
true))] struct ApiKey(String);`) put the extension on `$defs/ApiKey`.
nixcfg will inherit `x-nixcfg-*` extensions from the `$ref` target when a
field's schema is `anyOf: [{$ref: ApiKey}, {type: null}]` (the standard
schemars shape for `Option<ApiKey>`), so secrets on wrapper types
propagate through optional fields automatically. for non-nullable
references, the $ref target's extensions don't currently propagate, so
prefer annotating the field directly:

```rust
struct Config {
    #[nixcfg(secret)]
    api_key: ApiKey,             // works
    #[nixcfg(secret)]            // not strictly needed, but clearer
    optional_key: Option<ApiKey>,
}
```

### `settingsAttr` + top-level options (`package`, `enable`, etc.)

use `topLevelExtraOverrides` to add nix-only options outside the
settings submodule. previously consumers had to hand-write a second
module for things like `package`; `topLevelExtraOverrides` bakes that in.

### `schema_with` escape hatch for foreign types

types that can't implement `JsonSchema` (foreign crates, trait objects,
etc.) can hand-roll their fragment via schemars's `schema_with`:

```rust
#[schemars(schema_with = "my_type_schema")]
complex_field: SomeType,
```

nixcfg extensions in the returned JSON pass through untouched.

### tagged flatten (`#[serde(flatten)] + #[serde(tag = "...")]`)

schemars emits this as `{properties, oneOf}`. nixcfg merges variant
properties into a single submodule with the tag field as a string enum
discriminator. variant-specific fields become nullable so switching tags
doesn't require setting "wrong-variant" fields. this is lossy w.r.t.
strict JSON Schema validation but matches home-manager ergonomics.

### flatten of `HashMap<String, T>`

schemars emits this as `{properties, additionalProperties}`. nixcfg
turns it into a submodule with `freeformType = T`, so the named fields
stay strict and freeform extras are accepted and typed.

## checks

`nix flake check` runs 60 checks:

- **50 nix lib tests**: naming, types, secrets (including $ref inheritance
  and default-key rewrite), defaults, module generation, cli/env/config
  conversion, overrides (including dotted paths + `topLevelExtraOverrides`),
  reverse driver, modular service, extensions, format-aware ints, string
  validation, anyOf, tagged-flatten merging, freeformType for open-map
  submodules
- **5 rust checks**: build, clippy (deny warnings), nextest, cargo-deny,
  doctest
- **1 schema drift check** (rust): example binary output diffed against checked-in `schema.json`
- **1 gleam schema drift check** + **1 gleam unit test**: builds the gleam nixcfg package, runs gleeunit tests, verifies the example app's output matches checked-in `schema.json`
- **2 formatting**: treefmt wrapper + pre-commit hook
