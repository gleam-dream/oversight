import gleam/dynamic/decode
import gleam/json

pub type SubjectId {
  SubjectId(String)
}

pub type OperationId {
  OperationId(String)
}

pub type Target {
  Profile
  Archive
  DropReply
  Reject
}

pub type Command {
  Command(subject: SubjectId, operation: OperationId, target: Target)
}

pub type Receipt {
  Receipt(reference: String)
}

pub type Policy {
  StopOnRejection
  ContinueOnRejection
}

pub type PreparationError {
  PlanRejected
}

pub fn target_text(target: Target) -> String {
  case target {
    Profile -> "profile"
    Archive -> "archive"
    DropReply -> "drop"
    Reject -> "reject"
  }
}

pub fn identity(command: Command) -> String {
  let SubjectId(subject) = command.subject
  let OperationId(operation) = command.operation
  subject <> "/" <> operation <> "/" <> target_text(command.target)
}

pub fn encode(command: Command) -> json.Json {
  let SubjectId(subject) = command.subject
  let OperationId(operation) = command.operation
  json.object([
    #("subject", json.string(subject)),
    #("operation", json.string(operation)),
    #("target", json.string(target_text(command.target))),
  ])
}

pub fn decoder() -> decode.Decoder(Command) {
  use subject <- decode.field("subject", decode.string)
  use operation <- decode.field("operation", decode.string)
  use target <- decode.field("target", decode.string)
  case target {
    "profile" ->
      decode.success(Command(
        SubjectId(subject),
        OperationId(operation),
        Profile,
      ))
    "archive" ->
      decode.success(Command(
        SubjectId(subject),
        OperationId(operation),
        Archive,
      ))
    "drop" ->
      decode.success(Command(
        SubjectId(subject),
        OperationId(operation),
        DropReply,
      ))
    "reject" ->
      decode.success(Command(SubjectId(subject), OperationId(operation), Reject))
    _ ->
      decode.failure(
        Command(SubjectId(subject), OperationId(operation), Profile),
        "known target",
      )
  }
}

pub fn receipt_decoder() -> decode.Decoder(Receipt) {
  use reference <- decode.then(decode.string)
  decode.success(Receipt(reference))
}
