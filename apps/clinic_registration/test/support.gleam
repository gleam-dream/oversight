//// Test support: a fresh database per test inside the disposable cluster
//// that `../scripts/with-postgres.sh` starts, the scripted providers, the
//// application over them, and small helpers to wait for an outcome and to
//// call the desk over HTTP.

import clinic_registration/access
import clinic_registration/app.{type App}
import clinic_registration/domain.{type Inbound, type Registration, Inbound}
import clinic_registration/owner
import clinic_registration/scripted.{type Services}
import clinic_registration/store
import decisions
import decisions/occurrence.{type Occurrence}
import decisions_postgres
import decisions_postgres/queue
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/destination
import pog

@external(erlang, "support_ffi", "unique")
pub fn unique() -> Int

@external(erlang, "support_ffi", "quiet_pool_shutdown")
fn quiet_pool_shutdown() -> Nil

/// True the first time it is called with `key` on this node.
@external(erlang, "support_ffi", "once")
pub fn once(key: String) -> Bool

@external(erlang, "support_ffi", "ensure")
fn ensure(body: fn() -> a, cleanup: fn() -> b) -> a

/// A name no other test uses.
pub fn tag(prefix: String) -> String {
  prefix <> int.to_string(unique())
}

/// The cluster's URL from the helper script. Without it the tests fail
/// rather than pass untested.
pub fn cluster_url() -> String {
  case envoy.get("DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) ->
      panic as "DATABASE_URL is unset: run ../scripts/with-postgres.sh gleam test"
  }
}

