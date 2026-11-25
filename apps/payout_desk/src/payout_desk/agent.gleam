//// The support agent: three read tools, one gated tool, a scripted model
//// and a typed answer.
////
//// - **Reads.** Each read tool reaches the marketplace only through the
////   session's `Sources`, which capture what a read returned as evidence
////   before the model sees it. The tool's result is an envelope naming
////   that evidence, so the reads the model **received** are a fold over the
////   run's succeeded actions (`received`): a read whose tool failed after
////   reading never reaches the record.
//// - **The gated call.** Fabric's policy hands `propose_payout` over to the
////   `payout` decision point (`policy.HandOver`): the tool never runs, the
////   model takes no further turn, and the run ends `run.HandedOver` with
////   the call as the model sent it. No approval exists, so nothing can
////   expire and answer the model. `reported` turns the handed-over call
////   into a recommendation for `decisions`; the call's run and action are
////   its explanation, and the request's key is its key
////   (`jobs.request_key`).
//// - **Telling.** When the decision settles, `tell` starts a follow-on run
////   from the handed-over run's transcript (`fabric.handover_history`) in
////   which the call's result is the recorded outcome, never the call's own
////   arguments. The handed-over run itself never continues.

import decisions/model.{type Sources} as decisions_model
import decisions/vocabulary.{
  type Ref, Agent as AgentRecommender, Recommendation, RunAction,
}
import decisions/wire
import fabric
import fabric/agent.{type Agent}
import fabric/input
import fabric/model.{type Request} as fabric_model
import fabric/policy
import fabric/run.{type RunId}
import fabric/store.{type Store}
import fabric/tool
import gleam/bool
import gleam/dict
import gleam/int
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
    /// What really happened to the payout: `None` in the run that
    /// proposes, the recorded outcome in the follow-on run that tells it.
    settled: Option(Truth),
  )
}

/// The recommender's identity on the record. A new script or prompt is a
/// new version, so agreement is counted per version.
pub const recommender_id = AgentRecommender(kind: "payout_support", version: "1")

pub const propose = "propose_payout"

/// How the scripted model behaves once its proposal has an answer.
pub type Script {
  /// It reads the answer and tells the seller what it says.
  Careful
  /// It tells the seller the payout is done whatever the answer says: a
  /// model whose claim the application must not pass on.
  Naive
  /// It proposes the payout again once it holds the outcome, and then
  /// answers from what the second call returned: a model the follow-on
  /// policy must stop from handing the payout over twice.
  Insistent
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
    "Propose a payout to the seller. Finance decides, possibly days later; the result says what really happened.",
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
    // The policy never lets this call run: the run that proposes hands
    // it over, and the follow-on run is refused a second proposal. Its
    // result is the recorded outcome, given by `fabric.handover_history`.
    tool.bind(
      propose_definition(),
      fn(_session: Session, _call, _proposed) { Error(Nil) },
      fn(_) {
        tool.Explain("a payout is decided by finance, never by the agent")
      },
    ),
  ]
}

/// Fabric's policy: every read runs, and the payout is handed over to the
/// decision point. A follow-on run already holds the outcome, so a second
/// proposal there is refused and the model answers from the result.
fn gate(
  session: Session,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.name == propose, session.settled {
    True, None -> Ok(policy.HandOver(handed_over_reason))
    True, Some(_) -> Ok(policy.Deny("the payout is already decided"))
    False, _ -> Ok(policy.Allow)
  }
}

const handed_over_reason = "finance decides payouts at the payout decision point"

/// The agent every run uses, the one that proposes and the follow-on that
/// tells.
///
/// `unavailable` is a fault point: while it answers `True` the provider
/// behind the model refuses every call, so the run fails.
pub fn build(
  script: Script,
  unavailable: fn() -> Bool,
) -> Result(Agent(Session, Reply), String) {
  agent.build(fn() {
    agent.new("payout_support", scripted(script, unavailable), tools(), gate)
    |> agent.with_system_prompt(
      "You help marketplace sellers with payouts. Read the order, its dispute and the seller's history, then propose a payout. Tell the seller only what the proposal's result says.",
    )
    |> agent.with_answer(domain.reply_codec())
    |> agent.with_max_turns(6)
  })
  |> result.map_error(agent.describe_config_errors)
}

