import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import grind
import grind/testing
import http_gun
import http_gun/config
import http_gun/destination
import pog
import webhooks/attempt
import webhooks/delivery
import webhooks/egress
import webhooks/service.{type Service}
import webhooks/subscription
import webhooks/tenant.{type Tenant, Tenant}
import webhooks/web
import wisp/simulate

/// Simulated DNS.
pub fn test_dns(
  host: String,
  _remaining: Duration,
) -> Result(List(destination.Address), Nil) {
  case host {
    // A rebinding-style answer: one public and one private address.
    "rebind.acme.test" ->
      Ok([destination.Ipv4(93, 184, 216, 34), destination.Ipv4(10, 0, 0, 7)])
    _ -> Error(Nil)
  }
}

/// The test tenants; each one's key is `key(name)`.
pub fn tenants() -> List(Tenant) {
  [
    Tenant("acme", subscription.PublicTier, key("acme")),
    Tenant("globex", subscription.PublicTier, key("globex")),
    Tenant("ops", subscription.InternalTier, key("ops")),
  ]
}

pub fn key(tenant: String) -> String {
  "whk_test_" <> tenant
}

pub fn bearer(tenant: String) -> Option(String) {
  Some("Bearer " <> key(tenant))
}

pub fn options() -> service.Options {
  let url = case envoy.get("DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) ->
      panic as "DATABASE_URL is not set; run ../scripts/with-postgres.sh gleam test"
  }
  service.Options(
    ..service.options(url, tenants()),
    queue: "webhooks_" <> int.to_string(unique_int()),
    plan: delivery.Plan(
      ..delivery.default_plan(),
      max_attempts: 3,
      backoff: attempt.Backoff(0, 0),
    ),
    egress: egress.Settings(
      ..egress.default_settings(),
      resolver: Some(test_dns),
    ),
    consumers: False,
  )
}

/// Reads a delivery job back from the id the API handed out.
pub fn outcome(
  svc: Service,
  id: Int,
) -> Result(
  grind.Outcome(attempt.Receipt, attempt.DeliveryError),
  grind.ReadError,
) {
  use handle <- result.try(grind.bind(svc.jobs, svc.worker, id))
  grind.outcome(svc.jobs, handle)
}

/// Runs the service queue's due jobs, one at a time, until none is due.
pub fn drain(svc: Service) -> Result(Int, testing.DrainError) {
  drain_up_to(svc, 50)
}

pub fn drain_up_to(
  svc: Service,
  limit: Int,
) -> Result(Int, testing.DrainError) {
  testing.drain(
    svc.jobs,
    queue: svc.queue,
    limit:,
    within: duration.seconds(20),
  )
}

pub fn with_service(options: service.Options, run: fn(Service) -> a) -> a {
  let assert Ok(svc) = service.start(options)
  // Tests share one database; app tables start empty for each test.
  let assert Ok(_) =
    pog.query("TRUNCATE webhook_subscriptions, webhook_deliveries")
    |> pog.execute(svc.db)
  let result = run(svc)
  service.stop(svc)
  result
}

/// One request through the wisp handler, with an optional `Authorization`
/// header; returns the status and body.
pub fn call(
  svc: Service,
  method: http.Method,
  path: String,
  authorization: Option(String),
  body: String,
) -> #(Int, String) {
  let req =
    simulate.request(method, path)
    |> simulate.string_body(body)
    |> simulate.header("content-type", "application/json")
  let req = case authorization {
    Some(value) -> simulate.header(req, "authorization", value)
    None -> req
  }
  let response = web.handle(req, svc.context)
  #(response.status, simulate.read_body(response))
}

/// POST /subscriptions as `tenant`, authenticated by its key.
pub fn subscribe(
  svc: Service,
  tenant: String,
  url: String,
) -> Result(#(String, String), #(Int, String)) {
  let body = json.object([#("url", json.string(url))]) |> json.to_string
  case call(svc, http.Post, "/subscriptions", bearer(tenant), body) {
    #(201, body) -> {
      let assert Ok(pair) =
        json.parse(body, {
          use id <- decode.field("id", decode.string)
          use secret <- decode.field("secret", decode.string)
          decode.success(#(id, secret))
        })
      Ok(pair)
    }
    other -> Error(other)
  }
}

/// POST /events as `tenant`; returns (delivery id, job id).
pub fn publish(
  svc: Service,
  tenant: String,
  raw: String,
) -> List(#(String, Int)) {
  let #(status, body) = call(svc, http.Post, "/events", bearer(tenant), raw)
  assert status == 202
  deliveries(body)
}

/// The (delivery id, job id) pairs of a 202 `/events` answer.
pub fn deliveries(body: String) -> List(#(String, Int)) {
  let assert Ok(deliveries) =
    json.parse(
      body,
      decode.at(
        ["deliveries"],
        decode.list({
          use d <- decode.field("delivery_id", decode.string)
          use j <- decode.field("job_id", decode.int)
          decode.success(#(d, j))
        }),
      ),
    )
  deliveries
}

/// POSTs `body` to a loopback server on `port` and returns the status.
pub fn post(
  port: Int,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Int {
  let assert Ok(client) =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
    )
    |> config.without_observations
    |> http_gun.start
  let req =
    list.fold(
      headers,
      request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(http.Http)
        |> request.set_host("127.0.0.1")
        |> request.set_port(port)
        |> request.set_path(path)
        |> request.set_body(body),
      // A recorded request's framing headers are the client's to set.
      fn(req, header) {
        case header.0 {
          "host" | "content-length" | "connection" -> req
          name -> request.set_header(req, name, header.1)
        }
      },
    )
  let assert Ok(sent) = http_gun.send(client, req)
  http_gun.stop(client)
  sent.response.status
}

/// grind's observations go through its forwarder and need a moment to land.
pub fn settle() -> Nil {
  process.sleep(150)
}

@external(erlang, "webhooks_ffi", "unique_int")
pub fn unique_int() -> Int
