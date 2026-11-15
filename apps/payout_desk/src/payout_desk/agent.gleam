//// The support agent: three read tools, one gated tool, a scripted model
//// and a typed answer.
////
//// - **Reads.** Each read tool reaches the marketplace only through the
////   session's `Sources`, which capture what a read returned as evidence
////   before the model sees it. The tool's result is an envelope naming
////   that evidence, so the reads the model **received** are a fold over the
////   run's succeeded actions (`received`): a read whose tool failed after
////   reading never reaches the record.
//// - **The gated call.** Fabric's policy answers `propose_payout` with an
////   approval that only the `payout` decision point gives (`approvers`
////   in `payout_desk/app`). The run parks with no process. `recommender`
////   turns the parked call into a recommendation for `decisions`; the
////   call's run and action are its key.
//// - **Resuming.** When the decision settles, `jobs` answers the approval
////   with what really happened: the call is let through with the outcome
////   in the session (`settled`), and the tool returns that outcome, never
////   its own arguments; or it is rejected with the outcome as the reason.
////   The approval never expires (`run.Infinity`), so Fabric never answers
////   it on its own.

import decisions/model.{type Sources} as decisions_model
import decisions/vocabulary.{
  type Ref, Agent as AgentRecommender, Recommendation, RunAction,
}
import decisions/wire
import fabric
import fabric/agent.{type Agent}
import fabric/approvers.{type Approvers}
import fabric/model.{type Request} as fabric_model
import fabric/policy
import fabric/run.{type RunId}
import fabric/store.{type Store}
import fabric/tool
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}
import payout_desk/domain.{
  type Dispute, type History, type Payout, type Reply, type Truth, Payout, Reply,
}

/// The live context of a run. Fabric never stores it: `start`, `open`,
/// `recover` and `approve` take it again.
pub type Session {
  Session(
    request: String,
    seller: String,
    /// How the read tools reach the marketplace: capturing in production.
    sources: Sources,
    /// What really happened to the payout, once it is known. Only the
    /// approval that resumes the run carries it.
    settled: Option(Truth),
  )
}

/// The recommender's identity on the record. A new script or prompt is a
/// new version, so agreement is counted per version.
pub const recommender_id = AgentRecommender(kind: "payout_support", version: "1")

/// The requirement the gated call waits for.
pub const requirement = run.Requirement("payout", 1)

pub const propose = "propose_payout"

/// How the scripted model behaves once its proposal has an answer.
pub type Script {
  /// It reads the answer and tells the seller what it says.
  Careful
  /// It tells the seller the payout is done whatever the answer says:
  /// the model the trap in the recipe's notes needs.
  Naive
}

// -- Tools -------------------------------------------------------------------------

/// What a read tool returns to the model: the content, and the evidence
/// each read behind it was captured as.
pub type Envelope {
  Envelope(evidence: List(String), content: String)
}

fn envelope_codec() -> Codec(Envelope) {
  use evidence <- codec.field(
    "evidence",
    codec.list(codec.string()),
    get: fn(e: Envelope) { e.evidence },
  )
  use content <- codec.field("content", codec.string(), get: fn(e: Envelope) {
    e.content
  })
  codec.success(Envelope(evidence:, content:))
}

pub type OrderQuery {
  OrderQuery(order: String)
}

fn order_query_codec() -> Codec(OrderQuery) {
  use order <- codec.field("order", codec.string(), get: fn(q: OrderQuery) {
    q.order
  })
  codec.success(OrderQuery(order:))
}

pub type SellerQuery {
  SellerQuery(seller: String)
}

fn seller_query_codec() -> Codec(SellerQuery) {
  use seller <- codec.field("seller", codec.string(), get: fn(q: SellerQuery) {
    q.seller
  })
  codec.success(SellerQuery(seller:))
}

fn read_tool(
  name: String,
  description: String,
  input: Codec(input),
  argument: fn(input) -> String,
) -> tool.Tool(Session) {
  tool.define(name, description, input, envelope_codec())
  |> tool.bind(
    fn(session: Session, _call, value) {
      use captured <- result.map(session.sources.read(name, argument(value)))
      Envelope(
        evidence: [json.to_string(wire.ref(captured.ref))],
        content: captured.body,
      )
    },
    fn(failure) { tool.Explain(decisions_model.describe(failure)) },
  )
  // A read is safe to start again after a crash.
  |> tool.with_replay(3)
}

pub fn propose_definition() -> tool.Definition(Payout, Truth) {
  tool.define(
    propose,
    "Propose a payout to the seller. Finance decides; the result says what really happened.",
    domain.payout_codec(),
    domain.truth_codec(),
  )
}