/// The run of one attempt at a request: a redelivered request finds its
/// run, and a request whose earlier run failed (`attempt` failed attempts
/// on its record) starts a fresh one, since a failed run cannot continue.
///
/// `run.id_from_parts` joins its parts with `-` and does not keep them
/// apart, and a request id is free text, so each shape has its own prefix
/// and a fixed-shape part comes first: the first attempt is
/// `payout-<request>`, a later one `payoutretry-<attempt>-<request>`. The
/// attempt is digits, so the first `-` after it ends it, and request `x-1`
/// at the first attempt (`payout-x-1`) and request `x` at the second
/// (`payoutretry-1-x`) name different runs. A request that is not a valid
/// id text is hashed under the same prefix, which stays apart too.
pub fn run_id(request: String, attempt: Int) -> RunId {
  case attempt {
    0 -> run.id_from_parts("payout", [request])
    _ -> run.id_from_parts("payoutretry", [int.to_string(attempt), request])
  }
}

/// The follow-on run that tells a request's outcome. A request is one
/// payout and hands one call over, so the request names it: a telling
/// delivered again finds the run it started. Its own prefix keeps it apart
/// from every proposing run.
pub fn follow_on_id(request: String) -> RunId {
  run.id_from_parts("payouttold", [request])
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
fn scripted(script: Script, unavailable: fn() -> Bool) -> fabric_model.Model {
  fabric_model.new(fn(request: Request) {
    use <- bool.guard(
      unavailable(),
      Error(fabric_model.error(
        fabric_model.Rejected,
        "the model's provider refused the call",
      )),
    )
    let prompt = case request.messages {
      [fabric_model.UserMessage(text), ..] -> text
      _ -> ""
    }
    let seller = line(prompt, "seller")
    let order = line(prompt, "order")
    let results = results(request)
    Ok(case dict.get(results, propose), dict.get(results, domain.read_dispute) {
      Ok(answer), _ ->
        case script, outcome_in(answer) {
          Insistent, Some(_) -> call([#("p2", propose, proposal(request))])
          _, _ -> final(script, seller, answer, proposed(request))
        }
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
    _, Some(truth) ->
      Reply(
        outcome: domain.outcome_name(truth),
        amount_cents: domain.paid_cents(truth),
        message: told(name, truth),
      )
    _, None ->
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
    domain.Superseded(..) ->
      name
      <> ", your payout was stopped because your account is under review; nothing was paid."
    domain.Withdrawn(..) ->
      name <> ", the payout was withdrawn before it was made."
    domain.Refused(reason) ->
      name <> ", the payout could not be made: " <> reason <> "."
  }
}

/// The outcome in a proposal's result: the recorded outcome the follow-on
/// run was given. Any other result, such as a refusal, carries none.
fn outcome_in(content: String) -> Option(Truth) {
  codec.decode_json(domain.truth_codec(), content)
  |> option.from_result
}

/// The amount the model proposed in this conversation.
fn proposed(request: Request) -> Int {
  codec.decode_json(domain.payout_codec(), proposal(request))
  |> result.map(fn(p: Payout) { p.amount_cents })
  |> result.unwrap(0)
}

/// The arguments of the model's first proposal in this conversation.
fn proposal(request: Request) -> String {
  list.find_map(request.messages, fn(message) {
    case message {
      fabric_model.AssistantMessage(turn) ->
        list.find_map(turn.calls, fn(call) {
          case call.name == propose {
            True -> Ok(call.arguments_json)
            False -> Error(Nil)
          }
        })
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("{}")
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

/// The gated call a run handed over, as `run.HandedOver` names it.
pub type Handed {
  Handed(
    /// The handed-over action: its run and its action id. On the record
    /// it is written in Fabric's text forms (`run.action_ref_to_string`,
    /// `run.action_id_to_string`) and read back with their parse
    /// functions.
    action: run.ActionRef,
    arguments_json: String,
  )
}

/// Where a run came to rest.
pub type Reached {
  /// It handed its proposal over and ended, with what it had done.
  HandedOver(call: Handed, actions: List(run.ActionRecord))
  /// It ended with its answer.
  Answered(reply: Reply)
}

pub type DriveError {
  /// Fabric's store could not be reached; try again.
  RunsUnavailable(detail: String)
  /// The run ended without an answer or a handover of the proposal, or is
  /// stuck on an uncertain read.
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

fn unavailable(error: fabric.Error) -> DriveError {
  RunsUnavailable(fabric.describe_error(error))
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
    |> result.map_error(unavailable),
  )
  settle(handle, within)
}

/// Tell the recorded outcome through a follow-on run of the run that
/// handed the proposal over, and wait until it rests. The follow-on run
/// continues the handed-over run's conversation with `truth` as the
/// proposal's result (`fabric.handover_history`), with no prompt of its
/// own (`input.continuation`). Started once per request (`follow_on_id`): a
/// telling delivered again finds it and waits for it. `handed` is the
/// action the record names; a run that handed over another action is
/// refused.
pub fn tell(
  runs: Store,
  agent: Agent(Session, Reply),
  session: Session,
  handed handed: run.ActionRef,
  truth truth: Truth,
  within within: Duration,
) -> Result(Reached, DriveError) {
  let id = follow_on_id(session.request)
  use input <- result.try(follow_on_input(runs, agent, session, handed, truth))
  use handle <- result.try(
    case
      fabric.start_with_input(
        runs,
        agent,
        id:,
        context: session,
        input:,
        correlation: None,
      )
    {
      Error(fabric.AlreadyStarted(..)) ->
        fabric.recover(runs, agent, session, id)
      other -> other
    }
    |> result.map_error(unavailable),
  )
  settle(handle, within)
}

/// The input of the follow-on run: the handed-over run's transcript, then
/// the recorded outcome as the proposal's result. The model's first turn
/// continues from that result.
fn follow_on_input(
  runs: Store,
  agent: Agent(Session, Reply),
  session: Session,
  handed: run.ActionRef,
  truth: Truth,
) -> Result(input.Input, DriveError) {
  use first <- result.try(
    fabric.open(runs, agent, session, handed.run)
    |> result.map_error(unavailable),
  )
  use snapshot <- result.try(
    fabric.snapshot(first) |> result.map_error(unavailable),
  )
  use Nil <- result.try(case snapshot.status {
    run.Finished(run.HandedOver(action:, ..)) if action == handed -> Ok(Nil)
    run.Finished(run.HandedOver(action:, ..)) ->
      Error(RunStopped(
        "the run handed over "
        <> run.action_ref_to_string(action)
        <> ", not "
        <> run.action_ref_to_string(handed),
      ))
    _ -> Ok(Nil)
  })
  use decided <- result.try(
    tool.reconciliation(propose_definition(), Ok(truth))
    |> result.map_error(fn(e) { RunStopped(string.inspect(e)) }),
  )
  use history <- result.try(
    fabric.handover_history(snapshot, result: decided)
    |> result.map_error(fn(e) {
      RunStopped(
        "the proposing run has no handover history: " <> string.inspect(e),
      )
    }),
  )
  input.continuation(history)
  |> result.map_error(fn(e) { RunStopped(string.inspect(e)) })
}

/// Wait until the run rests and say where.
pub fn settle(
  handle: fabric.Run(Session, Reply),
  within: Duration,
) -> Result(Reached, DriveError) {
  use status <- result.try(
    fabric.await(handle, within:) |> result.map_error(unavailable),
  )
  case status {
    run.Finished(run.Completed(answer:)) -> Ok(Answered(answer))
    run.Finished(run.HandedOver(action:, tool:, arguments_json:, ..))
      if tool == propose
    -> {
      use snapshot <- result.map(
        fabric.snapshot(handle) |> result.map_error(unavailable),
      )
      HandedOver(
        call: Handed(action:, arguments_json:),
        actions: snapshot.actions,
      )
    }
    run.Finished(outcome) -> Error(RunStopped(run.describe_outcome(outcome)))
    run.Suspended(approvals:, uncertain:) ->
      Error(RunStopped(
        int.to_string(list.length(approvals))
        <> " approvals and "
        <> int.to_string(list.length(uncertain))
        <> " uncertain tool effects",
      ))
    run.Working | run.Unattended -> Error(StillWorking)
  }
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

/// The handed-over call as a recommendation for `decisions`: the output it
/// asks for, the reads the model received, the signals computed from those
/// reads, and the run and action as its explanation.
pub fn recommendation(
  call: Handed,
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
    explanation: RunAction(
      run: run.id_to_string(call.action.run),
      action: run.action_id_to_string(call.action.id),
    ),
    signals: domain.signals(dispute, history),
    reads: received(actions),
  )
}

/// The handed-over call as a `decisions` model that **reports** the reads
/// its model received: `decisions/model.run` believes the reads it puts on
/// the recommendation and records nothing it observed. The `Sources` that
/// `model.run` hands it are not used: the tools ran in Fabric's processes
/// through the session's own sources, before the run ended.
pub fn reported(
  call: Handed,
  actions: List(run.ActionRecord),
) -> decisions_model.Model(Payout) {
  decisions_model.reporting(fn(_context, _sources) {
    recommendation(call, actions)
  })
}
