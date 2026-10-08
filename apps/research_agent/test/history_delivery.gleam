//// Application-owned history-turn recipe used by history_delivery_test.
//// Grind owns delivery; the Fabric sweeper owns admitted execution. This
//// module does not add a queue, lease renewal, or abandoned-run scan.

import envoy
import fabric
import fabric/agent
import fabric/input
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/sweeper
import fabric_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/job
import grind/queue
import grind/worker
import json/blueprint/codec
import pog
import research_agent/wire

pub type Decision {
  Continue
  LoseReply
}

pub type Notice {
  BeforeStart(process.Subject(Decision))
  ModelCalled(recovered: Bool, messages: List(model.Message))
  BeforeApply(run.RunId, process.Subject(Decision))
  AfterApply(process.Subject(Decision))
}

pub type App {
  App(
    jobs: grind.Grind,
    db: pog.Connection,
    runs: store.Store,
    backend: fabric_postgres.Settings,
    agent: agent.Agent(Bool, String),
    worker: worker.Worker(String, String, String),
    notices: process.Subject(Notice),
  )
}

type SavedTurn {
  Pending(input.Input)
  Applied(answer: String)
}

type Dependencies {
  Dependencies(
    runs: store.Store,
    agent: agent.Agent(Bool, String),
    notices: process.Subject(Notice),
  )
}

pub fn start() -> App {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let name = process.new_name("history_delivery_pool")
  let assert Ok(pool) = pog.url_config(name, url)
  let pool =
    pool
    |> pog.pool_size(8)
    |> pog.connection_parameter("search_path", "history_delivery,public")
  let db = pog.named_connection(name)
  let notices = process.new_subject()
  let assert Ok(backend) =
    fabric_postgres.settings(db, node: "history-delivery")
    |> fabric_postgres.with_schema("history_delivery")
    |> result.map(fabric_postgres.with_lease(_, duration.milliseconds(300)))
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("history_delivery_runs"), backend)
  let assert Ok(runs) = store.with_drain(runs, duration.milliseconds(1))
  let agent =
    agent.new(
      "history-delivery-agent",
      model.new(fn(request) {
        let assert Ok(pog.Returned(_, [call_number])) =
          pog.query("INSERT INTO model_calls DEFAULT VALUES RETURNING id")
          |> pog.returning(decode.field(0, decode.int, decode.success))
          |> pog.execute(db)
        let recovered = call_number > 1
        process.send(notices, ModelCalled(recovered, request.messages))
        case recovered {
          True -> Ok(model.FinalAnswer("One observation summarized", None))
          False -> {
            // The fixture deliberately outlives the bounded store drain.
            let never = process.new_subject()
            let _ = process.receive(never, within: 30_000)
            Ok(model.FinalAnswer("late reply", None))
          }
        }
      }),
      [],
      fn(_context: Bool, _action) { Ok(policy.Allow) },
    )
    |> agent.build
  let assert Ok(agent) = agent
  let deps = Dependencies(runs, agent, notices)
  let worker =
    worker.responding(
      "history-delivery.turn",
      input: wire.grind("turn-key-1", codec.string()),
      output: wire.grind("answer-1", codec.string()),
      handle: fn(context, key) {
        deliver(deps, worker.connection(context), key)
      },
    )
    |> worker.with_error_codec(wire.grind("error-1", codec.string()))
    |> worker.with_queue("history-turns")
    |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 3))
  let config =
    grind.new(pool)
    |> grind.with_schema("history_delivery")
    |> grind.with_startup_migration
    |> grind.with_statement_deadline(duration.milliseconds(1500))
    |> grind.with_unique_lock_wait(duration.milliseconds(200))
    |> grind.with_worker(worker)
    |> grind.with_queue(
      queue.new("history-turns")
      |> queue.with_concurrency(1)
      |> queue.with_poll_interval(duration.milliseconds(25))
      |> queue.with_lease(duration.seconds(6)),
    )
  let assert Ok(jobs) = grind.start(config, process.new_name("history_jobs"))
  let assert Ok(_) =
    pog.query(
      "CREATE TABLE turns (
         key text PRIMARY KEY,
         previous_question text NOT NULL,
         previous_answer text NOT NULL,
         prompt text NOT NULL,
         answer text,
         run_id text,
         generated text,
         applications integer NOT NULL DEFAULT 0,
         observation text,
         observation_code text,
         CHECK ((answer IS NULL AND run_id IS NULL AND generated IS NULL AND applications = 0)
             OR (answer IS NOT NULL AND run_id IS NOT NULL AND generated IS NOT NULL AND applications = 1)))",
    )
    |> pog.execute(db)
  let assert Ok(_) =
    pog.query("CREATE TABLE model_calls (id bigserial PRIMARY KEY)")
    |> pog.execute(db)
  let assert Ok(Nil) = fabric_postgres.migrate(backend)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(sweeper_pid) =
    sweeper.start(
      runs,
      [sweeper.agent(agent, context: fn(_) { True })],
      every: duration.milliseconds(25),
    )
  // Script sweepers link their caller; this fixture deliberately stops the
  // store and observes recovery without letting that expected exit kill EUnit.
  process.unlink(sweeper_pid)
  App(jobs, db, runs, backend, agent, worker, notices)
}

