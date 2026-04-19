//// demo: emit a nixcfg schema for a mycel-like configuration.
////
//// the generated output is checked in at `schema.json` alongside the
//// gleam project; a flake check (`nix flake check`) re-runs this
//// program and diffs against the checked-in file to catch drift when
//// the schema definition changes

import gleam/io
import gleam/json
import nixcfg

pub fn main() {
  schema()
  |> nixcfg.to_json
  |> io.println
}

fn schema() {
  nixcfg.new("mycel", "mycel discord bot configuration")
  |> nixcfg.prop(
    "data_dir",
    nixcfg.string()
      |> nixcfg.default(json.string("/var/lib/mycel"))
      |> nixcfg.description("directory for the database, models, and workspace"),
  )
  |> nixcfg.prop(
    "model",
    nixcfg.string()
      |> nixcfg.default(json.string("claude-sonnet-4-20250514"))
      |> nixcfg.description("anthropic model to use"),
  )
  |> nixcfg.prop(
    "log_level",
    nixcfg.enum_of(["trace", "debug", "info", "warn", "error"])
      |> nixcfg.default(json.string("info"))
      |> nixcfg.description("log level"),
  )
  |> nixcfg.prop(
    "cache_warming",
    nixcfg.boolean()
      |> nixcfg.default(json.bool(False))
      |> nixcfg.description("keep the prompt cache warm between messages"),
  )
  |> nixcfg.prop(
    "discord_token",
    nixcfg.string()
      |> nixcfg.secret()
      |> nixcfg.description("discord bot token"),
  )
  |> nixcfg.prop(
    "anthropic_key",
    nixcfg.nullable(nixcfg.string())
      |> nixcfg.secret()
      |> nixcfg.description("anthropic API key (not needed with OAuth)"),
  )
}
