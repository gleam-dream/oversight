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
    /// Built once; every question's run reuses it.
    agent: agent.Agent(Context),
    context: Context,
    /// How long one question may take.
    budget: Duration,
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

/// The assistant's agent, built once. Each run's correlation reaches the
/// model's HTTP requests through `model.Request`, and the inventory calls
/// through `tool.Call`.
pub fn build_agent(
  http: http_gun.Client,
  settings: llm_wire.Config,
  model_id: String,
  tools: List(fabric_tool.Tool(Context)),
) -> Result(agent.Agent(Context), List(agent.ConfigError)) {
  agent.new(
    "inventory_assistant",
    llm.model(http, settings, model_id),
    tools,
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
  use running <- result.try(
    fabric.start(
      assistant.store,
      assistant.agent,
      id: run.new_id(),
      context: assistant.context,
      prompt: question.question,
      correlation: Some(correlation),
    )
    |> result.map_error(fn(error) { StartFailed(string.inspect(error)) }),
  )
  let run_id = run.id_to_string(fabric.id(running))
  let cancelled = case assistant.cancel_with_caller {
    True -> cancelled
    False -> process.new_selector()
  }
  case fabric.await_with(running, within: assistant.budget, or: cancelled) {
    Ok(fabric.Interrupted(Nil)) -> {
      let _ = fabric.cancel(running)
      Error(Cancelled)
    }
    Ok(fabric.Reached(run.Finished(run.Completed(text)))) ->
      Ok(Answer(text, run_id))
    Ok(fabric.Reached(run.Finished(run.Refused(reason)))) ->
      Error(ModelRefused(reason))
    Ok(fabric.Reached(run.Finished(run.Cancelled))) -> Error(Cancelled)
    Ok(fabric.Reached(run.Finished(other))) ->
      Error(Failed(string.inspect(other)))
    Ok(fabric.Reached(run.Suspended(_approvals, [_, ..] as uncertain))) ->
      Error(Uncertain(run_id, uncertain))
    Ok(fabric.Reached(run.Suspended(approvals, []))) ->
      Error(Failed(
        int.to_string(list.length(approvals)) <> " approvals pending",
      ))
    Ok(fabric.Reached(run.Working)) | Ok(fabric.Reached(run.Unattended)) -> {
      let _ = fabric.cancel(running)
      Error(TimedOut(run_id))
    }
    Error(error) -> Error(Failed(string.inspect(error)))
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
