//// The User codec playground: one JSON Blueprint codec seen as an encoder,
//// a strict decoder and a JSON Schema.

pub type Face {
  Encode
  Decode
  Schema
}

pub const faces = [Encode, Decode, Schema]

pub fn face_label(face: Face) -> String {
  case face {
    Encode -> "Encode"
    Decode -> "Decode"
    Schema -> "Schema"
  }
}

/// Incoming JSON the reader can feed to the decoder.
pub type Incoming {
  Valid
  MissingName
  AgeTooHigh
  UnknownRole
  RepeatedKey
  TooLarge
}

pub const incoming = [
  Valid,
  MissingName,
  AgeTooHigh,
  UnknownRole,
  RepeatedKey,
  TooLarge,
]

pub type Outcome {
  Decoded
  Refused
}

/// What the decoder makes of one input.
pub type Case {
  Case(
    label: String,
    json: String,
    outcome: Outcome,
    result: String,
    why: String,
  )
}

pub fn case_of(input: Incoming) -> Case {
  case input {
    Valid ->
      Case(
        label: "Valid",
        json: "{ \"name\": \"Ada\",\n  \"age\": 36,\n  \"role\": \"admin\" }",
        outcome: Decoded,
        result: "Ok(User(\"Ada\", 36, None, Admin))",
        why: "Every required field is present and allowed. Email is absent, so it decodes to None.",
      )
    MissingName ->
      Case(
        label: "Missing name",
        json: "{ \"age\": 36,\n  \"role\": \"admin\" }",
        outcome: Refused,
        result: "Error at $.name\nmissing required field",
        why: "A required field is missing. The error carries the exact JSON path, so you can show it to a user or feed it back to a model.",
      )
    AgeTooHigh ->
      Case(
        label: "Age 200",
        json: "{ \"name\": \"Ada\",\n  \"age\": 200,\n  \"role\": \"admin\" }",
        outcome: Refused,
        result: "Error at $.age\nabove the maximum of 150",
        why: "The bound lives in the codec, so it is enforced on decode and published in the schema the model saw.",
      )
    UnknownRole ->
      Case(
        label: "Unknown role",
        json: "{ \"name\": \"Ada\",\n  \"age\": 36,\n  \"role\": \"owner\" }",
        outcome: Refused,
        result: "Error at $.role\nnot one of admin, member",
        why: "Enums decode only to the variants you listed. \"owner\" can never sneak into your program as a string.",
      )
    RepeatedKey ->
      Case(
        label: "Repeated key",
        json: "{ \"name\": \"Ada\",\n  \"name\": \"Eve\",\n  \"age\": 36,\n  \"role\": \"admin\" }",
        outcome: Refused,
        result: "Rejected\nrepeated key \"name\"",
        why: "When admitting untrusted text, repeated object keys are refused. Otherwise two systems could disagree about which \"name\" was meant.",
      )
    TooLarge ->
      Case(
        label: "5 MB of JSON",
        json: "{ \"name\": \"AAAAAAAA…\n  (5,242,880 bytes)",
        outcome: Refused,
        result: "Rejected\nover the byte limit",
        why: "Untrusted text is admitted with a configurable byte limit, checked before any parsing work happens.",
      )
  }
}
