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
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import json/blueprint/codec.{type Codec}
import json/blueprint/value
import llm_wire
import relay/client
import relay/content
import relay/http
import relay/server
import relay/tool as relay_tool
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
    settings: llm_wire.Config,
    model_id: String,
    tools: List(fabric_tool.Tool(Context)),
    context: Context,
    /// How long one question may take.
    budget: Duration,
    /// Called once a run exists, with the correlation its model, inventory
    /// and Relay events carry, so telemetry can join fabric's run id to it.
    on_run: fn(run.RunId, Correlation) -> Nil,
    /// Cancel the run when Relay cancels the `ask_assistant` call.
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
  Uncertain(run_id: String, effects: List(run.UncertainAction))
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
  relay_tool.define("ask_assistant", question_codec(), answer_codec())
  |> relay_tool.with_description(
    "Ask the inventory assistant; it searches, checks stock and reserves.",
  )
}

/// The agent for one question. It is rebuilt per question only so that its
/// model calls carry the question's correlation: `llm.model` binds its HTTP
/// client when the agent is built, before the run id exists.
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

/// Asks one question under `correlation` and waits for the answer. When
/// `cancelled` fires (Relay's `tool.cancelled` for this call), the run is
/// cancelled before the handler returns, inside Relay's cancellation grace.
pub fn ask(
  assistant: Assistant,
  question: Question,
  correlation: Correlation,
  cancelled: process.Selector(Nil),
) -> Result(Answer, AskError) {
  use desk <- result.try(
    agent_for(assistant, correlation)
    |> result.map_error(fn(errors) { StartFailed(string.inspect(errors)) }),
  )
  // The inventory calls of this question carry its correlation too.
  let context =
    Context(client.with_correlation(assistant.context.inventory, correlation))
  use running <- result.try(
    fabric.start(assistant.store, desk, context, question.question)
    |> result.map_error(fn(error) { StartFailed(string.inspect(error)) }),
  )
  let id = fabric.id(running)
  let run_id = run.id_to_string(id)
  assistant.on_run(id, correlation)
  let cancelled = case assistant.cancel_with_caller {
    True -> cancelled
    False -> process.new_selector()
  }
  case await_or_cancel(running, assistant.budget, cancelled) {
    Error(Nil) -> Error(Cancelled)
    Ok(Ok(run.Finished(run.Completed(text)))) -> Ok(Answer(text, run_id))
    Ok(Ok(run.Finished(run.Refused(reason)))) -> Error(ModelRefused(reason))
    Ok(Ok(run.Finished(run.Cancelled))) -> Error(Cancelled)
    Ok(Ok(run.Finished(other))) -> Error(Failed(string.inspect(other)))
    Ok(Ok(run.Suspended(_approvals, [_, ..] as uncertain))) ->
      Error(Uncertain(run_id, uncertain))
    Ok(Ok(run.Suspended(approvals, []))) ->
      Error(Failed(
        int.to_string(list.length(approvals)) <> " approvals pending",
      ))
    Ok(Ok(run.Working)) | Ok(Ok(run.Unattended)) -> {
      let _ = fabric.cancel(running)
      Error(TimedOut(run_id))
    }
    Ok(Error(error)) -> Error(Failed(string.inspect(error)))
  }
}

/// `fabric.await` blocks and offers no selector, so a waiter process
/// awaits the run and this handler selects on its answer and on `cancelled`.
/// A cancellation cancels the run, which is the point of the signal.
fn await_or_cancel(
  running: fabric.Run(Context),
  budget: Duration,
  cancelled: process.Selector(Nil),
) -> Result(Result(run.Status, fabric.RecordError), Nil) {
  let answer = process.new_subject()
  // Unlinked: killing a linked waiter would kill this handler too.
  let waiter =
    process.spawn_unlinked(fn() {
      process.send(
        answer,
        fabric.await(running, duration.to_milliseconds(budget)),
      )
    })
  let outcome =
    process.new_selector()
    |> process.select_map(answer, Ok)
    |> process.merge_selector(
      process.map_selector(cancelled, fn(_) { Error(Nil) }),
    )
    |> process.selector_receive_forever
  process.kill(waiter)
  case outcome {
    Ok(status) -> Ok(status)
    Error(Nil) -> {
      let _ = fabric.cancel(running)
      Error(Nil)
    }
  }
}

/// The text an MCP client sees for each failure.
pub fn render(error: AskError) -> String {
  case error {
    StartFailed(reason) -> "the assistant could not start: " <> reason
    Uncertain(run_id, effects) ->
      "outcome unknown: "
      <> string.join(
        list.map(effects, fn(effect) {
          effect.tool <> " (" <> effect.evidence <> ")"
        }),
        "; ",
      )
      <> "; a person must reconcile run "
      <> run_id
    ModelRefused(reason) -> "the model refused: " <> reason
    Cancelled -> "the question was cancelled"
    Failed(reason) -> "the assistant failed: " <> reason
    TimedOut(run_id) -> "no answer in time (run " <> run_id <> " cancelled)"
  }
}

/// The `isError` result for a failure: the text, and the same facts as data,
/// so a client finds the run to reconcile without parsing the text.
pub fn tool_error(error: AskError) -> relay_tool.ToolError {
  let field = fn(name, text) { #(name, value.String(text)) }
  let facts = case error {
    StartFailed(_) -> [field("error", "start_failed")]
    Uncertain(run_id, effects) -> [
      field("error", "outcome_unknown"),
      field("run_id", run_id),
      #(
        "uncertain",
        value.Array(
          list.map(effects, fn(effect) {
            value.Object([
              field("tool", effect.tool),
              field("evidence", effect.evidence),
            ])
          }),
        ),
      ),
    ]
    ModelRefused(_) -> [field("error", "model_refused")]
    Cancelled -> [field("error", "cancelled")]
    Failed(_) -> [field("error", "failed")]
    TimedOut(run_id) -> [field("error", "timed_out"), field("run_id", run_id)]
  }
  relay_tool.error_with(
    [content.text(render(error))],
    Some(value.Object(facts)),
  )
}

/// The second MCP server, which exposes the agent as one tool. Each request
/// gets a fresh correlation, which Relay's events for it carry and the
/// question reuses for its model and inventory calls.
pub fn serve(
  assistant: Assistant,
  configure: fn(http.Config(Nil)) -> http.Config(Nil),
) -> Result(http.Handler(Nil), String) {
  let bound =
    relay_tool.handle_call(ask_assistant(), fn(call, question) {
      let correlation =
        option.lazy_unwrap(relay_tool.correlation(call), correlation.unique)
      ask(assistant, question, correlation, relay_tool.cancelled(call))
      |> result.map(relay_tool.complete)
      |> result.map_error(tool_error)
    })
  server.new([bound])
  |> http.new
  |> http.with_label("assistant")
  |> http.with_correlation(fn(_request) { Some(correlation.unique()) })
  |> configure
  |> http.start
  |> result.map_error(http.describe_start_error)
}
