import fabric
import fabric/agent
import fabric/input
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/io
import gleam/option.{None}
import gleam/time/duration

pub fn main() {
  let runs = store.directory(process.new_name("new_writer"), "../records")
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(definition) =
    agent.new(
      "compat",
      model.new(fn(_) { Ok(model.FinalAnswer("generated", None)) }),
      [],
      policy.always_allow(),
    )
    |> agent.build
  let assert Ok(original) =
    input.new(
      [
        model.UserMessage("earlier"),
        model.AssistantMessage(model.AssistantTurn("old answer", [], None)),
      ],
      "current",
    )
  let assert Ok(handle) =
    fabric.start_with_input(
      runs,
      definition,
      id: run.id_from_parts("compat", ["history"]),
      context: Nil,
      input: original,
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed("generated"))) =
    fabric.await(handle, duration.seconds(3))
  let assert Ok(_) = store.stop(runs)
  io.println("PASS new v8 record written through public facade")
}
