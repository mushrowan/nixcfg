//! nixcfg - bridge config structs to NixOS module options
//!
//! derive `NixOptions` on a struct to generate a schema that the nixcfg nix
//! library can consume to produce `lib.mkOption` definitions

// allow ::nixcfg:: paths to resolve in derive-macro output used within this crate
extern crate self as nixcfg;

use serde::ser::{SerializeMap, Serializer};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

#[cfg(feature = "derive")]
pub use nixcfg_derive::{NixCfg, NixOptions};

// re-exported for generated code
pub use serde_json;

// ---------- schema types ----------

/// type representation matching the nixcfg schema v1 spec
#[derive(Debug, Clone, PartialEq)]
pub enum SchemaType {
    String,
    Bool,
    Int,
    Uint,
    Path,
    Port,
    Optional(Box<SchemaType>),
    List(Box<SchemaType>),
    Attrs(Box<SchemaType>),
    Enum(Vec<std::string::String>),
    Submodule(Vec<(std::string::String, OptionDef)>),
}

impl serde::Serialize for SchemaType {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::String => ser.serialize_str("string"),
            Self::Bool => ser.serialize_str("bool"),
            Self::Int => ser.serialize_str("int"),
            Self::Uint => ser.serialize_str("uint"),
            Self::Path => ser.serialize_str("path"),
            Self::Port => ser.serialize_str("port"),
            Self::Optional(inner) => {
                let mut m = ser.serialize_map(Some(1))?;
                m.serialize_entry("optional", inner)?;
                m.end()
            }
            Self::List(inner) => {
                let mut m = ser.serialize_map(Some(1))?;
                m.serialize_entry("list", inner)?;
                m.end()
            }
            Self::Attrs(inner) => {
                let mut m = ser.serialize_map(Some(1))?;
                m.serialize_entry("attrs", inner)?;
                m.end()
            }
            Self::Enum(variants) => {
                let mut m = ser.serialize_map(Some(1))?;
                m.serialize_entry("enum", variants)?;
                m.end()
            }
            Self::Submodule(opts) => {
                let mut m = ser.serialize_map(Some(1))?;
                m.serialize_entry("submodule", &OrderedMap(opts))?;
                m.end()
            }
        }
    }
}

/// a single option in the schema
#[derive(Debug, Clone, PartialEq)]
pub struct OptionDef {
    pub type_: SchemaType,
    pub description: Option<std::string::String>,
    pub default: Option<serde_json::Value>,
    pub example: Option<serde_json::Value>,
    pub secret: bool,
}

impl serde::Serialize for OptionDef {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut len = 1; // type is always present
        if self.description.is_some() {
            len += 1;
        }
        if self.default.is_some() {
            len += 1;
        }
        if self.example.is_some() {
            len += 1;
        }
        if self.secret {
            len += 1;
        }
        let mut m = ser.serialize_map(Some(len))?;
        m.serialize_entry("type", &self.type_)?;
        if let Some(ref d) = self.description {
            m.serialize_entry("description", d)?;
        }
        if let Some(ref d) = self.default {
            m.serialize_entry("default", d)?;
        }
        if let Some(ref e) = self.example {
            m.serialize_entry("example", e)?;
        }
        if self.secret {
            m.serialize_entry("secret", &true)?;
        }
        m.end()
    }
}

/// complete schema for a service/program
#[derive(Debug, Clone)]
pub struct Schema {
    pub version: u32,
    pub name: std::string::String,
    pub description: Option<std::string::String>,
    pub options: Vec<(std::string::String, OptionDef)>,
}

impl Schema {
    /// create a schema from a type implementing NixOptions
    pub fn from<T: NixOptions>(name: impl Into<std::string::String>) -> Self {
        Schema {
            version: 1,
            name: name.into(),
            description: T::description().map(std::string::String::from),
            options: T::nix_options(),
        }
    }

    /// override the description
    pub fn with_description(mut self, desc: impl Into<std::string::String>) -> Self {
        self.description = Some(desc.into());
        self
    }

    /// serialise to pretty JSON
    pub fn to_json_pretty(&self) -> std::string::String {
        serde_json::to_string_pretty(self).expect("schema serialisation failed")
    }

    /// serialise to compact JSON
    pub fn to_json(&self) -> std::string::String {
        serde_json::to_string(self).expect("schema serialisation failed")
    }
}

impl serde::Serialize for Schema {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut m = ser.serialize_map(None)?;
        m.serialize_entry("version", &self.version)?;
        m.serialize_entry("name", &self.name)?;
        if let Some(ref d) = self.description {
            m.serialize_entry("description", d)?;
        }
        m.serialize_entry("options", &OrderedMap(&self.options))?;
        m.end()
    }
}

