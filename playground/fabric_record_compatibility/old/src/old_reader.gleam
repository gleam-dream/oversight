import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/io

pub fn main() {
  let runs = store.directory(process.new_name("old_reader"), "../records")
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(definition) =
    agent.new(
      "compat",
      model.new(fn(_) { panic as "old reader must never execute" }),
      [],
      policy.always_allow(),
    )
    |> agent.build
  let assert Error(fabric.UnsupportedVersion(8)) =
    fabric.open(runs, definition, Nil, run.id_from_parts("compat", ["history"]))
  let assert Ok(_) = store.stop(runs)
  io.println("PASS c92e97c public reader rejects v8 without execution")
}
