//// The tenant-facing API (wisp): register endpoints and publish events.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import grind
import grind/job
import grind/worker.{type Worker}
import pog
import sinal/correlation
import webhooks/attempt.{type Delivery, type DeliveryError, type Receipt}
import webhooks/store
import webhooks/subscription.{type Tier}
import wisp.{type Request, type Response}

pub type Context {
  Context(
    db: pog.Connection,
    jobs: grind.Grind,
    worker: Worker(Delivery, Receipt, DeliveryError),
    tenants: Dict(String, Tier),
    internal_hosts: List(String),
  )
}

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    http.Post, ["subscriptions"] -> create_subscription(req, ctx)
    http.Get, ["subscriptions", id] -> show_subscription(ctx, id)
    http.Post, ["events"] -> publish_event(req, ctx)
    http.Get, ["deliveries", id] -> show_delivery(ctx, id)
    _, ["subscriptions"] | _, ["events"] -> wisp.method_not_allowed([http.Post])
    _, _ -> wisp.not_found()
  }
}

fn error_json(status: Int, message: String) -> Response {
  json.object([#("error", json.string(message))])
  |> json.to_string
  |> wisp.json_response(status)
}

fn create_subscription(req: Request, ctx: Context) -> Response {
  use body <- wisp.require_json(req)
  let decoder = {
    use tenant <- decode.field("tenant", decode.string)
    use url <- decode.field("url", decode.string)
    decode.success(#(tenant, url))
  }
  case decode.run(body, decoder) {
    Error(_) -> error_json(400, "expected {tenant, url}")
    Ok(#(tenant, url)) ->
      case dict.get(ctx.tenants, tenant) {
        Error(Nil) -> error_json(404, "unknown tenant")
        Ok(tier) ->
          case subscription.validate_endpoint(url, tier, ctx.internal_hosts) {
            Error(e) -> error_json(422, subscription.endpoint_error_message(e))
            Ok(_) -> {
              let sub =
                subscription.Subscription(
                  id: "sub_" <> token(6),
                  tenant:,
                  url:,
                  secret: "whsec_" <> token(24),
                  status: subscription.Active,
                )
              case store.insert_subscription(ctx.db, sub) {
                Error(_) -> error_json(503, "storage unavailable")
                Ok(Nil) ->
                  json.object([
                    #("id", json.string(sub.id)),
                    #("secret", json.string(sub.secret)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(201)
              }
            }
          }
      }
  }
}

fn show_subscription(ctx: Context, id: String) -> Response {
  case store.get_subscription(ctx.db, id) {
    Error(store.NotFound) -> wisp.not_found()
    Error(_) -> error_json(503, "storage unavailable")
    Ok(sub) ->
      json.object([
        #("id", json.string(sub.id)),
        #("tenant", json.string(sub.tenant)),
        #("url", json.string(sub.url)),
        #("status", case sub.status {
          subscription.Active -> json.string("active")
          subscription.Disabled(reason) -> json.string("disabled: " <> reason)
        }),
      ])
      |> json.to_string
      |> wisp.json_response(200)
  }
}

pub type Published {
  Published(delivery_id: String, job_id: Int)
}

pub type PublishError {
  UnknownTenant
  StorageFailed
  AdmissionFailed(delivery_id: String)
}

/// Fan an event out: one grind job per active subscription. Each job is
/// admitted with a deterministic id (`event:subscription`), so a publisher
/// retrying the same event id converges on the same jobs, and in the same
/// transaction as its delivery row. The job carries the delivery's
/// correlation into the worker and every grind event.
pub fn publish(
  ctx: Context,
  tenant: String,
  event_id: String,
  event_type: String,
  body: String,
) -> Result(List(Published), PublishError) {
  use _tier <- result.try(
    dict.get(ctx.tenants, tenant) |> result.replace_error(UnknownTenant),
  )
  use subs <- result.try(
    store.active_for_tenant(ctx.db, tenant)
    |> result.replace_error(StorageFailed),
  )
  list.try_map(subs, fn(sub) {
    let delivery_id = event_id <> ":" <> sub.id
    let delivery =
      attempt.Delivery(
        delivery_id:,
        event_id:,
        event_type:,
        tenant:,
        subscription_id: sub.id,
        body:,
      )
    let delivery_job =
      job.new(ctx.worker, delivery)
      |> job.with_id(delivery_id)
      |> job.with_correlation(correlation.from_key(delivery_id))
    pog.transaction(ctx.db, fn(tx) {
      case grind.submit_in(ctx.jobs, tx, delivery_job) {
        Ok(grind.Inserted(handle)) -> {
          let job_id = job.id(handle)
          store.record_delivery(tx, delivery_id, event_id, sub.id, job_id)
          |> result.replace(Published(delivery_id, job_id))
          |> result.replace_error(StorageFailed)
        }
        // A resubmit converges on the job that holds the id; its delivery
        // row was written with it.
        Ok(admission) ->
          Ok(Published(delivery_id, job.id(grind.handle(admission))))
        Error(_) -> Error(AdmissionFailed(delivery_id))
      }
    })
    |> result.map_error(fn(e) {
      case e {
        pog.TransactionRolledBack(e) -> e
        pog.TransactionQueryError(_) -> AdmissionFailed(delivery_id)
      }
    })
  })
}

fn publish_event(req: Request, ctx: Context) -> Response {
  use raw <- wisp.require_bit_array_body(req)
  let decoder = {
    use tenant <- decode.field("tenant", decode.string)
    use event_type <- decode.field("type", decode.string)
    use id <- decode.optional_field("id", None, decode.optional(decode.string))
    use _data <- decode.field("data", decode.dynamic)
    decode.success(#(tenant, event_type, id))
  }
  case json.parse_bits(raw, decoder), bit_array.to_string(raw) {
    Ok(#(tenant, event_type, id)), Ok(text) -> {
      let event_id = option.lazy_unwrap(id, fn() { "evt_" <> token(8) })
      case publish(ctx, tenant, event_id, event_type, text) {
        Error(UnknownTenant) -> error_json(404, "unknown tenant")
        Error(StorageFailed) -> error_json(503, "storage unavailable")
        Error(AdmissionFailed(d)) ->
          error_json(503, "job admission failed for " <> d)
        Ok(published) ->
          json.object([
            #("event_id", json.string(event_id)),
            #(
              "deliveries",
              json.array(published, fn(p) {
                json.object([
                  #("delivery_id", json.string(p.delivery_id)),
                  #("job_id", json.int(p.job_id)),
                ])
              }),
            ),
          ])
          |> json.to_string
          |> wisp.json_response(202)
      }
    }
    _, _ -> error_json(400, "expected {tenant, type, id?, data}")
  }
}

fn show_delivery(ctx: Context, id: String) -> Response {
  case store.get_delivery(ctx.db, id) {
    Error(store.NotFound) -> wisp.not_found()
    Error(_) -> error_json(503, "storage unavailable")
    Ok(row) ->
      json.object([
        #("id", json.string(row.id)),
        #("job_id", json.int(row.job_id)),
        #("attempts", json.int(row.attempts)),
        #("last_status", json.nullable(row.last_status, json.int)),
        #("last_note", json.nullable(row.last_note, json.string)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
  }
}

fn token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}