/// A new, empty database in the cluster, and its URL.
pub fn fresh_database() -> String {
  let url = cluster_url()
  let name = tag("clinic_test_")
  let assert Ok(config) = pog.url_config(process.new_name("clinic_admin"), url)
  let assert Ok(#(Nil, pool)) =
    owner.start(fn() {
      let assert Ok(started) = pog.start(pog.pool_size(config, 1))
      let assert Ok(_) =
        pog.query("CREATE DATABASE " <> name) |> pog.execute(started.data)
      Ok(Nil)
    })
  owner.stop(pool)
  let assert Ok(#(base, _)) = split_last(url, "/")
  base <> "/" <> name
}

fn split_last(text: String, on: String) -> Result(#(String, String), Nil) {
  let parts = string.split(text, on)
  case list.reverse(parts) {
    [last, ..rest] if rest != [] ->
      Ok(#(string.join(list.reverse(rest), on), last))
    _ -> Error(Nil)
  }
}

pub type Env {
  Env(app: App, services: Services, url: String, config: app.Config)
}

/// Start the scripted providers and the application over a fresh database,
/// with the clinic's insurers, run `body`, and stop everything.
pub fn with_app(
  configure: fn(app.Config) -> app.Config,
  body: fn(Env) -> a,
) -> a {
  quiet_pool_shutdown()
  let assert Ok(services) = scripted.start()
  let url = fresh_database()
  let env = boot(services, url, configure)
  ensure(fn() { body(env) }, fn() {
    app.stop(env.app)
    scripted.stop(services)
  })
}

/// Stop the application and start it again on the same database and
/// services, configured anew: a restart, or the same clinic later in time.
pub fn restart(env: Env, configure: fn(app.Config) -> app.Config) -> Env {
  app.stop(env.app)
  boot(env.services, env.url, configure)
}

/// Start the application on an existing database and services.
pub fn boot(
  services: Services,
  url: String,
  configure: fn(app.Config) -> app.Config,
) -> Env {
  let config =
    app.default_config(
      database_url: url,
      llm_base: scripted.llm_base(services),
      messaging_base: scripted.messaging_base(services),
      provider_ports: scripted.ports(services),
    )
    |> fn(config) {
      app.Config(..config, staff: staff(), channel: Some(channel()))
    }
    |> configure
  let assert Ok(application) = app.start(config)
  list.each(insurers, fn(name) {
    let assert Ok(Nil) = store.accept_insurer(application.db, name)
  })
  Env(app: application, services:, url:, config:)
}

pub const insurers = ["Bradesco Saúde", "SulAmérica", "Unimed"]

// -- Ana --------------------------------------------------------------------------

/// A contact's first message, under a fresh id.
pub fn message(contact: String, profile: String, text: String) -> Inbound {
  Inbound(id: tag("wamid-"), contact:, profile_name: profile, text:)
}

/// A phone number no other test uses.
pub fn phone() -> String {
  "+55119" <> int.to_string(10_000_000 + unique() % 89_999_999)
}

/// What the model answers for Ana: confident and complete.
pub fn ana_answer(phone: String) -> domain.Extraction {
  scripted.extraction(
    name: "Ana Souza",
    birth_date: Some("1990-04-12"),
    phone:,
    insurer: Some("Unimed"),
    plan: Some("Unimed Flex"),
    confidence: 0.96,
  )
}

pub const ana_says =
  "Oi! Queria marcar uma consulta. Sou Ana Souza, nasci em 12/04/1990, tenho Unimed Flex. Pode me cadastrar."

// -- Waiting -----------------------------------------------------------------------

/// Wait until `ready` holds, checking every 25 ms, at most `within` ms.
pub fn eventually(within: Int, ready: fn() -> Bool) -> Bool {
  case ready() {
    True -> True
    False if within <= 0 -> False
    False -> {
      process.sleep(25)
      eventually(within - 25, ready)
    }
  }
}

/// The occurrence a message admitted, read on the pool.
pub fn read(
  env: Env,
  message_id: String,
) -> Result(Occurrence(Registration), decisions.Refusal) {
  decisions.read(env.app.desk, env.app.db, occurrence: domain.key(message_id))
}

/// Wait until the message's occurrence has a status named `status`.
pub fn await_status(
  env: Env,
  message_id: String,
  status: String,
) -> Occurrence(Registration) {
  let reached =
    eventually(8000, fn() {
      case read(env, message_id) {
        Ok(known) -> occurrence.status_name(known.status) == status
        Error(_) -> False
      }
    })
  let assert Ok(known) = read(env, message_id)
  case reached {
    True -> known
    False ->
      panic as {
        "expected "
        <> status
        <> ", the occurrence is "
        <> occurrence.status_name(known.status)
      }
  }
}

/// Deliver a message and wait until its registration waits for a verdict.
pub fn arrive(env: Env, message: Inbound) -> Occurrence(Registration) {
  let assert Ok(_) = app.admit(env.app, message)
  await_status(env, message.id, "awaiting")
}

/// How many rows a query counts.
pub fn count(env: Env, sql: String, parameters: List(String)) -> Int {
  let assert Ok(n) = store.count(env.app.db, sql, parameters)
  n
}

// -- The desk over HTTP --------------------------------------------------------------

pub type Answer {
  Answer(status: Int, body: String)
}

pub fn client() -> http_gun.Client {
  let assert Ok(client) =
    http_gun.start(
      http_config.default()
      |> http_config.with_destination(destination.loopback_only()),
    )
  client
}

/// Call the desk with a staff member's bearer token (`felipe`, `marta`,
/// `bia`), or anonymously with `""`.
pub fn call(
  env: Env,
  method: http.Method,
  path: String,
  as_validator: String,
  body: String,
) -> Answer {
  let headers = case as_validator {
    "" -> []
    token -> [#("authorization", "Bearer " <> token)]
  }
  send(env, method, path, headers, body)
}

/// One request to the application with exactly these headers.
pub fn send(
  env: Env,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Answer {
  let http = client()
  let assert Ok(req) = request.to(app.base_url(env.app) <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  let req =
    list.fold(headers, req, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  let assert Ok(reply) = http_gun.send(http, req)
  http_gun.stop(http)
  Answer(
    status: reply.response.status,
    body: bit_array.to_string(reply.response.body) |> result.unwrap(""),
  )
}

/// Deliver a webhook body as the messaging channel does: signed with the
/// channel's secret.
pub fn deliver(env: Env, body: String) -> Answer {
  send(
    env,
    http.Post,
    "/inbound",
    [
      #(
        access.signature_header,
        access.sign(channel(), bit_array.from_string(body)),
      ),
    ],
    body,
  )
}

/// The bearer tokens of the test clinic's staff: Felipe and Bia at
/// reception, Marta the manager.
pub const felipe = "felipe-test-token-4f0c2a9d6e1b7c35"

pub const bia = "bia-test-token-91d7e3a05c2f8b46aa"

pub const marta = "marta-test-token-c8a1f47e2d905b63"

fn staff() -> access.Staff {
  let assert Ok(staff) =
    access.staff([
      #(felipe, domain.validator("felipe", [domain.reception])),
      #(bia, domain.validator("bia", [domain.reception])),
      #(marta, domain.validator("marta", [domain.manager])),
    ])
  staff
}

/// The secret the test channel signs with.
pub fn channel() -> access.ChannelSecret {
  let assert Ok(secret) =
    access.channel_secret("test-channel-secret-7b2e9c41d08f5a36")
  secret
}

/// Open a card over HTTP and return its ticket's `seen` with the document.
pub fn open(
  env: Env,
  occurrence: String,
  as_validator: String,
) -> #(Int, String) {
  let answer =
    call(env, http.Post, "/cards/" <> occurrence <> "/open", as_validator, "")
  let assert 200 = answer.status
  let assert Ok(seen) =
    json.parse(answer.body, decode.at(["card", "seen"], decode.int))
  #(seen, answer.body)
}

/// Give a verdict over HTTP on the card shown at `seen`.
pub fn verdict(
  env: Env,
  occurrence: String,
  as_validator: String,
  seen: Int,
  verdict: String,
) -> Answer {
  call(
    env,
    http.Post,
    "/cards/" <> occurrence <> "/verdict",
    as_validator,
    "{\"seen\":" <> int.to_string(seen) <> ",\"verdict\":" <> verdict <> "}",
  )
}

/// A field of a JSON answer.
pub fn field(
  body: String,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(value) = json.parse(body, decode.at(path, decoder))
  value
}

/// The occurrence's status name, or `"absent"`.
pub fn status_of(env: Env, message_id: String) -> String {
  case read(env, message_id) {
    Ok(known) -> occurrence.status_name(known.status)
    Error(_) -> "absent"
  }
}

/// Run `work` in `count` processes released at once, and collect their
/// results in any order.
pub fn race(count: Int, work: fn(Int) -> a) -> List(a) {
  let results = process.new_subject()
  let ready = process.new_subject()
  let indexes = int.range(from: count - 1, to: -1, with: [], run: list.prepend)
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

/// How many registrations the record holds, from the heads.
pub fn registrations(env: Env) -> Int {
  let assert Ok(page) =
    queue.occurrences_of(
      env.app.db,
      point: domain.point_name,
      limit: 1000,
      after: None,
    )
  list.length(page)
}

/// A number as text.
pub fn show(n: Int) -> String {
  int.to_string(n)
}

/// The same clinic `minutes` later: the application restarts with its
/// store's clock that much ahead, and the wake-ups due by then (the end of
/// an undo window, an escalation) are delivered through the wake worker's
/// own code path. Returns the restarted environment and how many were
/// delivered.
pub fn later(env: Env, minutes: Int) -> #(Env, Int) {
  let later =
    restart(env, fn(config) {
      app.Config(..config, clock_offset: duration.minutes(minutes))
    })
  let assert Ok(delivered) =
    decisions_postgres.deliver_due(
      later.app.records,
      later.app.db,
      [decisions.waker(later.app.desk)],
      limit: 50,
    )
  #(later, delivered)
}

/// Start the scripted providers and a fresh database, run `body` with an
/// application booted on them, and stop whatever application `body`
/// returns: for tests that restart the application.
pub fn with_restarts(body: fn(Env) -> Env) -> Nil {
  quiet_pool_shutdown()
  let assert Ok(services) = scripted.start()
  let first = boot(services, fresh_database(), fn(config) { config })
  let last = body(first)
  app.stop(last.app)
  scripted.stop(services)
}

/// Run `body` on a pool of its own over `url`, closed afterwards.
pub fn with_pool(url: String, body: fn(pog.Connection) -> a) -> Nil {
  let assert Ok(config) = pog.url_config(process.new_name("clinic_side"), url)
  let assert Ok(#(Nil, pool)) =
    owner.start(fn() {
      let assert Ok(started) = pog.start(pog.pool_size(config, 1))
      let _ = body(started.data)
      Ok(Nil)
    })
  owner.stop(pool)
}
