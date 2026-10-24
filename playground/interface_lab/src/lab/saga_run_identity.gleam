// THROWAWAY: Can run and command identity live below Saga checkpointing?

pub opaque type RunId {
  RunId(String)
}

pub fn run_id(value: String) -> RunId {
  RunId(value)
}

pub fn run_id_value(id: RunId) -> String {
  let RunId(value) = id
  value
}

pub opaque type CommandId {
  CommandId(String)
}

pub fn command_id(value: String) -> CommandId {
  CommandId(value)
}

pub fn command_id_value(id: CommandId) -> String {
  let CommandId(value) = id
  value
}