fn tools() -> List(tool.Tool(Session)) {
  [
    read_tool(
      domain.read_order,
      "The order: its seller, total and status.",
      order_query_codec(),
      fn(q: OrderQuery) { q.order },
    ),
    read_tool(
      domain.read_dispute,
      "How the order's dispute ended and what the seller is still owed.",
      order_query_codec(),
      fn(q: OrderQuery) { q.order },
    ),
    read_tool(
      domain.read_history,
      "The seller's earlier payouts and recent chargebacks.",
      seller_query_codec(),
      fn(q: SellerQuery) { q.seller },
    ),
    tool.bind(
      propose_definition(),
      fn(session: Session, _call, _proposed) {
        // The body runs only when the decision point lets the call through,
        // with the outcome in the session. It returns that outcome, never
        // its own arguments: the amount may have been corrected.
        case session.settled {
          Some(truth) -> Ok(truth)
          None -> Error(Nil)
        }
      },
      fn(_) { tool.Explain("the payout has not been decided") },
    ),
  ]
}

/// Fabric's policy: every read runs, and the payout waits for the
/// decision point.
fn gate(
  _session: Session,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.name == propose {
    True -> Ok(policy.RequireApproval(requirement))
    False -> Ok(policy.Allow)
  }
}

/// The agent every run uses. `approvers` are the decision point's (see
/// `payout_desk/app`); `expiry` is `run.Infinity` in production.
pub fn build(
  approvers: Approvers(String),
  script: Script,
  expiry: run.Timeout,
) -> Result(Agent(Session, Reply), String) {
  agent.new("payout_support", scripted(script), tools(), gate)
  |> agent.with_system_prompt(
    "You help marketplace sellers with payouts. Read the order, its dispute and the seller's history, then propose a payout. Tell the seller only what the proposal's result says.",
  )
  |> agent.with_answer(domain.reply_codec())
  |> agent.with_approvers(approvers)
  |> agent.with_approval_expiry(expiry)
  |> agent.with_max_turns(6)
  |> agent.build
  |> result.map_error(agent.describe_config_errors)
}

/// The run of one request: a redelivered request finds its run.
pub fn run_id(request: String) -> RunId {
  run.id_from_parts("payout", [request])
}

/// The prompt a request starts its run with.
pub fn prompt(request: domain.Request) -> String {
  string.join(
    [
      "seller: " <> request.seller,
      "order: " <> request.order,
      "message: " <> request.text,
    ],
    "\n",
  )
}

// -- The scripted model ---------------------------------------------------------------

/// A deterministic model: a pure function of the request Fabric sends.
fn scripted(script: Script) -> fabric_model.Model {
  fabric_model.new(fn(request: Request) {
    let prompt = case request.messages {
      [fabric_model.UserMessage(text), ..] -> text
      _ -> ""
    }
    let seller = line(prompt, "seller")
    let order = line(prompt, "order")
    let results = results(request)
    Ok(case dict.get(results, propose), dict.get(results, domain.read_dispute) {
      Ok(answer), _ -> final(script, seller, answer, proposed(request))
      Error(Nil), Ok(dispute) -> {
        let owed =
          envelope_content(dispute, domain.dispute_codec())
          |> result.map(fn(d: Dispute) { d.seller_owed_cents })
          |> result.unwrap(0)
        call([
          #(
            "p1",
            propose,
            codec.encode_json(
              domain.payout_codec(),
              Payout(
                seller:,
                order:,
                amount_cents: owed,
                reason: "dispute correction",
              ),
            )
              |> result.unwrap("{}"),
          ),
        ])
      }
      Error(Nil), Error(Nil) ->
        call([
          #("r1", domain.read_order, json_object([#("order", order)])),
          #("r2", domain.read_dispute, json_object([#("order", order)])),
          #("r3", domain.read_history, json_object([#("seller", seller)])),
        ])
    })
  })
}

fn final(
  script: Script,
  seller: String,
  answer: String,
  asked: Int,
) -> fabric_model.Reply {
  let name = string.capitalise(seller)
  let reply = case script, outcome_in(answer) {
    Naive, _ ->
      Reply(
        outcome: "paid",
        amount_cents: asked,
        message: "Done, "
          <> name
          <> ": "
          <> domain.money(asked)
          <> " is on its way.",
      )
    Careful, Some(truth) ->
      Reply(
        outcome: domain.outcome_name(truth),
        amount_cents: domain.paid_cents(truth),
        message: told(name, truth),
      )
    Careful, None ->
      Reply(
        outcome: "unknown",
        amount_cents: 0,
        message: name
          <> ", I could not confirm your payout yet; finance will follow up.",
      )
  }
  fabric_model.FinalAnswer(
    codec.encode_json(domain.reply_codec(), reply) |> result.unwrap("{}"),
    None,
  )
}

