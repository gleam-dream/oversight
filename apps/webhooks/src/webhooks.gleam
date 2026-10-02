//// `gleam run` (with DATABASE_URL set): register tenant endpoints over HTTP,
//// publish events, let grind deliver them through http_gun, and print what
//// happened, including one delivery's telemetry trace across packages.

import envoy
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import grind/job
import grind/postgres
import grind/queue
import http_gun
import http_gun/config
import http_gun/destination
import mist
import webhooks/attempt
import webhooks/delivery
import webhooks/egress
import webhooks/receiver
import webhooks/service
import webhooks/signing
import webhooks/telemetry
import webhooks/web
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  case envoy.get("DATABASE_URL") {
    Error(Nil) ->
      io.println(
        "DATABASE_URL is not set. Run: ../scripts/with-postgres.sh gleam run",
      )
    Ok(url) -> run(url)
  }
}

/// Simulated DNS for the public tier: `rebind.acme.test` answers with one
/// public and one private address, the shape of a DNS-rebinding attack.
pub fn simulated_dns(
  host: String,
  _remaining_ms: Int,
) -> Result(List(destination.Address), Nil) {
  case host {
    "rebind.acme.test" ->
      Ok([destination.Ipv4(93, 184, 216, 34), destination.Ipv4(10, 0, 0, 7)])
    "metadata.acme.test" -> Ok([destination.Ipv4(169, 254, 169, 254)])
    _ -> Error(Nil)
  }
}

