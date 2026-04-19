//! nixcfg - bridge config structs to NixOS module options via JSON Schema
//!
//! use `#[derive(JsonSchema)]` from schemars with `#[schemars(extend(...))]`
//! to annotate fields with nixcfg extensions:
//!
//! - `#[schemars(extend("x-nixcfg-secret" = true))]` for secret fields
//! - `#[schemars(extend("x-nixcfg-port" = true))]` for port types
//!
//! then emit the schema with `NixSchema::from::<T>("name")`, or use the
//! one-liner [`emit::<T>("name")`] when `T: JsonSchema + Default + Serialize`

pub use schemars;
pub use schemars::JsonSchema;
pub use serde_json;

// re-export the nixcfg attribute macro for ergonomic use
pub use nixcfg_derive::nixcfg;

/// emit a schema for `T` as pretty JSON, with defaults from `T::default()`
/// merged in. this is the one-liner equivalent of the idiomatic emitter
/// binary every downstream project writes
///
/// ```no_run
/// use nixcfg::{JsonSchema, emit};
/// use serde::Serialize;
///
/// #[derive(JsonSchema, Serialize, Default)]
/// struct Config { data_dir: String }
///
/// fn main() {
///     println!("{}", emit::<Config>("myapp"));
/// }
/// ```
pub fn emit<T>(name: impl Into<String>) -> String
where
    T: JsonSchema + Default + serde::Serialize,
{
    let defaults = serde_json::to_value(T::default()).expect("defaults serialise");
    NixSchema::from::<T>(name)
        .with_defaults(defaults)
        .to_json_pretty()
}

/// wraps a schemars-generated JSON Schema with nixcfg metadata
#[derive(Debug, Clone)]
pub struct NixSchema {
    pub name: String,
    pub schema: schemars::Schema,
    pub extensions: Vec<(String, serde_json::Value)>,
}

impl NixSchema {
    /// create a nixcfg schema from a type implementing `JsonSchema`
    pub fn from<T: schemars::JsonSchema>(name: impl Into<String>) -> Self {
        NixSchema {
            name: name.into(),
            schema: schemars::schema_for!(T),
            extensions: Vec::new(),
        }
    }

    /// merge defaults from a serialised `T::default()` into the schema
    ///
    /// walks the schema's `properties` and sets `default` values from the
    /// provided JSON object. recurses into nested objects
    pub fn with_defaults(mut self, defaults: serde_json::Value) -> Self {
        if let serde_json::Value::Object(map) = defaults {
            merge_defaults(&mut self.schema, &map);
        }
        self
    }

    /// add a root-level extension property to the schema
    pub fn with_extension(mut self, key: impl Into<String>, value: impl serde::Serialize) -> Self {
        self.extensions.push((
            key.into(),
            serde_json::to_value(value).expect("extension value must be serialisable"),
        ));
        self
    }

    /// serialise to pretty JSON with nixcfg wrapper
    pub fn to_json_pretty(&self) -> String {
        let mut root = serde_json::to_value(&self.schema).expect("schema serialisation failed");
        if let serde_json::Value::Object(ref mut map) = root {
            map.insert(
                "x-nixcfg-name".to_string(),
                serde_json::Value::String(self.name.clone()),
            );
            for (k, v) in &self.extensions {
                map.insert(k.clone(), v.clone());
            }
        }
        serde_json::to_string_pretty(&root).expect("schema serialisation failed")
    }
}

