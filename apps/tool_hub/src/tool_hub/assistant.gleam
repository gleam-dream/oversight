//// The fabric agent and its exposure as the MCP tool `ask_assistant`.

import fabric/agent
import fabric/llm
import fabric/policy
import fabric/store.{type Store}
import fabric/tool as fabric_tool
import fabric_relay
import gleam/result
import gleam/time/duration.{type Duration}
import http_gun
import json/blueprint/codec.{type Codec}
import llm_wire
import relay/client
import relay/http
import relay/server
import relay/tool as relay_tool

/// What every tool call of a run receives.
pub type Context {
  Context(inventory: client.Client)
}

pub type Assistant {
  Assistant(
    store: Store,
    /// Built once; every question's run reuses it.
    agent: agent.Agent(Context, Answer),
    context: Context,
    /// How long one call waits for the answer.
    budget: Duration,
  )
}

pub type Question {
  Question(question: String)
}

/// What the model answers (`agent.with_answer`) and the tool returns.
pub type Answer {
  Answer(answer: String)
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
  codec.success(Answer(answer:))
}

pub fn ask_assistant() -> relay_tool.Definition(Question, Answer) {
  relay_tool.define("ask_assistant", question_codec(), answer_codec())
  |> relay_tool.with_description(
    "Ask the inventory assistant; it searches, checks stock and reserves.",
  )
}

/// The assistant's agent, built once. Each run's correlation reaches the
/// model's HTTP requests through `model.Request`, and the inventory calls
/// through `tool.Call`. The model answers with `answer_codec`'s JSON.
pub fn build_agent(
  http: http_gun.Client,
  settings: llm_wire.Config,
  model_id: String,
  tools: List(fabric_tool.Tool(Context)),
) -> Result(agent.Agent(Context, Answer), List(agent.ConfigError)) {
  agent.new(
    "inventory_assistant",
    llm.model(http, settings, model_id),
    tools,
    policy.always_allow(),
  )
  |> agent.with_system_prompt(
    "Answer questions about the product catalog using the inventory tools.",
  )
  |> agent.with_answer(answer_codec())
  |> agent.build
}

/// The second MCP server, which exposes the agent as one tool. A call with an
/// idempotency key names its run and survives a disconnect; a call without
/// one owns its run and cancels it with the caller. The caller's correlation
/// (`client.with_correlation`) is the run's, or a fresh one.
pub fn serve(
  assistant: Assistant,
  configure: fn(http.Config(Nil)) -> http.Config(Nil),
) -> Result(http.Handler(Nil), String) {
  let service =
    fabric_relay.service(
      ask_assistant(),
      runs: assistant.store,
      agent: assistant.agent,
      start: fn(_, question) {
        fabric_relay.start(assistant.context, prompt: question.question)
      },
    )
    |> fabric_relay.with_wait(assistant.budget)
  use tool <- result.try(
    fabric_relay.serve(service)
    |> result.map_error(fabric_relay.describe_config_errors),
  )
  server.new([tool])
  |> http.new
  |> http.with_label("assistant")
  |> configure
  |> http.start
  |> result.map_error(http.describe_start_error)
}