fn told(name: String, truth: Truth) -> String {
  case truth {
    domain.Paid(amount_cents:, asked_cents:, receipt:)
      if amount_cents != asked_cents
    ->
      name
      <> ", finance reviewed the dispute and paid you "
      <> domain.money(amount_cents)
      <> " instead of the "
      <> domain.money(asked_cents)
      <> " I proposed (receipt "
      <> receipt
      <> ")."
    domain.Paid(amount_cents:, receipt:, ..) ->
      name
      <> ", we paid you "
      <> domain.money(amount_cents)
      <> " (receipt "
      <> receipt
      <> ")."
    domain.NotPaid(reason:, ..) ->
      name <> ", the payout was approved but not made: " <> reason <> "."
    domain.Rejected(reason) ->
      name <> ", finance did not approve the payout: " <> reason <> "."
    domain.Expired ->
      name <> ", your request was not decided in time, so nothing was paid."
    domain.Withdrawn(..) ->
      name <> ", the payout was withdrawn before it was made."
    domain.Refused(reason) ->
      name <> ", the payout could not be made: " <> reason <> "."
  }
}

/// The outcome in a proposal's result: the tool's own result, or the
/// rejection's reason. Fabric's own rejection (an expired approval) carries
/// no outcome.
fn outcome_in(content: String) -> Option(Truth) {
  case codec.decode_json(domain.truth_codec(), content) {
    Ok(truth) -> Some(truth)
    Error(_) ->
      json.parse(content, decode.at(["detail"], decode.string))
      |> result.replace_error(Nil)
      |> result.try(fn(detail) {
        codec.decode_json(domain.truth_codec(), detail)
        |> result.replace_error(Nil)
      })
      |> option.from_result
  }
}

/// The amount the model proposed in this run.
fn proposed(request: Request) -> Int {
  list.find_map(request.messages, fn(message) {
    case message {
      fabric_model.AssistantMessage(turn) ->
        list.find_map(turn.calls, fn(call) {
          case call.name == propose {
            True ->
              codec.decode_json(domain.payout_codec(), call.arguments_json)
              |> result.map(fn(p: Payout) { p.amount_cents })
              |> result.replace_error(Nil)
            False -> Error(Nil)
          }
        })
      _ -> Error(Nil)
    }
  })
  |> result.unwrap(0)
}

