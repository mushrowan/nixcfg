# nixcfg (gleam driver)

JSON Schema builder for nixcfg, the bridge between your config struct
and a NixOS module. see the [repo README](../../../README.md) for
the overall architecture.

## install

if and when this is published to hex:

```sh
gleam add nixcfg
```

for now, use as a git dependency in your `gleam.toml`.

## usage

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
  |> nixcfg.prop(
    "api_token",
    nixcfg.string()
      |> nixcfg.secret()
      |> nixcfg.description("API authentication token"),
  )
  |> nixcfg.to_json
  |> io.println
}
```

### constructors

| function | produces |
|---|---|
| `string()` | `types.str` |
| `boolean()` | `types.bool` |
| `integer()` | `types.int` (signed, no bounds) |
| `unsigned()` | `types.ints.unsigned` |
| `u8()` / `u16()` / `u32()` | bounded unsigned |
| `i8()` / `i16()` / `i32()` | bounded signed |
| `enum_of([...])` | `types.enum [...]` |
| `list_of(item)` | `types.listOf item` |
| `nullable(inner)` | `types.nullOr inner` |
| `raw(value)` | escape hatch: pass through a raw JSON fragment |

### modifiers

all take a `PropBuilder` and return `PropBuilder`, so they pipe cleanly:

| modifier | effect |
|---|---|
| `default(value)` | set default |
| `description(text)` | set description |
| `example(value)` | set `examples[0]` |
| `pattern(regex)` | constrain strings by regex (`types.strMatching`) |
| `min_length(n)` / `max_length(n)` | constrain string length |
| `secret()` | `x-nixcfg-secret` |
| `port()` | `x-nixcfg-port` |
| `path()` | `x-nixcfg-path` |
| `skip()` | `x-nixcfg-skip` |
| `override_description(text)` | `x-nixcfg-description` |
| `override_example(value)` | `x-nixcfg-example` |

## demo + drift check

the `example_mycel` module is a full demo that lives alongside the
library (hidden from published docs via `internal_modules`). run it
to regenerate the checked-in `schema.json`:

```sh
gleam run --module example_mycel > schema.json
```

the repo's `nix flake check` diffs `schema.json` against the
module's output, so struct changes without a regen will fail CI.

## tests

```sh
gleam test
```

13 unit tests cover all types, annotations, validation constraints,
and required-list filtering.
