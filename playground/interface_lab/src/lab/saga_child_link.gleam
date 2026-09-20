// THROWAWAY: Can child routing and compatibility travel without native types?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/saga_run_identity.{type RunId, run_id, run_id_value}
import lab/value.{type Value}

pub type LinkError {
  LinkIdentityMustNotBeEmpty
  LinkVersionMustBePositive
}

// The link is persisted routing evidence, not an authorization credential.
// It deliberately contains no native output, error, or undo-error type.
pub opaque type ChildLink {
  ChildLink(
    owner_id: String,
    run_id: RunId,
    definition_id: String,
    definition_version: Int,
    signature: String,
    input_version: Int,
    output_version: Int,
    error_version: Int,
    undo_error_version: Int,
  )
}

pub fn new(
  owner_id: String,
  run_id: RunId,
  definition_id: String,
  definition_version: Int,
  signature: String,
  input_version: Int,
  output_version: Int,
  error_version: Int,
  undo_error_version: Int,
) -> Result(ChildLink, LinkError) {
  case owner_id, definition_id, signature {
    "", _, _ -> Error(LinkIdentityMustNotBeEmpty)
    _, "", _ -> Error(LinkIdentityMustNotBeEmpty)
    _, _, "" -> Error(LinkIdentityMustNotBeEmpty)
    _, _, _ ->
      case run_id_value(run_id) {
        "" -> Error(LinkIdentityMustNotBeEmpty)
        _ ->
          case
            versions_are_positive([
              definition_version,
              input_version,
              output_version,
              error_version,
              undo_error_version,
            ])
          {
            True ->
              Ok(ChildLink(
                owner_id,
                run_id,
                definition_id,
                definition_version,
                signature,
                input_version,
                output_version,
                error_version,
                undo_error_version,
              ))
            False -> Error(LinkVersionMustBePositive)
          }
      }
  }
}

pub fn owner(link: ChildLink) -> String {
  let ChildLink(owner_id, _, _, _, _, _, _, _, _) = link
  owner_id
}

pub fn run(link: ChildLink) -> RunId {
  let ChildLink(_, run_id, _, _, _, _, _, _, _) = link
  run_id
}

pub fn definition(link: ChildLink) -> String {
  let ChildLink(_, _, definition_id, _, _, _, _, _, _) = link
  definition_id
}

pub fn definition_version(link: ChildLink) -> Int {
  let ChildLink(_, _, _, version, _, _, _, _, _) = link
  version
}

pub fn signature(link: ChildLink) -> String {
  let ChildLink(_, _, _, _, value, _, _, _, _) = link
  value
}

pub fn input_version(link: ChildLink) -> Int {
  let ChildLink(_, _, _, _, _, version, _, _, _) = link
  version
}

pub fn output_version(link: ChildLink) -> Int {
  let ChildLink(_, _, _, _, _, _, version, _, _) = link
  version
}

pub fn error_version(link: ChildLink) -> Int {
  let ChildLink(_, _, _, _, _, _, _, version, _) = link
  version
}

pub fn undo_error_version(link: ChildLink) -> Int {
  let ChildLink(_, _, _, _, _, _, _, _, version) = link
  version
}

pub fn codec() -> Codec(ChildLink) {
  blueprint.new(encode, decode)
}

fn encode(link: ChildLink) -> Result(Value, EncodeError) {
  Ok(
    value.Object([
      #("owner_id", value.Text(owner(link))),
      #("run_id", value.Text(run_id_value(run(link)))),
      #("definition_id", value.Text(definition(link))),
      #("definition_version", value.Int(definition_version(link))),
      #("signature", value.Text(signature(link))),
      #("input_version", value.Int(input_version(link))),
      #("output_version", value.Int(output_version(link))),
      #("error_version", value.Int(error_version(link))),
      #("undo_error_version", value.Int(undo_error_version(link))),
    ]),
  )
}

fn decode(raw: Value) -> Result(ChildLink, DecodeError) {
  case raw {
    value.Object(fields) ->
      case validate_fields(fields) {
        Error(error) -> Error(error)
        Ok(Nil) -> decode_fields(fields)
      }
    _ -> Error(blueprint.CannotDecode("Expected child link object"))
  }
}