fn merge_defaults(
    schema: &mut schemars::Schema,
    defaults: &serde_json::Map<String, serde_json::Value>,
) {
    let obj = match schema.as_object_mut() {
        Some(o) => o,
        None => return,
    };

    let props = match obj.get_mut("properties") {
        Some(serde_json::Value::Object(p)) => p,
        _ => return,
    };

    for (key, default_val) in defaults {
        let Some(serde_json::Value::Object(prop)) = props.get_mut(key) else {
            continue;
        };

        // skip secrets (they shouldn't carry defaults)
        if prop.get("x-nixcfg-secret") == Some(&serde_json::Value::Bool(true)) {
            continue;
        }

        // recurse into nested objects
        if prop.get("type") == Some(&serde_json::Value::String("object".to_string()))
            && let serde_json::Value::Object(sub_defaults) = default_val
        {
            let mut sub_schema: schemars::Schema =
                serde_json::from_value(serde_json::Value::Object(prop.clone())).unwrap_or_default();
            merge_defaults(&mut sub_schema, sub_defaults);
            *prop = serde_json::to_value(&sub_schema)
                .unwrap()
                .as_object()
                .unwrap()
                .clone();
            continue;
        }

        // for anyOf (optional types), check if there's an object variant to recurse into
        if let Some(serde_json::Value::Array(any_of)) = prop.get("anyOf")
            && let serde_json::Value::Object(sub_defaults) = default_val
        {
            for variant in any_of {
                if let serde_json::Value::Object(v) = variant
                    && v.get("type") == Some(&serde_json::Value::String("object".to_string()))
                {
                    let sub_value = serde_json::Value::Object(v.clone());
                    let mut sub_schema: schemars::Schema =
                        serde_json::from_value(sub_value).unwrap_or_default();
                    merge_defaults(&mut sub_schema, sub_defaults);
                    break;
                }
            }
        }

        // set the default value (annotation defaults take priority)
        if !prop.contains_key("default") {
            prop.insert("default".to_string(), default_val.clone());
        }
    }
}

#[cfg(test)]
#[allow(dead_code)]
mod tests {
    use super::*;
    use schemars::JsonSchema;
    use serde::Serialize;

    #[derive(JsonSchema, Serialize)]
    /// mycel discord bot configuration
    struct Config {
        /// directory for the database, models, and workspace
        #[serde(default = "default_data_dir")]
        data_dir: String,

        /// log level
        log_level: LogLevel,

        /// discord bot token
        #[schemars(extend("x-nixcfg-secret" = true))]
        discord_token: String,

        /// listen port
        #[schemars(extend("x-nixcfg-port" = true))]
        port: u16,
    }

    fn default_data_dir() -> String {
        "/var/lib/mycel".to_string()
    }

    #[derive(JsonSchema, Serialize)]
    enum LogLevel {
        Trace,
        Debug,
        Info,
        Warn,
        Error,
    }

