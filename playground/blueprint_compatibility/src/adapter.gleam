// THROWAWAY: Can an existing decoder acquire an explicit lab encoder safely?
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import json/blueprint as legacy
import lab/blueprint
import lab/value

// The native encoder is caller-owned. The legacy decoder remains authoritative
// for decode behavior; no legacy schema is guessed into the lab's finite schema.
pub fn adapt(
  decoder: legacy.Decoder(a),
  encode: fn(a) -> Result(value.Value, blueprint.EncodeError),
) -> blueprint.Codec(a) {
  blueprint.new(
    fn(item) {
      case encode(item) {
        Error(error) -> Error(error)
        Ok(encoded) ->
          case validate_value(encoded) {
            Error(reason) -> Error(blueprint.CannotEncode(reason))
            Ok(Nil) -> Ok(encoded)
          }
      }
    },
    fn(raw) {
      case value_to_json(raw) {
        Error(reason) -> Error(blueprint.CannotDecode(reason))
        Ok(json_value) ->
          case legacy.decode(using: decoder, from: json.to_string(json_value)) {
            Ok(decoded) -> Ok(decoded)
            Error(_) ->
              Error(blueprint.CannotDecode(
                "json_blueprint 1.7.1 rejected the Value",
              ))
          }
      }
    },
  )
}

pub fn encode_json(
  codec: blueprint.Codec(a),
  item: a,
) -> Result(String, blueprint.EncodeError) {
  case blueprint.encode(codec, item) {
    Error(error) -> Error(error)
    Ok(encoded) ->
      case value_to_json(encoded) {
        Error(reason) -> Error(blueprint.CannotEncode(reason))
        Ok(json_value) -> Ok(json.to_string(json_value))
      }
  }
}

pub fn value_to_json(item: value.Value) -> Result(json.Json, String) {
  case validate_value(item) {
    Error(reason) -> Error(reason)
    Ok(Nil) -> convert_value(item)
  }
}

pub fn upstream_schema_value(
  decoder: legacy.Decoder(a),
) -> Result(value.Value, String) {
  let schema = legacy.generate_json_schema(decoder)
  let encoded = json.to_string(schema)
  case json.parse(from: encoded, using: decode.dynamic) {
    Error(_) -> Error("Could not parse json_blueprint schema output")
    Ok(dynamic) -> dynamic_to_value(dynamic)
  }
}

fn validate_value(item: value.Value) -> Result(Nil, String) {
  case item {
    value.Null -> Ok(Nil)
    value.Bool(_) -> Ok(Nil)
    value.Int(_) -> Ok(Nil)
    value.Text(_) -> Ok(Nil)
    value.Array(items) -> validate_values(items)
    value.Object(fields) -> validate_fields(fields)
  }
}

fn validate_values(items: List(value.Value)) -> Result(Nil, String) {
  case items {
    [] -> Ok(Nil)
    [item, ..rest] -> {
      use Nil <- result.try(validate_value(item))
      validate_values(rest)
    }
  }
}

fn validate_fields(
  fields: List(#(String, value.Value)),
) -> Result(Nil, String) {
  case fields {
    [] -> Ok(Nil)
    [#(key, item), ..rest] -> {
      case contains_key(key, rest) {
        True -> Error("Duplicate object key")
        False -> {
          use Nil <- result.try(validate_value(item))
          validate_fields(rest)
        }
      }
    }
  }
}

fn contains_key(key: String, fields: List(#(String, value.Value))) -> Bool {
  case fields {
    [] -> False
    [#(field, _), ..rest] -> field == key || contains_key(key, rest)
  }
}

fn convert_value(item: value.Value) -> Result(json.Json, String) {
  case item {
    value.Null -> Ok(json.null())
    value.Bool(boolean) -> Ok(json.bool(boolean))
    value.Int(integer) -> Ok(json.int(integer))
    value.Text(text) -> Ok(json.string(text))
    value.Array(items) -> {
      use converted <- result.try(convert_values(items))
      Ok(json.preprocessed_array(converted))
    }
    value.Object(fields) -> {
      use converted <- result.try(convert_fields(fields))
      Ok(json.object(converted))
    }
  }
}

fn convert_values(items: List(value.Value)) -> Result(List(json.Json), String) {
  case items {
    [] -> Ok([])
    [item, ..rest] -> {
      use converted <- result.try(convert_value(item))
      use converted_rest <- result.try(convert_values(rest))
      Ok([converted, ..converted_rest])
    }
  }
}

fn convert_fields(
  fields: List(#(String, value.Value)),
) -> Result(List(#(String, json.Json)), String) {
  case fields {
    [] -> Ok([])
    [#(key, item), ..rest] -> {
      use converted <- result.try(convert_value(item))
      use converted_rest <- result.try(convert_fields(rest))
      Ok([#(key, converted), ..converted_rest])
    }
  }
}

fn dynamic_to_value(dynamic: Dynamic) -> Result(value.Value, String) {
  case decode.run(dynamic, decode.optional(decode.dynamic)) {
    Ok(None) -> Ok(value.Null)
    Ok(Some(non_null)) -> dynamic_non_null(non_null)
    Error(_) -> dynamic_non_null(dynamic)
  }
}

fn dynamic_non_null(dynamic: Dynamic) -> Result(value.Value, String) {
  case decode.run(dynamic, decode.string) {
    Ok(text) -> Ok(value.Text(text))
    Error(_) ->
      case decode.run(dynamic, decode.bool) {
        Ok(boolean) -> Ok(value.Bool(boolean))
        Error(_) ->
          case decode.run(dynamic, decode.int) {
            Ok(integer) -> Ok(value.Int(integer))
            Error(_) ->
              case decode.run(dynamic, decode.list(of: decode.dynamic)) {
                Ok(items) -> dynamic_values_to_value(items)
                Error(_) ->
                  case
                    decode.run(
                      dynamic,
                      decode.dict(decode.string, decode.dynamic),
                    )
                  {
                    Ok(fields) -> dynamic_fields_to_value(dict.to_list(fields))
                    Error(_) ->
                      Error("Schema contains a JSON value outside lab Value")
                  }
              }
          }
      }
  }
}

fn dynamic_values_to_value(
  items: List(Dynamic),
) -> Result(value.Value, String) {
  case items {
    [] -> Ok(value.Array([]))
    [item, ..rest] -> {
      use converted <- result.try(dynamic_to_value(item))
      use converted_rest <- result.try(dynamic_values_to_value(rest))
      case converted_rest {
        value.Array(rest) -> Ok(value.Array([converted, ..rest]))
        _ -> Error("Internal array conversion failed")
      }
    }
  }
}

fn dynamic_fields_to_value(
  fields: List(#(String, Dynamic)),
) -> Result(value.Value, String) {
  case fields {
    [] -> Ok(value.Object([]))
    [#(key, item), ..rest] -> {
      use converted <- result.try(dynamic_to_value(item))
      use converted_rest <- result.try(dynamic_fields_to_value(rest))
      case converted_rest {
        value.Object(rest) -> Ok(value.Object([#(key, converted), ..rest]))
        _ -> Error("Internal object conversion failed")
      }
    }
  }
}