fn decode_fields(
  fields: List(#(String, Value)),
) -> Result(ChildLink, DecodeError) {
  use owner_id <- bind(decode_text(fields, "owner_id"))
  use run_id_text <- bind(decode_text(fields, "run_id"))
  use definition_id <- bind(decode_text(fields, "definition_id"))
  use definition_version <- bind(decode_int(fields, "definition_version"))
  use signature <- bind(decode_text(fields, "signature"))
  use input_version <- bind(decode_int(fields, "input_version"))
  use output_version <- bind(decode_int(fields, "output_version"))
  use error_version <- bind(decode_int(fields, "error_version"))
  use undo_error_version <- bind(decode_int(fields, "undo_error_version"))
  use run_id <- bind(validate_run_id(run_id_text))
  case
    new(
      owner_id,
      run_id,
      definition_id,
      definition_version,
      signature,
      input_version,
      output_version,
      error_version,
      undo_error_version,
    )
  {
    Ok(link) -> Ok(link)
    Error(LinkIdentityMustNotBeEmpty) ->
      Error(blueprint.CannotDecode("Child link identifiers must not be empty"))
    Error(LinkVersionMustBePositive) ->
      Error(blueprint.CannotDecode("Child link versions must be positive"))
  }
}

// The envelope has a closed key set: duplicate routing fields and silent
// extensions are rejected rather than assigning meaning to the first copy.
fn validate_fields(fields: List(#(String, Value))) -> Result(Nil, DecodeError) {
  case fields {
    [] -> Ok(Nil)
    [#(key, _), ..rest] ->
      case known_key(key) && count_key(fields, key) == 1 {
        True -> validate_fields(rest)
        False ->
          Error(blueprint.DecodeAtField(
            key,
            blueprint.CannotDecode("Unknown or duplicate child link field"),
          ))
      }
  }
}

fn known_key(key: String) -> Bool {
  key == "owner_id"
  || key == "run_id"
  || key == "definition_id"
  || key == "definition_version"
  || key == "signature"
  || key == "input_version"
  || key == "output_version"
  || key == "error_version"
  || key == "undo_error_version"
}

fn count_key(fields: List(#(String, Value)), target: String) -> Int {
  case fields {
    [] -> 0
    [#(key, _), ..rest] ->
      case key == target {
        True -> 1 + count_key(rest, target)
        False -> count_key(rest, target)
      }
  }
}

fn decode_text(
  fields: List(#(String, Value)),
  name: String,
) -> Result(String, DecodeError) {
  case field(fields, name) {
    Ok(value.Text(text)) -> Ok(text)
    Ok(_) ->
      Error(blueprint.DecodeAtField(
        name,
        blueprint.CannotDecode("Expected text"),
      ))
    Error(Nil) ->
      Error(blueprint.DecodeAtField(
        name,
        blueprint.CannotDecode("Missing field"),
      ))
  }
}

fn decode_int(
  fields: List(#(String, Value)),
  name: String,
) -> Result(Int, DecodeError) {
  case field(fields, name) {
    Ok(value.Int(integer)) -> Ok(integer)
    Ok(_) ->
      Error(blueprint.DecodeAtField(
        name,
        blueprint.CannotDecode("Expected integer"),
      ))
    Error(Nil) ->
      Error(blueprint.DecodeAtField(
        name,
        blueprint.CannotDecode("Missing field"),
      ))
  }
}

fn field(fields: List(#(String, Value)), name: String) -> Result(Value, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(key, value), ..rest] ->
      case key == name {
        True -> Ok(value)
        False -> field(rest, name)
      }
  }
}

fn validate_run_id(text: String) -> Result(RunId, DecodeError) {
  case text {
    "" ->
      Error(blueprint.DecodeAtField(
        "run_id",
        blueprint.CannotDecode("Must not be empty"),
      ))
    _ -> Ok(run_id(text))
  }
}

fn versions_are_positive(versions: List(Int)) -> Bool {
  case versions {
    [] -> True
    [version, ..rest] -> version > 0 && versions_are_positive(rest)
  }
}

fn bind(
  result: Result(a, DecodeError),
  next: fn(a) -> Result(b, DecodeError),
) -> Result(b, DecodeError) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