pub fn stop(app: App) {
  let assert Ok(Nil) = store.stop(app.runs)
  let assert Ok(_) = grind.stop(app.jobs)
}

pub fn next(app: App) -> Notice {
  let assert Ok(notice) = process.receive(app.notices, within: 10_000)
  notice
}

pub fn accept(app: App, tx: pog.Connection, key: String) {
  use _ <- result.try(
    pog.query(
      "INSERT INTO turns (key, previous_question, previous_answer, prompt)
       VALUES ($1, 'List the observations', 'One observation', 'Summarize those observations')",
    )
    |> pog.parameter(pog.text(key))
    |> pog.execute(tx)
    |> result.map_error(string.inspect),
  )
  grind.submit_in(app.jobs, tx, job.new(app.worker, key))
  |> result.map_error(grind.describe_submit_error)
}

fn load(db: pog.Connection, key: String) -> Result(SavedTurn, String) {
  let row = {
    use previous_question <- decode.field(0, decode.string)
    use previous_answer <- decode.field(1, decode.string)
    use prompt <- decode.field(2, decode.string)
    use answer <- decode.field(3, decode.optional(decode.string))
    decode.success(#(previous_question, previous_answer, prompt, answer))
  }
  use rows <- result.try(
    pog.query(
      "SELECT previous_question, previous_answer, prompt, answer FROM turns WHERE key = $1",
    )
    |> pog.parameter(pog.text(key))
    |> pog.returning(row)
    |> pog.execute(db)
    |> result.map_error(string.inspect),
  )
  case rows.rows {
    [#(_, _, _, Some(answer))] -> Ok(Applied(answer))
    [#(previous_question, previous_answer, prompt, None)] ->
      input.new(
        [
          model.UserMessage(previous_question),
          model.AssistantMessage(model.AssistantTurn(previous_answer, [], None)),
        ],
        prompt,
      )
      |> result.map(Pending)
      |> result.map_error(string.inspect)
    _ -> Error("missing accepted turn")
  }
}

fn invoke_input(deps: Dependencies, key: String, initial: input.Input) {
  let request =
    invoke.request(False, initial)
    |> invoke.with_principal("research-reader")
    |> invoke.with_key(Some(key))
  invoke.agent_with_history("history-turn", deps.runs, deps.agent)
  |> invoke.with_wait(duration.milliseconds(100))
  |> invoke.call(request)
}

pub fn invoke_turn(app: App, key: String) {
  let assert Ok(Pending(initial)) = load(app.db, key)
  invoke_input(Dependencies(app.runs, app.agent, app.notices), key, initial)
}

fn barrier(
  notices: process.Subject(Notice),
  stage: fn(process.Subject(Decision)) -> Notice,
) {
  let reply = process.new_subject()
  process.send(notices, stage(reply))
  let assert Ok(decision) = process.receive(reply, within: 10_000)
  decision
}

fn deliver(deps: Dependencies, db: pog.Connection, key: String) {
  case load(db, key) {
    // This check precedes Fabric invocation and survives Fabric pruning.
    Ok(Applied(answer)) -> worker.Succeeded(answer)
    Error(error) -> worker.Failed(error)
    Ok(Pending(initial)) -> {
      let assert Continue = barrier(deps.notices, BeforeStart)
      let response = invoke_input(deps, key, initial)
      let assert Ok(_) =
        pog.query(
          "UPDATE turns SET observation = $2, observation_code = $3 WHERE key = $1",
        )
        |> pog.parameter(pog.text(key))
        |> pog.parameter(pog.text(observation(invoke.response_kind(response))))
        |> pog.parameter(pog.text(invoke.code(response)))
        |> pog.execute(db)
      case invoke.response_kind(response) {
        invoke.Answered -> apply_answer(deps, db, key, response)
        invoke.Working | invoke.Unattended ->
          worker.Snoozed(duration.milliseconds(100), "execution remains active")
        // Grind quarantines this delivery until application continuation.
        // The saved original kind distinguishes suspension from unknown effects.
        invoke.AwaitingApproval | invoke.AwaitingInput ->
          worker.Uncertain(
            "suspended execution needs its explicit continuation",
          )
        invoke.OutcomeUnknown ->
          worker.Uncertain("inspect or reconcile the retained execution")
        invoke.Ended -> worker.Failed(invoke.describe_response(response))
        invoke.Refused ->
          case invoke.code(response) {
            "unavailable" ->
              worker.Snoozed(duration.milliseconds(100), "read unavailable")
            _ -> worker.Discarded(invoke.describe_response(response))
          }
      }
    }
  }
}

fn observation(kind: invoke.Kind) {
  case kind {
    invoke.Answered -> "answered"
    invoke.Working -> "working"
    invoke.Unattended -> "unattended"
    invoke.AwaitingApproval -> "awaiting_approval"
    invoke.AwaitingInput -> "awaiting_input"
    invoke.OutcomeUnknown -> "outcome_unknown"
    invoke.Ended -> "ended"
    invoke.Refused -> "refused"
  }
}

fn apply_answer(
  deps: Dependencies,
  db: pog.Connection,
  key: String,
  response: invoke.Response(String),
) {
  let id = invoke.id(response)
  let assert Some(answer) = invoke.answer(response)
  let prepared = {
    use handle <- result.try(
      fabric.open(deps.runs, deps.agent, False, id)
      |> result.map_error(fabric.describe_error),
    )
    fabric.generated_messages(handle) |> result.map_error(fabric.describe_error)
  }
  case prepared {
    Error(error) -> worker.Snoozed(duration.milliseconds(100), error)
    Ok(generated) -> {
      let assert Continue = barrier(deps.notices, BeforeApply(id, _))
      case pog.transaction(db, incorporate(_, key, id, answer, generated)) {
        Error(error) ->
          worker.Snoozed(duration.milliseconds(100), string.inspect(error))
        Ok(answer) ->
          case barrier(deps.notices, AfterApply) {
            Continue -> worker.Succeeded(answer)
            LoseReply ->
              worker.Snoozed(
                duration.milliseconds(100),
                "incorporation reply lost",
              )
          }
      }
    }
  }
}

// The transaction owns row locking and incorporation. This is application
// state, not a Fabric persistence transaction or an effect hidden in admission.
pub fn incorporate(
  tx: pog.Connection,
  key: String,
  id: run.RunId,
  answer: String,
  generated: List(model.Message),
) {
  use locked <- result.try(
    pog.query("SELECT answer FROM turns WHERE key = $1 FOR UPDATE")
    |> pog.parameter(pog.text(key))
    |> pog.returning(decode.field(
      0,
      decode.optional(decode.string),
      decode.success,
    ))
    |> pog.execute(tx)
    |> result.map_error(string.inspect),
  )
  case locked.rows {
    [Some(answer)] -> Ok(answer)
    [None] -> {
      let encoded = json.array(generated, message_json) |> json.to_string
      use _ <- result.map(
        pog.query(
          "UPDATE turns SET answer = $2, run_id = $3, generated = $4,
           applications = applications + 1 WHERE key = $1",
        )
        |> pog.parameter(pog.text(key))
        |> pog.parameter(pog.text(answer))
        |> pog.parameter(pog.text(run.id_to_string(id)))
        |> pog.parameter(pog.text(encoded))
        |> pog.execute(tx)
        |> result.map_error(string.inspect),
      )
      answer
    }
    _ -> Error("missing accepted turn")
  }
}

// Serialization belongs to the application's chosen history schema. Fabric
// has already validated relationships and decoded the separate native answer.
fn optional_json(value, encode) {
  case value {
    None -> json.null()
    Some(value) -> encode(value)
  }
}

fn message_json(message: model.Message) {
  case message {
    model.UserMessage(text) ->
      json.object([
        #("role", json.string("user")),
        #("text", json.string(text)),
      ])
    model.ToolResultMessage(id, content) ->
      json.object([
        #("role", json.string("tool")),
        #("call_id", json.string(id)),
        #("content", json.string(content)),
      ])
    model.AssistantMessage(turn) ->
      json.object([
        #("role", json.string("assistant")),
        #("text", json.string(turn.text)),
        #(
          "calls",
          json.array(turn.calls, fn(call) {
            json.object([
              #("id", json.string(call.id)),
              #("name", json.string(call.name)),
              #("arguments_json", json.string(call.arguments_json)),
              #("provider_id", optional_json(call.provider_id, json.string)),
              #(
                "provider_state",
                optional_json(call.provider_state, json.string),
              ),
            ])
          }),
        ),
        #(
          "provider_data",
          optional_json(turn.data, fn(data) {
            json.object([
              #("format", json.string(data.format)),
              #("value", json.string(data.value)),
            ])
          }),
        ),
      ])
  }
}

