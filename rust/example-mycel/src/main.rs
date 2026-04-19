//! demo: emit a nixcfg schema for the `Config` struct below
//!
//! this binary shows the end-to-end flow: rust struct → json schema →
//! (nix consumes via `mkModule`). the generated output is checked in at
//! `schema.json` alongside this source; a flake check (`nix flake check`)
//! re-runs the binary and diffs against the checked-in file to catch
//! drift when the struct changes

use nixcfg::{JsonSchema, nixcfg};
use serde::Serialize;

/// mycel discord bot configuration
#[nixcfg]
#[derive(JsonSchema, Serialize)]
struct Config {
    /// directory for the database, models, and workspace
    data_dir: String,

    /// anthropic model to use
    model: String,

    /// log level
    log_level: LogLevel,

    /// keep the prompt cache warm between messages
    cache_warming: bool,

    /// discord bot token
    #[nixcfg(secret)]
    discord_token: String,

    /// anthropic API key (not needed with OAuth)
    #[nixcfg(secret)]
    anthropic_key: Option<String>,
}

#[derive(JsonSchema, Serialize)]
#[serde(rename_all = "lowercase")]
#[allow(dead_code)] // variants are part of the schema enum, not all are constructed
enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            data_dir: "/var/lib/mycel".into(),
            model: "claude-sonnet-4-20250514".into(),
            log_level: LogLevel::Info,
            cache_warming: false,
            discord_token: String::new(),
            anthropic_key: None,
        }
    }
}

fn main() {
    // one-liner: wraps NixSchema::from + with_defaults + to_json_pretty
    print!("{}", nixcfg::emit::<Config>("mycel"));
    println!();
}