fn run(url: String) -> Nil {
  wisp.set_logger_level(wisp.ErrorLevel)
  let options =
    service.Options(
      ..service.options(url),
      plan: delivery.Plan(max_attempts: 3, backoff: attempt.Backoff(200, 2000)),
      egress: egress.Settings(
        ..egress.default_settings(),
        public_resolver: Some(simulated_dns),
      ),
    )
  let assert Ok(svc) = service.start(options)
  let rx = receiver.start()
  let api = start_api(svc.context)
  // The operator's own client for calling the API: a third policy.
  let assert Ok(admin) =
    http_gun.start(config.default() |> config.allow_loopback)
  io.println("== webhooks: grind + http_gun + sinal on wisp/mist/pog ==")
  io.println(
    "API on 127.0.0.1:"
    <> int.to_string(api)
    <> ", receiver on 127.0.0.1:"
    <> int.to_string(receiver.port(rx)),
  )

  io.println("\n-- registering endpoints")
  let ops_paths = ["/ok", "/flaky", "/busy", "/gone", "/big"]
  let ops_subs =
    list.map(ops_paths, fn(path) {
      #(path, register(admin, api, "ops", receiver.url(rx, path)))
    })
  let down = register(admin, api, "ops", "http://127.0.0.1:1/down")
  let _ =
    register(admin, api, "acme", "https://169.254.169.254/latest/meta-data")
  let _ = register(admin, api, "acme", "http://hooks.acme.example/hook")
  let _ =
    register(
      admin,
      api,
      "acme",
      "https://127.0.0.1:" <> int.to_string(receiver.port(rx)) <> "/ok",
    )
  let rebind = register(admin, api, "acme", "https://rebind.acme.test/hook")
  let secrets =
    [#("/down", down), #("rebind", rebind), ..ops_subs]
    |> list.filter_map(fn(entry) {
      case entry.1 {
        Ok(#(id, secret)) -> Ok(#(id, #(entry.0, secret)))
        Error(_) -> Error(Nil)
      }
    })
    |> dict.from_list

  io.println("\n-- publishing events")
  let ops_jobs = publish(admin, api, "ops", "order.created", "{\"order\":42}")
  let acme_jobs = publish(admin, api, "acme", "invoice.paid", "{\"invoice\":7}")
  let published = list.append(ops_jobs, acme_jobs)

  let consumer =
    service.start_consumer(
      svc,
      queue.default_policy()
        |> queue.with_poll_interval(50)
        |> queue.with_maximum_concurrency(4),
    )
  let outcomes = await_outcomes(svc, published, 100)
  let assert Ok(_) = queue.stop(consumer)

  io.println("\n-- outcomes")
  list.each(outcomes, fn(entry) {
    let #(delivery_id, outcome) = entry
    let sub_id = case string.split(delivery_id, ":") {
      [_, sub] -> sub
      _ -> delivery_id
    }
    let label = case dict.get(secrets, sub_id) {
      Ok(#(path, _)) -> path
      Error(Nil) -> sub_id
    }
    let attempts = case
      get_json(admin, api, "/deliveries/" <> delivery_id, {
        use attempts <- decode.field("attempts", decode.int)
        use note <- decode.field("last_note", decode.optional(decode.string))
        decode.success(#(attempts, option.unwrap(note, "")))
      })
    {
      Ok(#(n, note)) -> int.to_string(n) <> " attempt(s), last: " <> note
      Error(_) -> "?"
    }
    io.println(
      "  "
      <> string.pad_end(label, 8, " ")
      <> describe_outcome(outcome)
      <> "  ["
      <> attempts
      <> "]",
    )
  })
  let rebind_status = case rebind {
    Ok(#(id, _)) ->
      get_json(
        admin,
        api,
        "/subscriptions/" <> id,
        decode.at(["status"], decode.string),
      )
      |> result.unwrap("?")
    Error(_) -> "?"
  }
  io.println("  acme rebind subscription is now: " <> rebind_status)

  io.println("\n-- what the receiver saw")
  let seen = receiver.received(rx)
  let verified = list.count(seen, fn(r) { verify(r, secrets) })
  io.println(
    "  "
    <> int.to_string(list.length(seen))
    <> " requests, "
    <> int.to_string(verified)
    <> " with a valid signature; idempotency keys: "
    <> {
      seen
      |> list.filter_map(fn(r) { list.key_find(r.headers, signing.id_header) })
      |> list.unique
      |> list.length
      |> int.to_string
    }
    <> " distinct",
  )

  io.println("\n-- telemetry trace for the /flaky delivery")
  process.sleep(100)
  case list.find(outcomes, fn(e) { label_is(e.0, secrets, "/flaky") }) {
    Ok(#(delivery_id, _)) ->
      telemetry.trace(svc.collector, delivery_id)
      |> list.filter(fn(l) { l.name != "grind.diag.renewal" })
      |> list.each(fn(l) { io.println("  " <> telemetry.format(l)) })
    Error(Nil) -> Nil
  }
  let all = telemetry.lines(svc.collector)
  io.println(
    "  (collected "
    <> int.to_string(list.length(all))
    <> " events; "
    <> int.to_string(list.count(all, fn(l) { l.key == telemetry.Unkeyed }))
    <> " could not be attributed to a delivery)",
  )

  let _ = http_gun.stop(admin)
  service.stop(svc)
  io.println("\ndone.")
}

fn label_is(delivery_id: String, secrets, path: String) -> Bool {
  case string.split(delivery_id, ":") {
    [_, sub] ->
      case dict.get(secrets, sub) {
        Ok(#(p, _)) -> p == path
        Error(Nil) -> False
      }
    _ -> False
  }
}

fn verify(r: receiver.Received, secrets) -> Bool {
  let header = fn(name) { list.key_find(r.headers, name) }
  case
    header(signing.id_header),
    header(signing.timestamp_header),
    header(signing.signature_header)
  {
    Ok(id), Ok(ts), Ok(signature) ->
      case string.split(id, ":"), int.parse(ts) {
        [_, sub], Ok(ts) ->
          case dict.get(secrets, sub) {
            Ok(#(_, secret)) ->
              signing.verify(secret, id, ts, r.body, signature)
            Error(Nil) -> False
          }
        _, _ -> False
      }
    _, _, _ -> False
  }
}

fn describe_outcome(
  outcome: job.Outcome(attempt.Receipt, attempt.DeliveryError),
) -> String {
  case outcome {
    job.SucceededWith(receipt) ->
      "delivered "
      <> int.to_string(receipt.status)
      <> case receipt.body {
        attempt.BodyOverLimit(limit) ->
          " (body over " <> int.to_string(limit) <> "-byte read limit, ignored)"
        _ -> ""
      }
    job.BusinessFailedWithCause(e, cause) ->
      "failed: "
      <> attempt.describe_error(e)
      <> " ("
      <> string.inspect(cause)
      <> ")"
    job.BusinessFailedWith(e) -> "failed: " <> attempt.describe_error(e)
    job.DiscardedWithReason(reason) -> "discarded: " <> reason
    job.Pending(state) -> "pending (" <> string.inspect(state) <> ")"
    other -> string.inspect(other)
  }
}

fn await_outcomes(
  svc: service.Service,
  published: List(#(String, Int)),
  tries: Int,
) -> List(#(String, job.Outcome(attempt.Receipt, attempt.DeliveryError))) {
  let outcomes =
    list.map(published, fn(entry) {
      let assert Ok(handle) =
        postgres.bind_handle(svc.jobs, svc.worker, entry.1)
      let assert Ok(outcome) = postgres.outcome(svc.jobs, handle)
      #(entry.0, outcome)
    })
  let settled =
    list.all(outcomes, fn(e) {
      case e.1 {
        job.Pending(_) -> False
        _ -> True
      }
    })
  case settled || tries == 0 {
    True -> outcomes
    False -> {
      process.sleep(100)
      await_outcomes(svc, published, tries - 1)
    }
  }
}

fn start_api(context: web.Context) -> Int {
  let ports = process.new_subject()
  let assert Ok(_) =
    wisp_mist.handler(
      web.handle(_, context),
      "development-secret-key-base-0123456789",
    )
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 1000)
  port
}

fn call(
  admin: http_gun.Client,
  port: Int,
  method: http.Method,
  path: String,
  body: String,
) -> Result(#(Int, String), String) {
  let req =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_port(port)
    |> request.set_method(method)
    |> request.set_path(path)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  case http_gun.send(admin, req) {
    Ok(buffered) ->
      Ok(#(
        buffered.response.status,
        bit_array.to_string(buffered.response.body) |> result.unwrap(""),
      ))
    Error(failure) -> Error(attempt.failure_name(failure.reason))
  }
}

fn get_json(admin, port, path, decoder) {
  case call(admin, port, http.Get, path, "") {
    Ok(#(200, text)) -> json.parse(text, decoder) |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

fn register(admin, port, tenant: String, url: String) {
  let body =
    json.object([#("tenant", json.string(tenant)), #("url", json.string(url))])
    |> json.to_string
  case call(admin, port, http.Post, "/subscriptions", body) {
    Ok(#(201, text)) -> {
      let assert Ok(pair) =
        json.parse(text, {
          use id <- decode.field("id", decode.string)
          use secret <- decode.field("secret", decode.string)
          decode.success(#(id, secret))
        })
      io.println("  201 " <> tenant <> " " <> url <> " -> " <> pair.0)
      Ok(pair)
    }
    Ok(#(status, text)) -> {
      io.println(
        "  "
        <> int.to_string(status)
        <> " "
        <> tenant
        <> " "
        <> url
        <> " "
        <> text,
      )
      Error(Nil)
    }
    Error(reason) -> {
      io.println("  !! " <> reason)
      Error(Nil)
    }
  }
}

fn publish(admin, port, tenant: String, event_type: String, data: String) {
  let body =
    "{\"tenant\":\""
    <> tenant
    <> "\",\"type\":\""
    <> event_type
    <> "\",\"data\":"
    <> data
    <> "}"
  case call(admin, port, http.Post, "/events", body) {
    Ok(#(202, text)) -> {
      let assert Ok(deliveries) =
        json.parse(
          text,
          decode.at(
            ["deliveries"],
            decode.list({
              use d <- decode.field("delivery_id", decode.string)
              use j <- decode.field("job_id", decode.int)
              decode.success(#(d, j))
            }),
          ),
        )
      io.println(
        "  202 "
        <> tenant
        <> " "
        <> event_type
        <> " -> "
        <> int.to_string(list.length(deliveries))
        <> " delivery job(s)",
      )
      deliveries
    }
    other -> {
      io.println("  publish failed: " <> string.inspect(other))
      []
    }
  }
}
