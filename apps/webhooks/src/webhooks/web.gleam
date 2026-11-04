//// The tenant-facing API (wisp): register endpoints and publish events.
////
//// Every route authenticates the caller with `Authorization: Bearer <key>`
//// and acts for the tenant that key belongs to; see `webhooks/tenant`.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grind
import grind/job
import grind/worker.{type Worker}
import pog
import sinal/correlation
import webhooks/attempt.{type Delivery, type DeliveryError, type Receipt}
import webhooks/store
import webhooks/subscription
import webhooks/tenant.{type Tenant}
import wisp.{type Request, type Response}

pub type Context {
  Context(
    db: pog.Connection,
    jobs: grind.Grind,
    worker: Worker(Delivery, Receipt, DeliveryError),
    tenants: List(Tenant),
    internal_hosts: List(String),
  )
}

pub fn handle(req: Request, ctx: Context) -> Response {
  use <- wisp.rescue_crashes
  case req.method, wisp.path_segments(req) {
    http.Post, ["subscriptions"] -> {
      use tenant <- require_tenant(req, ctx)
      create_subscription(req, ctx, tenant)
    }
    http.Get, ["subscriptions", id] -> {
      use tenant <- require_tenant(req, ctx)
      show_subscription(ctx, tenant, id)
    }
    http.Post, ["events"] -> {
      use tenant <- require_tenant(req, ctx)
      publish_event(req, ctx, tenant)
    }
    http.Get, ["deliveries", id] -> {
      use tenant <- require_tenant(req, ctx)
      show_delivery(ctx, tenant, id)
    }
    _, ["subscriptions"] | _, ["events"] -> wisp.method_not_allowed([http.Post])
    _, _ -> wisp.not_found()
  }
}

/// The caller's tenant, from `Authorization: Bearer <key>`, or 401. No route
/// takes a tenant from its body or path.
fn require_tenant(
  req: Request,
  ctx: Context,
  next: fn(Tenant) -> Response,
) -> Response {
  case
    tenant.authenticate(ctx.tenants, request.get_header(req, "authorization"))
  {
    Ok(tenant) -> next(tenant)
    Error(Nil) ->
      error_json(401, "a tenant API key is required")
      |> wisp.set_header("www-authenticate", "Bearer")
  }
}