/// helper: serialise `&[(String, T)]` as a JSON object preserving order
struct OrderedMap<'a, T: serde::Serialize>(&'a [(std::string::String, T)]);

impl<T: serde::Serialize> serde::Serialize for OrderedMap<'_, T> {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut m = ser.serialize_map(Some(self.0.len()))?;
        for (k, v) in self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

// ---------- traits ----------

/// any type that maps to a nixcfg schema type
pub trait NixType {
    fn schema_type() -> SchemaType;
}

/// structs whose fields map to nixcfg option definitions
pub trait NixOptions {
    fn nix_options() -> Vec<(std::string::String, OptionDef)>;

    /// description extracted from doc comments (override via derive macro)
    fn description() -> Option<&'static str> {
        None
    }
}

// ---------- built-in NixType impls ----------

impl NixType for std::string::String {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

impl NixType for &str {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

impl NixType for bool {
    fn schema_type() -> SchemaType {
        SchemaType::Bool
    }
}

macro_rules! impl_int {
    ($($t:ty),+) => { $(
        impl NixType for $t {
            fn schema_type() -> SchemaType { SchemaType::Int }
        }
    )+ };
}

macro_rules! impl_uint {
    ($($t:ty),+) => { $(
        impl NixType for $t {
            fn schema_type() -> SchemaType { SchemaType::Uint }
        }
    )+ };
}

impl_int!(i8, i16, i32, i64, isize);
impl_uint!(u8, u16, u32, u64, usize);

impl NixType for PathBuf {
    fn schema_type() -> SchemaType {
        SchemaType::Path
    }
}

impl NixType for std::path::Path {
    fn schema_type() -> SchemaType {
        SchemaType::Path
    }
}

impl<T: NixType> NixType for Option<T> {
    fn schema_type() -> SchemaType {
        SchemaType::Optional(Box::new(T::schema_type()))
    }
}

impl<T: NixType> NixType for Vec<T> {
    fn schema_type() -> SchemaType {
        SchemaType::List(Box::new(T::schema_type()))
    }
}

impl<K, V: NixType> NixType for HashMap<K, V> {
    fn schema_type() -> SchemaType {
        SchemaType::Attrs(Box::new(V::schema_type()))
    }
}

impl<K, V: NixType> NixType for BTreeMap<K, V> {
    fn schema_type() -> SchemaType {
        SchemaType::Attrs(Box::new(V::schema_type()))
    }
}

// ---------- foreign type impls ----------

#[cfg(feature = "ipnet")]
impl NixType for ipnet::IpNet {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

#[cfg(feature = "ipnet")]
impl NixType for ipnet::Ipv4Net {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

#[cfg(feature = "ipnet")]
impl NixType for ipnet::Ipv6Net {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

#[cfg(feature = "secrecy")]
impl NixType for secrecy::SecretString {
    fn schema_type() -> SchemaType {
        SchemaType::String
    }
}

// ---------- defaults merging ----------

impl Schema {
    /// merge defaults from a serde-serialised `T::default()` value into the
    /// schema. fields present in the JSON object override any `#[nixcfg(default)]`
    /// annotation. nested submodules are merged recursively
    pub fn with_defaults(mut self, defaults: serde_json::Value) -> Self {
        if let serde_json::Value::Object(map) = defaults {
            merge_defaults(&mut self.options, &map);
        }
        self
    }
}

fn merge_defaults(
    options: &mut [(std::string::String, OptionDef)],
    defaults: &serde_json::Map<std::string::String, serde_json::Value>,
) {
    for (name, opt) in options.iter_mut() {
        let Some(val) = defaults.get(name) else {
            continue;
        };
        // recurse into submodules
        if let SchemaType::Submodule(ref mut sub_opts) = opt.type_
            && let serde_json::Value::Object(sub_map) = val
        {
            merge_defaults(sub_opts, sub_map);
            continue;
        }
        // for optional submodules, recurse into the inner submodule
        if let SchemaType::Optional(ref mut inner) = opt.type_
            && let SchemaType::Submodule(ref mut sub_opts) = **inner
            && let serde_json::Value::Object(sub_map) = val
        {
            merge_defaults(sub_opts, sub_map);
            continue;
        }
        opt.default = Some(val.clone());
    }
}

// ---------- tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn simple_types() {
        assert_eq!(std::string::String::schema_type(), SchemaType::String);
        assert_eq!(bool::schema_type(), SchemaType::Bool);
        assert_eq!(i32::schema_type(), SchemaType::Int);
        assert_eq!(u64::schema_type(), SchemaType::Uint);
        assert_eq!(PathBuf::schema_type(), SchemaType::Path);
    }

