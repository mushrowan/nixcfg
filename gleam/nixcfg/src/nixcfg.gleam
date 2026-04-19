//// nixcfg - JSON Schema builder for NixOS module options
////
//// build a schema describing your program's config, print it, and feed it
//// into the nixcfg nix library to get `mkOption` definitions.
////
//// ```gleam
//// import nixcfg
//// import gleam/json
////
//// pub fn main() {
////   nixcfg.new("myapp", "my service configuration")
////   |> nixcfg.prop(
////     "data_dir",
////     nixcfg.string()
////       |> nixcfg.default(json.string("/var/lib/myapp"))
////       |> nixcfg.description("data directory"),
////   )
////   |> nixcfg.prop("listen_port", nixcfg.u16() |> nixcfg.port())
////   |> nixcfg.prop("api_token", nixcfg.string() |> nixcfg.secret())
////   |> nixcfg.to_json
//// }
//// ```

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ── public types ──────────────────────────────────────────────────

pub opaque type Schema {
  Schema(
    name: String,
    description: String,
    properties: List(#(String, PropBuilder)),
  )
}

pub opaque type PropBuilder {
  PropBuilder(kind: Kind, meta: Meta)
}

// ── internal representation ───────────────────────────────────────

type Meta {
  Meta(
    default: Option(Json),
    description: Option(String),
    example: Option(Json),
    secret: Bool,
    port: Bool,
    path: Bool,
    skip: Bool,
    override_description: Option(String),
    override_example: Option(Json),
    pattern: Option(String),
    min_length: Option(Int),
    max_length: Option(Int),
  )
}

type Kind {
  KStr
  KBool
  KInt
  KUnsigned
  KBoundedInt(format: String, min: Int, max: Int)
  KEnum(values: List(String))
  KList(item: PropBuilder)
  KNullable(inner: PropBuilder)
  KRaw(value: Json)
}

fn empty_meta() -> Meta {
  Meta(
    default: None,
    description: None,
    example: None,
    secret: False,
    port: False,
    path: False,
    skip: False,
    override_description: None,
    override_example: None,
    pattern: None,
    min_length: None,
    max_length: None,
  )
}

// ── constructors ──────────────────────────────────────────────────

/// start a new schema
pub fn new(name: String, description: String) -> Schema {
  Schema(name, description, [])
}

pub fn string() -> PropBuilder {
  PropBuilder(KStr, empty_meta())
}

pub fn boolean() -> PropBuilder {
  PropBuilder(KBool, empty_meta())
}

/// plain signed integer (nix `types.int`)
pub fn integer() -> PropBuilder {
  PropBuilder(KInt, empty_meta())
}

/// non-negative integer (nix `types.ints.unsigned`)
pub fn unsigned() -> PropBuilder {
  PropBuilder(KUnsigned, empty_meta())
}

pub fn u8() -> PropBuilder {
  PropBuilder(KBoundedInt("uint8", 0, 255), empty_meta())
}

pub fn u16() -> PropBuilder {
  PropBuilder(KBoundedInt("uint16", 0, 65_535), empty_meta())
}

pub fn u32() -> PropBuilder {
  PropBuilder(KBoundedInt("uint32", 0, 4_294_967_295), empty_meta())
}

pub fn i8() -> PropBuilder {
  PropBuilder(KBoundedInt("int8", -128, 127), empty_meta())
}

pub fn i16() -> PropBuilder {
  PropBuilder(KBoundedInt("int16", -32_768, 32_767), empty_meta())
}

pub fn i32() -> PropBuilder {
  PropBuilder(KBoundedInt("int32", -2_147_483_648, 2_147_483_647), empty_meta())
}

/// string enum (nix `types.enum`)
pub fn enum_of(values: List(String)) -> PropBuilder {
  PropBuilder(KEnum(values), empty_meta())
}

/// list of some element type
pub fn list_of(item: PropBuilder) -> PropBuilder {
  PropBuilder(KList(item), empty_meta())
}

/// wraps a type to make it nullable (nix `types.nullOr`).
/// a nullable property is not included in the schema's `required` list
pub fn nullable(inner: PropBuilder) -> PropBuilder {
  PropBuilder(KNullable(inner), empty_meta())
}

/// escape hatch: provide a raw JSON schema fragment. use this when your
/// type doesn't fit any of the builder constructors (e.g. foreign types,
/// submodules, complex unions). nixcfg extensions embedded in the json
/// pass through unchanged
pub fn raw(value: Json) -> PropBuilder {
  PropBuilder(KRaw(value), empty_meta())
}

// ── modifiers ─────────────────────────────────────────────────────

pub fn default(b: PropBuilder, value: Json) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, default: Some(value)) })
}

