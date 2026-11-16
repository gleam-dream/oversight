//// Test support: an application on its own schema of the disposable
//// cluster, the provider it pays through, staff signing in to the desk's
//// MCP endpoint, and waiting on what the jobs do.

import decisions
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary
import decisions_postgres
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import payout_desk/app.{type App, type Settings}
import payout_desk/db
import payout_desk/domain.{type Payout}
import payout_desk/provider
import payout_desk/world
import relay/client as mcp

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(Positive)) -> Int

type Positive {
  Positive
}

pub fn unique() -> Int {
  unique_integer([Positive])
}

/// Settings for a test: a schema of its own, a provider of its own, and a
/// policy version 1 whose undo window is short enough to wait out.
pub fn settings(name: String) -> Settings {
  let assert Ok(url) = app.database_url()
  let assert Ok(provider) = provider.start()
  app.settings(url, schema: name <> "_" <> int.to_string(unique()), provider:)
  |> fn(s) { app.Settings(..s, hold: duration.seconds(1)) }
}

pub fn start(settings: Settings) -> App {
  let assert Ok(running) = app.start(settings)
  let assert Ok(Nil) = world.seed(running.db)
  running
}

/// Run `body` against a started application, then stop it and its
/// provider.
pub fn with_app(
  name: String,
  change: fn(Settings) -> Settings,
  body: fn(App) -> a,
) -> a {
  let settings = change(settings(name))
  let running = start(settings)
  let answer = body(running)
  app.stop(running)
  provider.stop(settings.provider)
  answer
}

/// Wait until `ready` holds, checking every 50 ms, at most `within` ms.
pub fn eventually(within: Int, ready: fn() -> Bool) -> Bool {
  case ready() {
    True -> True
    False ->
      case within <= 0 {
        True -> False
        False -> {
          process.sleep(50)
          eventually(within - 50, ready)
        }
      }
  }
}

/// Dora asks about `order`, whose dispute ended with `status`, owing her
/// `owed_cents`. Returns the occurrence her agent's gated call became.
pub fn ask(
  running: App,
  request: String,
  order: String,
  status: String,
  owed_cents: Int,
) -> String {
  let assert Ok(Nil) =
    world.disputed(
      running.db,
      order:,
      status:,
      owed_cents:,
      fee_cents: owed_cents / 4,
    )
  let assert Ok(Nil) =
    app.request(
      running,
      world.request(request, order),
      requested_by: world.fiona,
    )
  let assert Ok(id) = app.occurrence_of(running, request, 15_000)
  id
}

pub fn read(running: App, id: String) -> Occurrence(Payout) {
  let assert Ok(known) =
    decisions_postgres.transaction(running.db, decisions.read(
      app.payout_desk(running),
      _,
      occurrence: id,
    ))
  known
}

/// Wait until the occurrence's status is `name`.
pub fn reaches(running: App, id: String, name: String, within: Int) -> Bool {
  eventually(within, fn() {
    occurrence.status_name(read(running, id).status) == name
  })
}

/// What Dora was told about this payout, waiting for it.
pub fn told(running: App, id: String, within: Int) -> Option(db.Told) {
  let found =
    eventually(within, fn() {
      case db.told(running.db, id) {
        Ok(Some(_)) -> True
        _ -> False
      }
    })
  case found {
    True -> db.told(running.db, id) |> result.unwrap(None)
    False -> None
  }
}

/// An MCP client signed in as `subject`.
pub fn desk(running: App, subject: String) -> mcp.Client {
  connect(running, Some(app.token(running, subject)))
}

pub fn connect(running: App, token: Option(String)) -> mcp.Client {
  let assert Ok(config) = mcp.http(running.mcp_url)
  let bearer = case token {
    Some(token) -> [#("authorization", "Bearer " <> token)]
    None -> []
  }
  let assert Ok(client) =
    config
    |> mcp.with_timeout(duration.seconds(10))
    |> mcp.with_headers(fn() { bearer })
    |> mcp.connect
  client
}

pub fn first(items: List(a)) -> a {
  let assert [item, ..] = items
  item
}

pub fn count(items: List(a), keep: fn(a) -> Bool) -> Int {
  list.length(list.filter(items, keep))
}

/// True the first time it is called with `key` on this node.
@external(erlang, "payout_desk_test_ffi", "once")
pub fn once(key: String) -> Bool

/// Run `work` in `count` processes released at once, and collect their
/// results in any order.
pub fn race(count: Int, work: fn(Int) -> a) -> List(a) {
  let results = process.new_subject()
  let ready = process.new_subject()
  let indexes =
    int.range(from: 0, to: count, with: [], run: fn(acc, n) { [n, ..acc] })
  list.each(indexes, fn(n) {
    process.spawn(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let _ = process.receive(go, 60_000)
      process.send(results, work(n))
    })
  })
  let gates =
    list.map(indexes, fn(_) {
      let assert Ok(go) = process.receive(ready, 10_000)
      go
    })
  list.each(gates, fn(go) { process.send(go, Nil) })
  list.map(gates, fn(_) {
    let assert Ok(result) = process.receive(results, 30_000)
    result
  })
}

/// Open the card and give a verdict in one transaction, as `subject`.
pub fn decide(
  running: App,
  id: String,
  subject: String,
  verdict: vocabulary.Verdict(Payout),
) -> Result(Occurrence(Payout), decisions_postgres.Failure) {
  let assert Ok(validator) = db.validator(running.db, subject)
  decisions_postgres.decide(
    running.db,
    app.payout_desk(running),
    fn(tx) {
      decisions.open(
        app.payout_desk(running),
        tx,
        occurrence: id,
        by: validator,
        latest: fn(ref) { ref.revision },
      )
    },
    verdict,
  )
}

/// Open the card as `subject`, in a transaction of its own.
pub fn open(
  running: App,
  id: String,
  subject: String,
) -> decisions.Card(Payout) {
  let assert Ok(validator) = db.validator(running.db, subject)
  let assert Ok(card) =
    decisions_postgres.transaction(
      running.db,
      decisions.open(
        app.payout_desk(running),
        _,
        occurrence: id,
        by: validator,
        latest: fn(ref) { ref.revision },
      ),
    )
  card
}

/// Give a verdict on a card shown earlier, by its ticket.
pub fn decide_on(
  running: App,
  card: decisions.Card(Payout),
  verdict: vocabulary.Verdict(Payout),
) -> Result(Occurrence(Payout), decisions_postgres.Failure) {
  let holder = decisions.holder(card)
  decisions_postgres.decide(
    running.db,
    app.payout_desk(running),
    decisions.resume(
      app.payout_desk(running),
      _,
      decisions.ticket(card),
      by: holder,
    ),
    verdict,
  )
}

pub fn corrected(cents: Int) -> fn(Payout) -> vocabulary.Verdict(Payout) {
  fn(standing: Payout) {
    vocabulary.Correct(
      domain.Payout(..standing, amount_cents: cents),
      vocabulary.Reason("chargeback_fee", Some("the seller bears the fee")),
    )
  }
}
