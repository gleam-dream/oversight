// THROWAWAY: Can the same typed function serve heterogeneous tool registries?
import lab/blueprint
import lab/fabric
import lab/grind
import lab/relay
import lab/value

pub type LookupError {
  Missing
}

pub fn lookup(id: Int) -> Result(String, LookupError) {
  case id {
    42 -> Ok("Ada")
    _ -> Error(Missing)
  }
}

pub fn error_codec() -> blueprint.Codec(LookupError) {
  blueprint.new(
    fn(error: LookupError) {
      case error {
        Missing -> Ok(value.Text("missing"))
      }
    },
    fn(v) {
      case v {
        value.Text("missing") -> Ok(Missing)
        _ -> Error(blueprint.CannotDecode("Expected lookup error"))
      }
    },
  )
}

pub fn relay_tools() -> List(relay.Tool) {
  [
    relay.tool(
      "lookup",
      blueprint.int(),
      blueprint.text(),
      error_codec(),
      lookup,
    ),
    relay.tool("echo", blueprint.text(), blueprint.text(), error_codec(), fn(s) {
      Ok(s)
    }),
  ]
}

pub fn agent_tools() -> List(fabric.Tool) {
  [
    fabric.tool(
      "lookup",
      blueprint.int(),
      blueprint.text(),
      error_codec(),
      lookup,
    ),
    fabric.tool(
      "echo",
      blueprint.text(),
      blueprint.text(),
      error_codec(),
      fn(s) { Ok(s) },
    ),
  ]
}

pub fn lookup_worker() -> Result(
  grind.Worker(Int, String, LookupError),
  grind.WorkerIdentityError,
) {
  case grind.worker_id("lookup"), grind.worker_version(1) {
    Ok(id), Ok(version) ->
      Ok(grind.worker(
        id,
        version,
        blueprint.int(),
        blueprint.text(),
        error_codec(),
        lookup,
      ))
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}
