//// The fabric agent and its exposure as the MCP tool `ask_assistant`.

import fabric
import fabric/agent
import fabric/approvers.{type Approvers}
import fabric/invoke
import fabric/llm
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store.{type Store}
import fabric/tool as fabric_tool
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/duration.{type Duration}
import http_gun
import json/blueprint/codec.{type Codec}
import llm_wire
import relay/client
import relay/http
import relay/server
import relay/tool as relay_tool
import relay_serve

/// What every tool call of a run receives.
pub type Context {
  Context(inventory: client.Client)
}

pub type Assistant {
  Assistant(
    store: Store,
    /// Who may answer the agent's approval requests: the agent and the
    /// operator's `approve`/`reject` share this value.
    approvers: Approvers(String),
    /// Built once; every question's run reuses it.
    agent: agent.Agent(Context, Answer),
    context: Context,
    /// How long one call waits for the answer.
    budget: Duration,
  )
}

/// The requirement a reservation waits for.
pub const reserver = run.Requirement("stock-reserver", 1)

/// Why an operator's answer was not recorded.
pub type AnswerError {
  /// The credential is not the operator's, or may not answer this
  /// requirement. Nothing reached fabric.
  Denied(approvers.Denial)
  /// The operator is verified, and fabric refused the answer.
  Refused(fabric.Error)
}

pub fn describe_answer_error(error: AnswerError) -> String {
  case error {
    Denied(approvers.NotAuthenticated(reason)) ->
      "not authenticated: " <> reason
    Denied(approvers.NotAuthorized(reason)) -> "not authorized: " <> reason
    Denied(approvers.Unavailable(reason)) -> "verifier unavailable: " <> reason
    Refused(error) -> fabric.describe_error(error)
  }
}

/// The names of the tools a policy may run without an approval: those
/// whose declaration says they are read-only. The application starts the
/// inventory peer, so its declarations are trusted; a tool from an
/// arbitrary peer would need the application's own classification.
pub fn read_only(declarations: List(relay_tool.Declaration)) -> List(String) {
  list.filter_map(declarations, fn(declaration) {
    case declaration.annotations.read_only_hint {
      Some(True) -> Ok(declaration.name)
      _ -> Error(Nil)
    }
  })
}

/// Read-only tools run; every other action, a reservation or a tool this
/// list does not name, waits for an operator's approval.
pub fn policy(read_only: List(String)) -> policy.Policy(Context) {
  fn(_, action: policy.Action) {
    case action.target, list.contains(read_only, action.name) {
      policy.InvokeTool, True -> Ok(policy.Allow)
      _, _ -> Ok(policy.RequireApproval(reserver))
    }
  }
}

/// The operator's approvers. The credential is generated at boot and held
/// in the process that starts the hub; no MCP route carries it, so a
/// caller of `ask_assistant` cannot answer its own run's approval. A
/// deployment would verify an access token's scope here instead, as
/// `apps/support_desk/src/support_desk/approvers.gleam` does.
pub fn operator_approvers(credential: String) -> Approvers(String) {
  approvers.new("tool_hub_operator", fn(presented, requirement) {
    case secure_equal(presented, credential), requirement == reserver {
      False, _ ->
        Error(approvers.NotAuthenticated("not the operator credential"))
      True, False ->
        Error(approvers.NotAuthorized("the operator answers reservations only"))
      True, True ->
        reviewer.new("operator")
        |> result.map_error(fn(error) {
          approvers.NotAuthenticated(reviewer.describe_error(error))
        })
    }
  })
}

/// A fresh random operator credential.
@external(erlang, "tool_hub_ffi", "random_token")
pub fn random_credential() -> String

@external(erlang, "tool_hub_ffi", "secure_equal")
fn secure_equal(left: String, right: String) -> Bool

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
    "Ask the inventory assistant; it searches and checks stock, and a reservation waits for the operator.",
  )
}

/// The assistant's agent, built once. Each run's correlation reaches the
/// model's HTTP requests through `model.Request`, and the inventory calls
/// through `tool.Call`. The model answers with `answer_codec`'s JSON.
/// `ask_assistant` carries untrusted text to the model, so only the tools
/// named in `read_only` run unattended; the rest wait for `approvers`.
pub fn build_agent(
  http: http_gun.Client,
  settings: llm_wire.Config,
  model_id: String,
  tools: List(fabric_tool.Tool(Context)),
  read_only read_only: List(String),
  approvers approvers: Approvers(String),
) -> Result(agent.Agent(Context, Answer), List(agent.ConfigError)) {
  agent.new(
    "inventory_assistant",
    llm.model(http, settings, model_id),
    tools,
    policy(read_only),
  )
  |> agent.with_approvers(approvers)
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
    invoke.agent("ask_assistant", assistant.store, assistant.agent)
    |> invoke.with_wait(assistant.budget)
  use tool <- result.try(
    relay_serve.serve(ask_assistant(), service, fn(_, question) {
      Ok(invoke.request(assistant.context, question.question))
    })
    |> result.map_error(invoke.describe_config_error),
  )
  server.new([tool])
  |> http.new
  |> http.with_label("assistant")
  |> configure
  |> http.start
  |> result.map_error(http.describe_start_error)
}
