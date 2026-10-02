//// The fabric agent and its exposure as the MCP tool `ask_assistant`.

import fabric
import fabric/agent
import fabric/llm
import fabric/policy
import fabric/run
import fabric/store.{type Store}
import fabric/tool as fabric_tool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import json/blueprint/codec.{type Codec}
import llm_wire/config
import llm_wire/types
import relay/client
import relay/server
import relay/tool as relay_tool
import relay/transport/http
import sinal/correlation.{type Correlation}

/// What every tool call of a run receives.
pub type Context {
  Context(inventory: client.Client)
}

pub type Assistant {
  Assistant(
    store: Store,
    /// The application's HTTP client for the model provider.
    http: http_gun.Client,
    settings: config.Config,
    model_id: types.ModelId,
    tools: List(fabric_tool.Tool(Context)),
    context: Context,
    /// How long one question may take, in milliseconds.
    budget_ms: Int,
    /// Called once a run exists, with the HTTP correlation id its model
    /// calls carry, so telemetry can join the two.
    on_run: fn(run.RunId, Correlation) -> Nil,
    /// Cancel the run when the asking process dies (see `ask`).
    cancel_with_caller: Bool,
  )
}

pub type Question {
  Question(question: String)
}

pub type Answer {
  Answer(answer: String, run_id: String)
}

pub type AskError {
  StartFailed(reason: String)
  /// The run stopped on effects of unknown status; a person must reconcile.
  Uncertain(effects: List(run.UncertainAction))
  ModelRefused(reason: String)
  Cancelled
  Failed(reason: String)
  TimedOut(run_id: String)
}

pub fn question_codec() -> Codec(Question) {
  use question <- codec.field(
    "question",
    codec.string() |> codec.describe("A question about products or stock"),
    get: fn(q) { q.question },
  )
  codec.success(Question(question:))
}

pub fn answer_codec() -> Codec(Answer) {
  use answer <- codec.field("answer", codec.string(), get: fn(a) { a.answer })
  use run_id <- codec.field("run_id", codec.string(), get: fn(a) { a.run_id })
  codec.success(Answer(answer:, run_id:))
}

pub fn ask_assistant() -> relay_tool.Definition(Question, Answer) {
  let assert Ok(name) = relay_tool.tool_name("ask_assistant")
  let assert Ok(definition) =
    relay_tool.definition(name, question_codec(), answer_codec())
  definition
  |> relay_tool.with_description(
    "Ask the inventory assistant; it searches, checks stock and reserves.",
  )
}

/// The agent for one question. It is rebuilt per question only so that its
/// model calls carry a per-question HTTP correlation id.
pub fn agent_for(
  assistant: Assistant,
  correlation: Correlation,
) -> Result(agent.Agent(Context), List(agent.ConfigError)) {
  let model =
    llm.model(
      http_gun.with_correlation(assistant.http, correlation),
      assistant.settings,
      assistant.model_id,
    )
  agent.new(
    "inventory_assistant",
    model,
    assistant.tools,
    policy.always_allow(),
  )
  |> agent.with_system_prompt(
    "Answer questions about the product catalog using the inventory tools.",
  )
  |> agent.build
}

/// Asks one question and waits for the answer. If the calling process dies
/// (Relay kills a cancelled invocation's worker), the run is cancelled.
pub fn ask(
  assistant: Assistant,
  question: Question,
) -> Result(Answer, AskError) {
  let correlation = correlation.unique()
  use desk <- result.try(
    agent_for(assistant, correlation)
    |> result.map_error(fn(errors) { StartFailed(string.inspect(errors)) }),
  )
  use running <- result.try(
    fabric.start(assistant.store, desk, assistant.context, question.question)
    |> result.map_error(fn(error) { StartFailed(string.inspect(error)) }),
  )
  let id = fabric.id(running)
  assistant.on_run(id, correlation)
  let watcher = case assistant.cancel_with_caller {
    True -> Some(cancel_when_caller_dies(running))
    False -> None
  }
  let status = fabric.await(running, assistant.budget_ms)
  option.map(watcher, process.kill)
  case status {
    Ok(run.Finished(run.Completed(text))) ->
      Ok(Answer(text, run.id_to_string(id)))
    Ok(run.Finished(run.Refused(reason))) -> Error(ModelRefused(reason))
    Ok(run.Finished(run.Cancelled)) -> Error(Cancelled)
    Ok(run.Finished(other)) -> Error(Failed(string.inspect(other)))
    Ok(run.Suspended(_approvals, [_, ..] as uncertain)) ->
      Error(Uncertain(uncertain))
    Ok(run.Suspended(approvals, [])) ->
      Error(Failed(
        int.to_string(list.length(approvals)) <> " approvals pending",
      ))
    Ok(run.Working) | Ok(run.Unattended) -> {
      let _ = fabric.cancel(running)
      Error(TimedOut(run.id_to_string(id)))
    }
    Error(error) -> Error(Failed(string.inspect(error)))
  }
}

/// Glue: Relay stops a cancelled invocation by killing its worker process,
/// but a fabric run lives in its own runner. A monitor bridges the two.
fn cancel_when_caller_dies(running: fabric.Run(Context)) -> process.Pid {
  let caller = process.self()
  process.spawn_unlinked(fn() {
    let monitor = process.monitor(caller)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
    let _down = process.selector_receive_forever(selector)
    fabric.cancel(running)
  })
}

/// What the MCP client sees for each failure (`isError: true` text). MCP has
/// no "outcome unknown"; the text is the only place to say so.
pub fn render(error: AskError) -> String {
  case error {
    StartFailed(reason) -> "the assistant could not start: " <> reason
    Uncertain(effects) ->
      "outcome unknown: "
      <> string.join(
        list.map(effects, fn(effect) {
          effect.tool <> " (" <> effect.evidence <> ")"
        }),
        "; ",
      )
      <> "; a person must reconcile run "
      <> case effects {
        [first, ..] -> run.id_to_string(first.reference.run)
        [] -> "?"
      }
    ModelRefused(reason) -> "the model refused: " <> reason
    Cancelled -> "the question was cancelled"
    Failed(reason) -> "the assistant failed: " <> reason
    TimedOut(run_id) -> "no answer in time (run " <> run_id <> " cancelled)"
  }
}

/// The second MCP server, which exposes the agent as one tool.
pub fn serve(
  assistant: Assistant,
  policy: http.HttpPolicy,
) -> Result(http.HttpServer(Nil), String) {
  let bound =
    relay_tool.handle_with_error_renderer(
      ask_assistant(),
      fn(question) { ask(assistant, question) },
      render,
    )
  use registry <- result.try(
    relay_tool.registry([bound]) |> result.replace_error("registry"),
  )
  server.server(registry)
  |> http.listener(fn() { Nil })
  |> http.with_policy(policy)
  |> http.start
}