/// Each tool's latest result, by tool name.
fn results(request: Request) -> dict.Dict(String, String) {
  let names =
    list.flat_map(request.messages, fn(message) {
      case message {
        fabric_model.AssistantMessage(turn) ->
          list.map(turn.calls, fn(call) { #(call.id, call.name) })
        _ -> []
      }
    })
  list.fold(request.messages, dict.new(), fn(found, message) {
    case message {
      fabric_model.ToolResultMessage(call_id:, content:) ->
        case list.key_find(names, call_id) {
          Ok(name) -> dict.insert(found, name, content)
          Error(Nil) -> found
        }
      _ -> found
    }
  })
}

fn envelope_content(text: String, inner: Codec(a)) -> Result(a, Nil) {
  use envelope <- result.try(
    codec.decode_json(envelope_codec(), text) |> result.replace_error(Nil),
  )
  codec.decode_json(inner, envelope.content) |> result.replace_error(Nil)
}

fn call(calls: List(#(String, String, String))) -> fabric_model.Reply {
  fabric_model.ToolRequest(
    fabric_model.AssistantTurn(
      "",
      list.map(calls, fn(c) {
        fabric_model.tool_call(id: c.0, name: c.1, arguments_json: c.2)
      }),
      None,
    ),
    None,
  )
}

fn json_object(fields: List(#(String, String))) -> String {
  json.to_string(
    json.object(list.map(fields, fn(f) { #(f.0, json.string(f.1)) })),
  )
}

fn line(text: String, name: String) -> String {
  string.split(text, "\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, ": ") {
      Ok(#(key, value)) if key == name -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

// -- Driving a run -------------------------------------------------------------------------

/// The gated call a run is parked on.
pub type Parked {
  Parked(
    run: String,
    /// The action within the run: `turn.call_id`.
    action: String,
    reference: run.ApprovalRef,
    arguments_json: String,
  )
}

/// Where a run came to rest.
pub type Reached {
  /// It waits for the decision point, with what it has done so far.
  Waiting(call: Parked, actions: List(run.ActionRecord))
  /// It ended with its answer.
  Answered(reply: Reply)
}

pub type DriveError {
  /// Fabric's store could not be reached; try again.
  RunsUnavailable(detail: String)
  /// The run ended without an answer, or is stuck on an uncertain read.
  RunStopped(detail: String)
  /// The run was still working at the deadline.
  StillWorking
}

pub fn describe_drive_error(error: DriveError) -> String {
  case error {
    RunsUnavailable(detail) -> "the runs are unavailable: " <> detail
    RunStopped(detail) -> "the run stopped: " <> detail
    StillWorking -> "the run was still working at the deadline"
  }
}

/// Start the request's run, or find it, and wait until it rests.
pub fn drive(
  runs: Store,
  agent: Agent(Session, Reply),
  session: Session,
  id id: RunId,
  prompt prompt: String,
  within within: Duration,
) -> Result(Reached, DriveError) {
  use handle <- result.try(
    case
      fabric.start(
        runs,
        agent,
        id:,
        context: session,
        prompt:,
        correlation: None,
      )
    {
      Error(fabric.AlreadyStarted(..)) ->
        fabric.recover(runs, agent, session, id)
      other -> other
    }
    |> result.map_error(fn(e) { RunsUnavailable(fabric.describe_error(e)) }),
  )
  settle(handle, within)
}

/// Wait until the run rests and say where.
pub fn settle(
  handle: fabric.Run(Session, Reply),
  within: Duration,
) -> Result(Reached, DriveError) {
  use status <- result.try(
    fabric.await(handle, within:)
    |> result.map_error(fn(e) { RunsUnavailable(fabric.describe_error(e)) }),
  )
  case status {
    run.Finished(run.Completed(answer:)) -> Ok(Answered(answer))
    run.Finished(outcome) -> Error(RunStopped(run.describe_outcome(outcome)))
    run.Suspended(approvals:, uncertain:) ->
      case list.find(approvals, fn(pending) { pending.tool == propose }) {
        Ok(pending) -> {
          use snapshot <- result.map(
            fabric.snapshot(handle)
            |> result.map_error(fn(e) {
              RunsUnavailable(fabric.describe_error(e))
            }),
          )
          Waiting(
            call: Parked(
              run: run.id_to_string(pending.reference.run),
              action: action_key(pending.reference.id),
              reference: pending.reference,
              arguments_json: pending.arguments_json,
            ),
            actions: snapshot.actions,
          )
        }
        Error(Nil) ->
          Error(RunStopped(
            string.inspect(list.length(uncertain)) <> " uncertain tool effects",
          ))
      }
    run.Working | run.Unattended -> Error(StillWorking)
  }
}

fn action_key(id: run.ActionId) -> String {
  string.inspect(id.turn) <> "." <> id.call_id
}

// -- What the model received ------------------------------------------------------------

/// The evidence behind every read result the model received, in call
/// order. A read that failed, was denied, or never reported contributes
/// nothing, whatever its body read before that.
pub fn received(actions: List(run.ActionRecord)) -> List(Ref) {
  list.flat_map(actions, fn(action) {
    case action.state {
      run.Succeeded(content:) ->
        codec.decode_json(envelope_codec(), content)
        |> result.map(fn(envelope) {
          list.filter_map(envelope.evidence, fn(text) {
            json.parse(text, wire.ref_decoder()) |> result.replace_error(Nil)
          })
        })
        |> result.unwrap([])
      _ -> []
    }
  })
  |> list.unique
}

/// The content of the latest received result of a read tool.
fn received_content(
  actions: List(run.ActionRecord),
  name: String,
  inner: Codec(a),
) -> Option(a) {
  list.filter_map(actions, fn(action) {
    case action.call.name == name, action.state {
      True, run.Succeeded(content:) -> envelope_content(content, inner)
      _, _ -> Error(Nil)
    }
  })
  |> list.last
  |> option.from_result
}

/// The parked call as a recommendation for `decisions`: the output it
/// asks for, the reads the model received, the signals computed from those
/// reads, and the run and action as its explanation.
pub fn recommendation(
  call: Parked,
  actions: List(run.ActionRecord),
) -> Result(vocabulary.Recommendation(Payout), decisions_model.Failure) {
  use output <- result.map(
    codec.decode_json(domain.payout_codec(), call.arguments_json)
    |> result.map_error(fn(e) {
      decisions_model.Undecodable(codec.describe_decode_error(e))
    }),
  )
  let dispute: Option(Dispute) =
    received_content(actions, domain.read_dispute, domain.dispute_codec())
  let history: Option(History) =
    received_content(actions, domain.read_history, domain.history_codec())
  Recommendation(
    output:,
    by: recommender_id,
    explanation: RunAction(run: call.run, action: call.action),
    signals: domain.signals(dispute, history),
    reads: received(actions),
  )
}

/// The parked call as a `decisions` model that **reports** the reads its
/// model received: `decisions/model.run` believes the reads it puts on the
/// recommendation and records nothing it observed. The `Sources` that
/// `model.run` hands it are not used: the tools ran in Fabric's processes
/// through the session's own sources, and may run again after this returns
/// (a recovery), when `model.run`'s sources are gone.
pub fn reported(
  call: Parked,
  actions: List(run.ActionRecord),
) -> decisions_model.Model(Payout) {
  decisions_model.reporting(fn(_context, _sources) {
    recommendation(call, actions)
  })
}