fn error_json(status: Int, message: String) -> Response {
  json.object([#("error", json.string(message))])
  |> json.to_string
  |> wisp.json_response(status)
}

/// Decodes `True` when the body has a `tenant` field. The API key names the
/// tenant, so a body that also names one is refused rather than ignored.
fn names_tenant() -> decode.Decoder(Bool) {
  decode.optional_field("tenant", False, decode.success(True), decode.success)
}

fn create_subscription(req: Request, ctx: Context, tenant: Tenant) -> Response {
  use body <- wisp.require_json(req)
  let decoder = {
    use names_tenant <- decode.then(names_tenant())
    use url <- decode.field("url", decode.string)
    decode.success(#(names_tenant, url))
  }
  case decode.run(body, decoder) {
    Error(_) -> error_json(400, "expected {url}")
    Ok(#(True, _)) ->
      error_json(400, "the API key names the tenant; remove `tenant`")
    Ok(#(False, url)) ->
      case
        subscription.validate_endpoint(url, tenant.tier, ctx.internal_hosts)
      {
        Error(e) -> error_json(422, subscription.endpoint_error_message(e))
        Ok(_) -> {
          let sub =
            subscription.Subscription(
              id: "sub_" <> token(6),
              tenant: tenant.name,
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

/// Another tenant's subscription answers 404, the same as a missing one.
fn show_subscription(ctx: Context, tenant: Tenant, id: String) -> Response {
  case store.get_subscription(ctx.db, id) {
    Error(store.QueryFailed(_)) -> error_json(503, "storage unavailable")
    Error(store.NotFound) -> wisp.not_found()
    Ok(sub) if sub.tenant != tenant.name -> wisp.not_found()
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
  tenant: Tenant,
  event_id: EventId,
  event_type: String,
  body: String,
) -> Result(List(Published), PublishError) {
  let event_id = event_id_to_string(event_id)
  use subs <- result.try(
    store.active_for_tenant(ctx.db, tenant.name)
    |> result.replace_error(StorageFailed),
  )
  list.try_map(subs, fn(sub) {
    let delivery_id = event_id <> ":" <> sub.id
    let delivery =
      attempt.Delivery(
        delivery_id:,
        event_id:,
        event_type:,
        tenant: tenant.name,
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

/// A validated event id: 1 to 64 characters of `A-Z`, `a-z`, `0-9`, `_`
/// and `-`. It becomes part of the delivery id, the Grind job id and the
/// `webhook-id` header, whose `event:subscription` shape needs it free of
/// `:` and whitespace.
pub opaque type EventId {
  EventId(String)
}

pub const max_event_id_length = 64

pub fn event_id(candidate: String) -> Result(EventId, Nil) {
  let length = string.length(candidate)
  let allowed =
    string.to_utf_codepoints(candidate)
    |> list.all(fn(codepoint) {
      case string.utf_codepoint_to_int(codepoint) {
        c if c >= 0x30 && c <= 0x39 -> True
        c if c >= 0x41 && c <= 0x5A -> True
        c if c >= 0x61 && c <= 0x7A -> True
        0x5F | 0x2D -> True
        _ -> False
      }
    })
  case length >= 1 && length <= max_event_id_length && allowed {
    True -> Ok(EventId(candidate))
    False -> Error(Nil)
  }
}

pub fn event_id_to_string(id: EventId) -> String {
  let EventId(id) = id
  id
}

/// The largest event body `POST /events` accepts, in bytes. The body is
/// stored in each delivery's job row and sent as is, so a larger one is
/// refused with 413 before anything is stored.
pub const max_event_bytes = 65_536

fn publish_event(req: Request, ctx: Context, tenant: Tenant) -> Response {
  use raw <- wisp.require_bit_array_body(wisp.set_max_body_size(
    req,
    max_event_bytes,
  ))
  let decoder = {
    use names_tenant <- decode.then(names_tenant())
    use event_type <- decode.field("type", decode.string)
    use id <- decode.optional_field("id", None, decode.optional(decode.string))
    use _data <- decode.field("data", decode.dynamic)
    decode.success(#(names_tenant, event_type, id))
  }
  case json.parse_bits(raw, decoder), bit_array.to_string(raw) {
    Ok(#(True, _, _)), _ ->
      error_json(400, "the API key names the tenant; remove `tenant`")
    Ok(#(False, event_type, id)), Ok(text) -> {
      let id = case id {
        None -> Ok(EventId("evt_" <> token(8)))
        Some(id) -> event_id(id)
      }
      case id {
        Error(Nil) ->
          error_json(
            400,
            "event id must be 1-64 characters of A-Z, a-z, 0-9, '_' or '-'",
          )
        Ok(event_id) ->
          case publish(ctx, tenant, event_id, event_type, text) {
            Error(StorageFailed) -> error_json(503, "storage unavailable")
            Error(AdmissionFailed(d)) ->
              error_json(503, "job admission failed for " <> d)
            Ok(published) ->
              json.object([
                #("event_id", json.string(event_id_to_string(event_id))),
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
    }
    _, _ -> error_json(400, "expected {type, id?, data}")
  }
}

/// Another tenant's delivery answers 404, the same as a missing one.
fn show_delivery(ctx: Context, tenant: Tenant, id: String) -> Response {
  case store.get_delivery(ctx.db, id) {
    Error(store.QueryFailed(_)) -> error_json(503, "storage unavailable")
    Error(store.NotFound) -> wisp.not_found()
    Ok(row) if row.tenant != tenant.name -> wisp.not_found()
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