fn count(db: pog.Connection, sql: String, params: List(String)) -> Int {
  let query =
    list.fold(params, pog.query(sql), fn(q, p) { pog.parameter(q, pog.text(p)) })
  let assert Ok(pog.Returned(_, [value])) =
    query
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(db)
  value
}

pub fn turn_count(db: pog.Connection, key: String) {
  count(db, "SELECT count(*) FROM turns WHERE key = $1", [key])
}

pub fn application_count(db: pog.Connection, key: String) {
  count(db, "SELECT applications FROM turns WHERE key = $1", [key])
}

pub fn job_count(db: pog.Connection) {
  count(db, "SELECT count(*) FROM grind_jobs", [])
}

pub fn run_count(db: pog.Connection) {
  count(db, "SELECT count(*) FROM fabric_runs", [])
}

pub fn model_calls(db: pog.Connection) {
  count(db, "SELECT count(*) FROM model_calls", [])
}

fn saved_field(db: pog.Connection, key: String, field: String) {
  let assert Ok(pog.Returned(_, [value])) =
    pog.query("SELECT generated::jsonb -> 0 ->> $2 FROM turns WHERE key = $1")
    |> pog.parameter(pog.text(key))
    |> pog.parameter(pog.text(field))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(db)
  value
}

pub fn saved_role(db: pog.Connection, key: String) {
  saved_field(db, key, "role")
}

pub fn saved_text(db: pog.Connection, key: String) {
  saved_field(db, key, "text")
}
