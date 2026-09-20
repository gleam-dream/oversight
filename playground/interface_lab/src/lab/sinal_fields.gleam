// THROWAWAY: Map-shaped intermediate data, not native Erlang telemetry maps.
// Keys are logical labels. The future bridge must use existing/static atoms.
import lab/blueprint
import lab/value.{type Value}

pub type FieldMap {
  FieldMap(List(#(String, Value)))
}

pub type FieldError {
  MissingField(String)
  DuplicateField(String)
  InvalidField(String, blueprint.DecodeError)
}

pub opaque type Fields(a) {
  Fields(
    names: List(String),
    encode: fn(a) -> Result(FieldMap, blueprint.EncodeError),
    decode: fn(FieldMap) -> Result(a, FieldError),
  )
}

pub fn field(name: String, codec: blueprint.Codec(a)) -> Fields(a) {
  Fields(
    [name],
    fn(item) {
      case blueprint.encode(codec, item) {
        Ok(raw) -> Ok(FieldMap([#(name, raw)]))
        Error(error) -> Error(blueprint.EncodeAtField(name, error))
      }
    },
    fn(fields) {
      case lookup(fields, name) {
        Error(error) -> Error(error)
        Ok(raw) ->
          case blueprint.decode(codec, raw) {
            Ok(item) -> Ok(item)
            Error(error) -> Error(InvalidField(name, error))
          }
      }
    },
  )
}

pub fn pair(
  left: Fields(a),
  right: Fields(b),
) -> Result(Fields(#(a, b)), FieldError) {
  case check_names(left.names, right.names) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      Ok(
        Fields(
          append(left.names, right.names),
          fn(items: #(a, b)) {
            case left.encode(items.0), right.encode(items.1) {
              Ok(FieldMap(a)), Ok(FieldMap(b)) -> Ok(FieldMap(append(a, b)))
              Error(error), _ -> Error(error)
              _, Error(error) -> Error(error)
            }
          },
          fn(raw) {
            case left.decode(raw), right.decode(raw) {
              Ok(a), Ok(b) -> Ok(#(a, b))
              Error(error), _ -> Error(error)
              _, Error(error) -> Error(error)
            }
          },
        ),
      )
  }
}

pub fn encode(
  fields: Fields(a),
  item: a,
) -> Result(FieldMap, blueprint.EncodeError) {
  fields.encode(item)
}

pub fn decode(fields: Fields(a), raw: FieldMap) -> Result(a, FieldError) {
  fields.decode(raw)
}

fn lookup(raw: FieldMap, name: String) -> Result(Value, FieldError) {
  let FieldMap(entries) = raw
  case matches(entries, name) {
    [] -> Error(MissingField(name))
    [value] -> Ok(value)
    _ -> Error(DuplicateField(name))
  }
}

fn matches(entries: List(#(String, Value)), name: String) -> List(Value) {
  case entries {
    [] -> []
    [#(key, value), ..rest] ->
      case key == name {
        True -> [value, ..matches(rest, name)]
        False -> matches(rest, name)
      }
  }
}

fn check_names(
  left: List(String),
  right: List(String),
) -> Result(Nil, FieldError) {
  case left {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case contains(right, name) {
        True -> Error(DuplicateField(name))
        False -> check_names(rest, right)
      }
  }
}

fn contains(items: List(a), item: a) -> Bool {
  case items {
    [] -> False
    [head, ..rest] -> head == item || contains(rest, item)
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [item, ..rest] -> [item, ..append(rest, right)]
  }
}