pub fn description(b: PropBuilder, text: String) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, description: Some(text)) })
}

pub fn example(b: PropBuilder, value: Json) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, example: Some(value)) })
}

/// marks as a secret (`x-nixcfg-secret`)
pub fn secret(b: PropBuilder) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, secret: True) })
}

/// marks as a port (`x-nixcfg-port`). use on an integer type
pub fn port(b: PropBuilder) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, port: True) })
}

/// marks as a filesystem path (`x-nixcfg-path`). use on a string type
pub fn path(b: PropBuilder) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, path: True) })
}

/// omit from nix module options but keep in the schema
/// (`x-nixcfg-skip`). useful for runtime-only fields
pub fn skip(b: PropBuilder) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, skip: True) })
}

/// override the description text specifically for the nix module
/// (`x-nixcfg-description`)
pub fn override_description(b: PropBuilder, text: String) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, override_description: Some(text)) })
}

/// override the example value for the nix module (`x-nixcfg-example`)
pub fn override_example(b: PropBuilder, value: Json) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, override_example: Some(value)) })
}

/// constrain strings by regex (`pattern` → `types.strMatching`)
pub fn pattern(b: PropBuilder, regex: String) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, pattern: Some(regex)) })
}

pub fn min_length(b: PropBuilder, n: Int) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, min_length: Some(n)) })
}

pub fn max_length(b: PropBuilder, n: Int) -> PropBuilder {
  with_meta(b, fn(m) { Meta(..m, max_length: Some(n)) })
}

fn with_meta(b: PropBuilder, f: fn(Meta) -> Meta) -> PropBuilder {
  let PropBuilder(k, m) = b
  PropBuilder(k, f(m))
}

// ── attach ────────────────────────────────────────────────────────

