import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/time/duration.{type Duration}
import grind
import grind/testing
import http_gun/destination
import pog
import webhooks/attempt
import webhooks/delivery
import webhooks/egress
import webhooks/service.{type Service}
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

pub fn options() -> service.Options {
  let url = case envoy.get("DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) ->
      panic as "DATABASE_URL is not set; run ../scripts/with-postgres.sh gleam test"
  }
  service.Options(
    ..service.options(url),
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

/// POST /subscriptions through the wisp handler.
pub fn subscribe(
  svc: Service,
  tenant: String,
  url: String,
) -> Result(#(String, String), #(Int, String)) {
  let response =
    simulate.request(http.Post, "/subscriptions")
    |> simulate.json_body(
      json.object([#("tenant", json.string(tenant)), #("url", json.string(url))]),
    )
    |> web.handle(svc.context)
  let body = simulate.read_body(response)
  case response.status {
    201 -> {
      let assert Ok(pair) =
        json.parse(body, {
          use id <- decode.field("id", decode.string)
          use secret <- decode.field("secret", decode.string)
          decode.success(#(id, secret))
        })
      Ok(pair)
    }
    status -> Error(#(status, body))
  }
}

/// POST /events through the wisp handler; returns (delivery id, job id).
pub fn publish(svc: Service, raw: String) -> List(#(String, Int)) {
  let response =
    simulate.request(http.Post, "/events")
    |> simulate.string_body(raw)
    |> simulate.header("content-type", "application/json")
    |> web.handle(svc.context)
  assert response.status == 202
  let assert Ok(deliveries) =
    json.parse(
      simulate.read_body(response),
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

/// grind's observations go through its forwarder and need a moment to land.
pub fn settle() -> Nil {
  process.sleep(150)
}

@external(erlang, "webhooks_ffi", "unique_int")
pub fn unique_int() -> Int