    #[test]
    fn composite_types() {
        assert_eq!(
            Option::<std::string::String>::schema_type(),
            SchemaType::Optional(Box::new(SchemaType::String))
        );
        assert_eq!(
            Vec::<i32>::schema_type(),
            SchemaType::List(Box::new(SchemaType::Int))
        );
        assert_eq!(
            HashMap::<std::string::String, bool>::schema_type(),
            SchemaType::Attrs(Box::new(SchemaType::Bool))
        );
    }

    #[test]
    fn nested_optional_list() {
        assert_eq!(
            Option::<Vec<std::string::String>>::schema_type(),
            SchemaType::Optional(Box::new(SchemaType::List(Box::new(SchemaType::String))))
        );
    }

    #[test]
    fn schema_type_serialisation() {
        assert_eq!(
            serde_json::to_value(SchemaType::String).unwrap(),
            serde_json::json!("string")
        );
        assert_eq!(
            serde_json::to_value(SchemaType::Optional(Box::new(SchemaType::Int))).unwrap(),
            serde_json::json!({"optional": "int"})
        );
        assert_eq!(
            serde_json::to_value(SchemaType::Enum(vec!["a".into(), "b".into()])).unwrap(),
            serde_json::json!({"enum": ["a", "b"]})
        );
    }

    #[test]
    fn option_def_serialisation() {
        let opt = OptionDef {
            type_: SchemaType::String,
            description: Some("a field".into()),
            default: Some(serde_json::json!("hello")),
            example: None,
            secret: false,
        };
        let v = serde_json::to_value(&opt).unwrap();
        assert_eq!(v["type"], "string");
        assert_eq!(v["description"], "a field");
        assert_eq!(v["default"], "hello");
        assert!(v.get("secret").is_none());
        assert!(v.get("example").is_none());
    }

    #[test]
    fn option_def_secret_serialisation() {
        let opt = OptionDef {
            type_: SchemaType::String,
            description: None,
            default: None,
            example: None,
            secret: true,
        };
        let v = serde_json::to_value(&opt).unwrap();
        assert_eq!(v["secret"], true);
    }

    // derive macro tests live here when the feature is enabled
    #[cfg(feature = "derive")]
    #[allow(dead_code)]
    mod derive_tests {
        use super::super::*;

        #[derive(NixOptions)]
        /// test service configuration
        struct BasicConfig {
            /// the hostname
            #[nixcfg(default = "localhost")]
            host: std::string::String,

            /// listen port
            #[nixcfg(port, default = 8080)]
            port: u16,

            /// enable debug mode
            #[nixcfg(default = false)]
            debug: bool,

            /// optional description
            description: Option<std::string::String>,

            /// api token
            #[nixcfg(secret)]
            api_token: std::string::String,

            /// optional db password
            #[nixcfg(secret)]
            db_password: Option<std::string::String>,

            /// tags for the service
            tags: Vec<std::string::String>,

            /// extra labels
            labels: HashMap<std::string::String, std::string::String>,
        }

        #[derive(NixOptions)]
        enum LogLevel {
            Trace,
            Debug,
            Info,
            Warn,
            Error,
        }

        #[derive(NixOptions)]
        struct Nested {
            /// log level
            #[nixcfg(default = "info")]
            log_level: std::string::String,

            /// database settings
            db: DatabaseConfig,
        }

        #[derive(NixOptions)]
        /// database connection settings
        struct DatabaseConfig {
            /// database host
            #[nixcfg(default = "localhost")]
            host: std::string::String,

            /// database port
            #[nixcfg(port, default = 5432)]
            port: u16,
        }

        #[test]
        fn basic_struct_options() {
            let opts = BasicConfig::nix_options();
            assert_eq!(opts.len(), 8);

            let (name, opt) = &opts[0];
            assert_eq!(name, "host");
            assert_eq!(opt.type_, SchemaType::String);
            assert_eq!(opt.description.as_deref(), Some("the hostname"));
            assert_eq!(opt.default, Some(serde_json::json!("localhost")));
            assert!(!opt.secret);
        }

        #[test]
        fn port_annotation() {
            let opts = BasicConfig::nix_options();
            let (name, opt) = &opts[1];
            assert_eq!(name, "port");
            assert_eq!(opt.type_, SchemaType::Port);
        }

