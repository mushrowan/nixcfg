import gleam/json
import gleam/string
import gleeunit
import nixcfg

pub fn main() {
  gleeunit.main()
}

// ── smoke: empty schema serialises ────────────────────────────────

pub fn empty_schema_test() {
  let out =
    nixcfg.new("myapp", "test service")
    |> nixcfg.to_json

  assert string.contains(out, "\"x-nixcfg-name\":\"myapp\"")
  assert string.contains(out, "\"type\":\"object\"")
  assert string.contains(out, "\"description\":\"test service\"")
  assert string.contains(out, "\"properties\":{}")
}

// ── types ─────────────────────────────────────────────────────────

pub fn string_prop_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop(
      "name",
      nixcfg.string() |> nixcfg.default(json.string("hello")),
    )
    |> nixcfg.to_json

  assert string.contains(
    out,
    "\"name\":{\"type\":\"string\",\"default\":\"hello\"}",
  )
}

pub fn integer_formats_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("port", nixcfg.u16())
    |> nixcfg.prop("count", nixcfg.i32())
    |> nixcfg.to_json

  assert string.contains(out, "\"format\":\"uint16\"")
  assert string.contains(out, "\"maximum\":65535")
  assert string.contains(out, "\"format\":\"int32\"")
  assert string.contains(out, "\"minimum\":-2147483648")
}

pub fn enum_of_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop(
      "level",
      nixcfg.enum_of(["low", "high"])
        |> nixcfg.default(json.string("low")),
    )
    |> nixcfg.to_json

  assert string.contains(out, "\"enum\":[\"low\",\"high\"]")
  assert string.contains(out, "\"default\":\"low\"")
}

pub fn list_of_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("tags", nixcfg.list_of(nixcfg.string()))
    |> nixcfg.to_json

  assert string.contains(out, "\"type\":\"array\"")
  assert string.contains(out, "\"items\":{\"type\":\"string\"}")
}

pub fn nullable_scalar_uses_type_array_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("hint", nixcfg.nullable(nixcfg.string()))
    |> nixcfg.to_json

  assert string.contains(out, "\"type\":[\"string\",\"null\"]")
}

// ── annotations ───────────────────────────────────────────────────

pub fn secret_flag_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("token", nixcfg.string() |> nixcfg.secret())
    |> nixcfg.to_json

  assert string.contains(out, "\"x-nixcfg-secret\":true")
}

pub fn port_flag_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("port", nixcfg.u16() |> nixcfg.port())
    |> nixcfg.to_json

  assert string.contains(out, "\"x-nixcfg-port\":true")
}

pub fn path_flag_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("data_dir", nixcfg.string() |> nixcfg.path())
    |> nixcfg.to_json

  assert string.contains(out, "\"x-nixcfg-path\":true")
}

pub fn skip_flag_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("handle", nixcfg.string() |> nixcfg.skip())
    |> nixcfg.to_json

  assert string.contains(out, "\"x-nixcfg-skip\":true")
}

pub fn description_override_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop(
      "cwd",
      nixcfg.string()
        |> nixcfg.description("short")
        |> nixcfg.override_description("long prose for nix"),
    )
    |> nixcfg.to_json

  assert string.contains(out, "\"description\":\"short\"")
  assert string.contains(out, "\"x-nixcfg-description\":\"long prose for nix\"")
}

// ── validation ────────────────────────────────────────────────────

pub fn pattern_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop(
      "slug",
      nixcfg.string()
        |> nixcfg.pattern("^[a-z]+$")
        |> nixcfg.min_length(3)
        |> nixcfg.max_length(16),
    )
    |> nixcfg.to_json

  assert string.contains(out, "\"pattern\":\"^[a-z]+$\"")
  assert string.contains(out, "\"minLength\":3")
  assert string.contains(out, "\"maxLength\":16")
}

// ── required list ─────────────────────────────────────────────────

pub fn required_excludes_nullable_and_skip_test() {
  let out =
    nixcfg.new("t", "")
    |> nixcfg.prop("always_here", nixcfg.string())
    |> nixcfg.prop("maybe", nixcfg.nullable(nixcfg.string()))
    |> nixcfg.prop("runtime", nixcfg.string() |> nixcfg.skip())
    |> nixcfg.to_json

  assert string.contains(out, "\"required\":[\"always_here\"]")
}