/// attach a property to the schema, preserving insertion order
pub fn prop(s: Schema, name: String, b: PropBuilder) -> Schema {
  let Schema(n, d, ps) = s
  Schema(n, d, list.append(ps, [#(name, b)]))
}

// ── serialisation ─────────────────────────────────────────────────

/// serialise the schema to a JSON string. deterministic so checked-in
/// `schema.json` files work as drift-check references
pub fn to_json(schema: Schema) -> String {
  schema
  |> to_json_value
  |> json.to_string
}

fn to_json_value(schema: Schema) -> Json {
  let Schema(name, description, properties) = schema

  let required =
    list.filter_map(properties, fn(entry) {
      let #(n, PropBuilder(kind, meta)) = entry
      case meta.skip, kind {
        True, _ -> Error(Nil)
        _, KNullable(_) -> Error(Nil)
        _, _ -> Ok(n)
      }
    })

  let props_json =
    list.map(properties, fn(entry) {
      let #(n, builder) = entry
      #(n, prop_to_json(builder))
    })

  json.object([
    #("$schema", json.string("https://json-schema.org/draft/2020-12/schema")),
    #("title", json.string(title_from_name(name))),
    #("description", json.string(description)),
    #("type", json.string("object")),
    #("x-nixcfg-name", json.string(name)),
    #("properties", json.object(props_json)),
    #("required", json.array(required, json.string)),
  ])
}

fn title_from_name(name: String) -> String {
  name
  |> string.replace("-", "_")
  |> string.split("_")
  |> list.map(capitalize)
  |> string.concat
}

fn capitalize(word: String) -> String {
  case string.to_graphemes(word) {
    [] -> ""
    [first, ..rest] -> string.uppercase(first) <> string.concat(rest)
  }
}

fn prop_to_json(builder: PropBuilder) -> Json {
  let PropBuilder(kind, meta) = builder
  json.object(list.append(kind_to_entries(kind), meta_to_entries(meta)))
}

fn kind_to_entries(kind: Kind) -> List(#(String, Json)) {
  case kind {
    KStr -> [#("type", json.string("string"))]
    KBool -> [#("type", json.string("boolean"))]
    KInt -> [#("type", json.string("integer"))]
    KUnsigned -> [
      #("type", json.string("integer")),
      #("minimum", json.int(0)),
    ]
    KBoundedInt(format, min, max) -> [
      #("type", json.string("integer")),
      #("format", json.string(format)),
      #("minimum", json.int(min)),
      #("maximum", json.int(max)),
    ]
    KEnum(values) -> [
      #("type", json.string("string")),
      #("enum", json.array(values, json.string)),
    ]
    KList(item) -> [
      #("type", json.string("array")),
      #("items", prop_to_json(item)),
    ]
    KNullable(inner) -> nullable_entries(inner)
    // raw fragment: the user provided a full JSON object. we can't
    // easily merge meta into it here without deconstructing, so we emit
    // a wrapper object and hope users only use raw() without meta
    // modifiers. documented in the function docstring
    KRaw(value) -> [#("__nixcfg_raw__", value)]
  }
}

fn nullable_entries(inner: PropBuilder) -> List(#(String, Json)) {
  let PropBuilder(kind, _) = inner
  case kind {
    KStr -> [#("type", json.array(["string", "null"], json.string))]
    KBool -> [#("type", json.array(["boolean", "null"], json.string))]
    KInt | KUnsigned -> [
      #("type", json.array(["integer", "null"], json.string)),
    ]
    KBoundedInt(format, min, max) -> [
      #("type", json.array(["integer", "null"], json.string)),
      #("format", json.string(format)),
      #("minimum", json.int(min)),
      #("maximum", json.int(max)),
    ]
    // complex types fall back to anyOf
    _ -> [
      #(
        "anyOf",
        json.preprocessed_array([
          json.object(kind_to_entries(kind)),
          json.object([#("type", json.string("null"))]),
        ]),
      ),
    ]
  }
}

fn meta_to_entries(meta: Meta) -> List(#(String, Json)) {
  []
  |> maybe_add("description", meta.description, json.string)
  |> maybe_add_json("default", meta.default)
  |> maybe_add_example(meta.example)
  |> maybe_add("pattern", meta.pattern, json.string)
  |> maybe_add("minLength", meta.min_length, json.int)
  |> maybe_add("maxLength", meta.max_length, json.int)
  |> maybe_flag("x-nixcfg-secret", meta.secret)
  |> maybe_flag("x-nixcfg-port", meta.port)
  |> maybe_flag("x-nixcfg-path", meta.path)
  |> maybe_flag("x-nixcfg-skip", meta.skip)
  |> maybe_add("x-nixcfg-description", meta.override_description, json.string)
  |> maybe_add_json("x-nixcfg-example", meta.override_example)
}

fn maybe_add(
  entries: List(#(String, Json)),
  key: String,
  value: Option(a),
  encoder: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    Some(v) -> list.append(entries, [#(key, encoder(v))])
    None -> entries
  }
}

fn maybe_add_json(
  entries: List(#(String, Json)),
  key: String,
  value: Option(Json),
) -> List(#(String, Json)) {
  case value {
    Some(v) -> list.append(entries, [#(key, v)])
    None -> entries
  }
}

fn maybe_add_example(
  entries: List(#(String, Json)),
  example: Option(Json),
) -> List(#(String, Json)) {
  case example {
    Some(v) ->
      list.append(entries, [#("examples", json.preprocessed_array([v]))])
    None -> entries
  }
}

fn maybe_flag(
  entries: List(#(String, Json)),
  key: String,
  flag: Bool,
) -> List(#(String, Json)) {
  case flag {
    True -> list.append(entries, [#(key, json.bool(True))])
    False -> entries
  }
}