    #[test]
    fn schema_has_name() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        assert_eq!(json["x-nixcfg-name"], "mycel");
    }

    #[test]
    fn schema_has_properties() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        assert!(json["properties"]["data_dir"].is_object());
        assert!(json["properties"]["discord_token"].is_object());
        assert!(json["properties"]["port"].is_object());
    }

    #[test]
    fn secret_extension() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        assert_eq!(json["properties"]["discord_token"]["x-nixcfg-secret"], true);
        // non-secret fields don't have the extension
        assert!(
            json["properties"]["data_dir"]
                .get("x-nixcfg-secret")
                .is_none()
        );
    }

    #[test]
    fn port_extension() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        assert_eq!(json["properties"]["port"]["x-nixcfg-port"], true);
    }

    #[test]
    fn descriptions_from_doc_comments() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        assert_eq!(
            json["properties"]["data_dir"]["description"],
            "directory for the database, models, and workspace"
        );
        assert_eq!(json["description"], "mycel discord bot configuration");
    }

    #[test]
    fn defaults_merged() {
        let schema = NixSchema::from::<Config>("mycel");
        let defaults = serde_json::json!({
            "data_dir": "/var/lib/mycel",
            "log_level": "Info",
            "discord_token": "secret",
            "port": 8080
        });
        let schema = schema.with_defaults(defaults);
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

        // default set on data_dir (from serde default attr, should already be there)
        // port gets default from with_defaults
        assert_eq!(json["properties"]["port"]["default"], 8080);
        // secret fields don't get defaults
        assert!(json["properties"]["discord_token"].get("default").is_none());
    }

    #[test]
    fn enum_generates_variants() {
        let schema = NixSchema::from::<Config>("mycel");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();
        // log_level should reference LogLevel enum via $ref or inline
        // the exact shape depends on schemars, but it should exist
        assert!(json["properties"]["log_level"].is_object());
    }

    // ── nixcfg attribute macro ────────────────────────────────────

    #[crate::nixcfg]
    #[derive(JsonSchema, Serialize)]
    #[allow(dead_code)]
    struct MacroConfig {
        /// api key
        #[nixcfg(secret)]
        api_key: String,

        /// listen port
        #[nixcfg(port)]
        listen_port: u16,

        /// state dir
        #[nixcfg(path)]
        data_dir: String,

        /// runtime-only
        #[nixcfg(skip)]
        runtime_handle: String,

        /// combined secret path
        #[nixcfg(secret, path)]
        pem_path: String,

        /// override description and example
        #[nixcfg(
            description = "long prose description for nix option docs",
            example = "/var/lib/app"
        )]
        hooks_cwd: String,
    }

    #[test]
    fn macro_rewrites_flags() {
        let schema = NixSchema::from::<MacroConfig>("macro-test");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

        assert_eq!(
            json["properties"]["api_key"]["x-nixcfg-secret"], true,
            "secret flag should be emitted"
        );
        assert_eq!(
            json["properties"]["listen_port"]["x-nixcfg-port"], true,
            "port flag should be emitted"
        );
        assert_eq!(
            json["properties"]["data_dir"]["x-nixcfg-path"], true,
            "path flag should be emitted"
        );
        assert_eq!(
            json["properties"]["runtime_handle"]["x-nixcfg-skip"], true,
            "skip flag should be emitted"
        );
    }

    #[test]
    fn macro_combines_flags() {
        let schema = NixSchema::from::<MacroConfig>("macro-test");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

        assert_eq!(json["properties"]["pem_path"]["x-nixcfg-secret"], true);
        assert_eq!(json["properties"]["pem_path"]["x-nixcfg-path"], true);
    }

    #[test]
    fn macro_key_value_pairs() {
        let schema = NixSchema::from::<MacroConfig>("macro-test");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

        assert_eq!(
            json["properties"]["hooks_cwd"]["x-nixcfg-description"],
            "long prose description for nix option docs"
        );
        assert_eq!(
            json["properties"]["hooks_cwd"]["x-nixcfg-example"],
            "/var/lib/app"
        );
    }

    // ── schema_with escape hatch ──────────────────────────────────
    //
    // verifies the pattern used for foreign types that can't (or shouldn't)
    // impl JsonSchema locally: hand-roll the schema fragment including any
    // x-nixcfg-* extensions, hook it up via #[schemars(schema_with = ...)].
    // nixcfg reads the resulting schema the same way it reads any other.

    // a foreign type we don't want (or can't) derive JsonSchema on
    #[derive(Serialize, Default)]
    #[allow(dead_code)]
    struct OpaqueForeign {
        host: String,
    }

    fn opaque_schema(_g: &mut schemars::SchemaGenerator) -> schemars::Schema {
        serde_json::from_value(serde_json::json!({
            "type": "object",
            "properties": {
                "host": { "type": "string" }
            },
            "x-nixcfg-skip": true,
            "description": "provided via schema_with"
        }))
        .unwrap()
    }

    #[derive(JsonSchema, Serialize)]
    #[allow(dead_code)]
    struct ContainerWithOpaque {
        /// normal field
        name: String,

        // no doc comment here: schemars would apply it as the field description,
        // overriding whatever the schema_with function produces. leaving it off
        // lets the hand-rolled schema's own description win
        #[schemars(schema_with = "opaque_schema")]
        opaque: OpaqueForeign,
    }

    #[test]
    fn schema_with_round_trips_extensions() {
        let schema = NixSchema::from::<ContainerWithOpaque>("schema-with-test");
        let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

        // extension from the hand-rolled fragment lands in the schema
        assert_eq!(json["properties"]["opaque"]["x-nixcfg-skip"], true);
        assert_eq!(
            json["properties"]["opaque"]["description"],
            "provided via schema_with"
        );
        // normal derived field is untouched
        assert_eq!(json["properties"]["name"]["type"], "string");
    }
}