        #[test]
        fn secret_annotation() {
            let opts = BasicConfig::nix_options();
            let (name, opt) = &opts[4];
            assert_eq!(name, "api_token");
            assert!(opt.secret);
            // type is still String, nix lib handles the transform
            assert_eq!(opt.type_, SchemaType::String);
        }

        #[test]
        fn optional_secret() {
            let opts = BasicConfig::nix_options();
            let (name, opt) = &opts[5];
            assert_eq!(name, "db_password");
            assert!(opt.secret);
            assert_eq!(
                opt.type_,
                SchemaType::Optional(Box::new(SchemaType::String))
            );
        }

        #[test]
        fn composite_fields() {
            let opts = BasicConfig::nix_options();
            let (_, tags) = &opts[6];
            assert_eq!(tags.type_, SchemaType::List(Box::new(SchemaType::String)));
            let (_, labels) = &opts[7];
            assert_eq!(
                labels.type_,
                SchemaType::Attrs(Box::new(SchemaType::String))
            );
        }

        #[test]
        fn enum_type() {
            assert_eq!(
                LogLevel::schema_type(),
                SchemaType::Enum(vec![
                    "trace".into(),
                    "debug".into(),
                    "info".into(),
                    "warn".into(),
                    "error".into(),
                ])
            );
        }

        #[test]
        fn struct_description() {
            assert_eq!(
                BasicConfig::description(),
                Some("test service configuration")
            );
        }

        #[test]
        fn nested_submodule() {
            let opts = Nested::nix_options();
            let (name, opt) = &opts[1];
            assert_eq!(name, "db");
            match &opt.type_ {
                SchemaType::Submodule(sub_opts) => {
                    assert_eq!(sub_opts.len(), 2);
                    assert_eq!(sub_opts[0].0, "host");
                    assert_eq!(sub_opts[1].0, "port");
                    assert_eq!(sub_opts[1].1.type_, SchemaType::Port);
                }
                other => panic!("expected Submodule, got {other:?}"),
            }
        }

        #[test]
        fn full_schema_json() {
            let schema = Schema::from::<BasicConfig>("test-service");
            let json: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

            assert_eq!(json["version"], 1);
            assert_eq!(json["name"], "test-service");
            assert_eq!(json["description"], "test service configuration");
            assert!(json["options"]["host"].is_object());
            assert_eq!(json["options"]["port"]["type"], "port");
            assert_eq!(json["options"]["api_token"]["secret"], true);
        }

        #[test]
        fn mycel_example_roundtrip() {
            #[derive(NixOptions)]
            enum MycelLogLevel {
                Trace,
                Debug,
                Info,
                Warn,
                Error,
            }

            #[derive(NixOptions)]
            /// mycel discord bot configuration
            struct MycelConfig {
                /// directory for the database, models, and workspace
                #[nixcfg(default = "/var/lib/mycel")]
                data_dir: PathBuf,

                /// anthropic model to use
                #[nixcfg(default = "claude-sonnet-4-20250514")]
                model: std::string::String,

                /// log level
                #[nixcfg(default = "info")]
                log_level: MycelLogLevel,

                /// keep the prompt cache warm between messages
                #[nixcfg(default = false)]
                cache_warming: bool,

                /// discord bot token
                #[nixcfg(secret)]
                discord_token: std::string::String,

                /// anthropic API key (not needed with OAuth)
                #[nixcfg(secret)]
                anthropic_key: Option<std::string::String>,
            }

            let schema = Schema::from::<MycelConfig>("mycel");
            let actual: serde_json::Value = serde_json::from_str(&schema.to_json_pretty()).unwrap();

            // matches examples/mycel.json
            let expected = serde_json::json!({
                "version": 1,
                "name": "mycel",
                "description": "mycel discord bot configuration",
                "options": {
                    "data_dir": {
                        "type": "path",
                        "default": "/var/lib/mycel",
                        "description": "directory for the database, models, and workspace"
                    },
                    "model": {
                        "type": "string",
                        "default": "claude-sonnet-4-20250514",
                        "description": "anthropic model to use"
                    },
                    "log_level": {
                        "type": { "enum": ["trace", "debug", "info", "warn", "error"] },
                        "default": "info",
                        "description": "log level"
                    },
                    "cache_warming": {
                        "type": "bool",
                        "default": false,
                        "description": "keep the prompt cache warm between messages"
                    },
                    "discord_token": {
                        "type": "string",
                        "secret": true,
                        "description": "discord bot token"
                    },
                    "anthropic_key": {
                        "type": { "optional": "string" },
                        "secret": true,
                        "description": "anthropic API key (not needed with OAuth)"
                    }
                }
            });

            assert_eq!(actual, expected);
        }
    }
}
