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
import gleam/time/duration.{type Duration}
import grind
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error
import mist
import webhooks/attempt
import webhooks/delivery
import webhooks/egress
import webhooks/receiver
import webhooks/service
import webhooks/signing
import webhooks/telemetry
import webhooks/tenant
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
  _remaining: Duration,
) -> Result(List(destination.Address), Nil) {
  case host {
    "rebind.acme.test" ->
      Ok([destination.Ipv4(93, 184, 216, 34), destination.Ipv4(10, 0, 0, 7)])
    "metadata.acme.test" -> Ok([destination.Ipv4(169, 254, 169, 254)])
    _ -> Error(Nil)
  }
}

/// Each demo tenant with its key from `WEBHOOKS_API_KEY_<NAME>`, or a key
/// generated for this run. A generated key is never printed.
fn tenants() -> List(tenant.Tenant) {
  list.map(service.default_tenants(), fn(entry) {
    let #(found, source) = tenant.from_environment(entry.0, entry.1)
    case source {
      tenant.FromEnvironment -> Nil
      tenant.Generated ->
        io.println(
          tenant.key_variable(found.name)
          <> " is not set; generated a key for this run",
        )
    }
    found
  })
}

fn run(url: String) -> Nil {
  wisp.set_logger_level(wisp.ErrorLevel)
  let rx = receiver.start()
  let options =
    service.Options(
      ..service.options(url, tenants()),
      plan: delivery.Plan(
        max_attempts: 3,
        backoff: attempt.Backoff(200, 2000),
        snooze: attempt.SnoozePolicy(..attempt.default_snooze(), max_snoozes: 3),
      ),
      egress: egress.Settings(
        ..egress.default_settings(),
        // The internal tier reaches the receiver's port and the dead port 1,
        // and no other loopback port.
        internal_hosts: [
          "127.0.0.1:" <> int.to_string(receiver.port(rx)),
          "127.0.0.1:1",
        ],
        resolver: Some(simulated_dns),
      ),
    )
  let assert Ok(svc) = service.start(options)
  let api = start_api(svc.context)
  // Each tenant's key, as the tenant's own application would hold it.
  let key = fn(name) {
    let assert Ok(found) = list.find(options.tenants, fn(t) { t.name == name })
    found.api_key
  }
  // The operator's own client for calling the API: loopback, this port only.
  let assert Ok(admin) =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(api)]),
    )
    |> config.without_observations
    |> http_gun.start
  io.println("== webhooks: grind + http_gun + sinal on wisp/mist/pog ==")
  io.println(
    "API on 127.0.0.1:"
    <> int.to_string(api)
    <> ", receiver on 127.0.0.1:"
    <> int.to_string(receiver.port(rx)),
  )

  io.println("\n-- registering endpoints")
  let ops_paths = ["/ok", "/flaky", "/busy", "/throttled", "/gone", "/big"]
  let ops_subs =
    list.map(ops_paths, fn(path) {
      #(path, register(admin, api, key, "ops", receiver.url(rx, path)))
    })
  let down = register(admin, api, key, "ops", "http://127.0.0.1:1/down")
  let _ = register(admin, api, key, "ops", "http://127.0.0.1:5432/hook")
  let _ =
    register(
      admin,
      api,
      key,
      "acme",
      "https://169.254.169.254/latest/meta-data",
    )
  let _ = register(admin, api, key, "acme", "http://hooks.acme.example/hook")
  let _ =
    register(
      admin,
      api,
      key,
      "acme",
      "https://127.0.0.1:" <> int.to_string(receiver.port(rx)) <> "/ok",
    )
  let rebind =
    register(admin, api, key, "acme", "https://rebind.acme.test/hook")
  // No route trusts a tenant named by the caller: without a tenant's key the
  // API answers 401.
  case
    call(
      admin,
      api,
      "not-a-tenant-key",
      http.Post,
      "/subscriptions",
      json.object([#("url", json.string("https://hooks.acme.example/hook"))])
        |> json.to_string,
    )
  {
    Ok(#(status, _)) ->
      io.println("  " <> int.to_string(status) <> " without a tenant key")
    Error(reason) -> io.println("  !! " <> reason)
  }
  let secrets =
    [#("/down", down), #("rebind", rebind), ..ops_subs]
    |> list.filter_map(fn(entry) {
      case entry.1 {
        Ok(#(id, secret)) -> Ok(#(id, #(entry.0, secret)))
        Error(_) -> Error(Nil)
      }
    })
    |> dict.from_list
  // The receiver verifies each endpoint's deliveries with that endpoint's
  // secret, as a tenant's own receiver would.
  list.each(ops_subs, fn(entry) {
    case entry.1 {
      Ok(#(_, secret)) -> receiver.trust(rx, entry.0, secret)
      Error(Nil) -> Nil
    }
  })

  io.println("\n-- publishing events")
  let ops_jobs =
    publish(admin, api, key, "ops", "order.created", "{\"order\":42}")
  let acme_jobs =
    publish(admin, api, key, "acme", "invoice.paid", "{\"invoice\":7}")
  let published =
    list.append(
      list.map(ops_jobs, fn(job) { #("ops", job) }),
      list.map(acme_jobs, fn(job) { #("acme", job) }),
    )

  let outcomes =
    list.map(published, fn(entry) {
      let #(tenant, #(delivery_id, job_id)) = entry
      let assert Ok(handle) = grind.bind(svc.jobs, svc.worker, job_id)
      let assert Ok(outcome) =
        grind.await(svc.jobs, handle, within: duration.seconds(15))
      #(delivery_id, tenant, outcome)
    })

  io.println("\n-- outcomes")
  list.each(outcomes, fn(entry) {
    let #(delivery_id, tenant, outcome) = entry
    let sub_id = case string.split(delivery_id, ":") {
      [_, sub] -> sub
      _ -> delivery_id
    }
    let label = case dict.get(secrets, sub_id) {
      Ok(#(path, _)) -> path
      Error(Nil) -> sub_id
    }
    let attempts = case
      get_json(admin, api, key(tenant), "/deliveries/" <> delivery_id, {
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
      <> string.pad_end(label, 11, " ")
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
        key("acme"),
        "/subscriptions/" <> id,
        decode.at(["status"], decode.string),
      )
      |> result.unwrap("?")
    Error(_) -> "?"
  }
  io.println("  acme rebind subscription is now: " <> rebind_status)

  io.println("\n-- what the receiver saw")
  let seen = receiver.received(rx)
  let count = fn(seen, keep) {
    list.count(seen, fn(r: receiver.Received) { keep(r.verdict) })
    |> int.to_string
  }
  io.println(
    "  "
    <> int.to_string(list.length(seen))
    <> " requests: "
    <> count(seen, is_processed)
    <> " verified and processed, "
    <> count(seen, fn(v) { v == receiver.Duplicate })
    <> " duplicate, "
    <> count(seen, fn(v) { v != receiver.Duplicate && !is_processed(v) })
    <> " rejected; idempotency keys: "
    <> {
      seen
      |> list.filter_map(fn(r) { list.key_find(r.headers, signing.id_header) })
      |> list.unique
      |> list.length
      |> int.to_string
    }
    <> " distinct",
  )
  // Replaying a captured delivery byte for byte: the receiver acknowledges
  // it as a duplicate and does not run the endpoint again.
  case list.find(seen, fn(r) { r.path == "/ok" }) {
    Ok(captured) -> {
      let status = replay(rx, captured)
      let verdict = case list.last(receiver.received(rx)) {
        Ok(r) -> string.inspect(r.verdict)
        Error(Nil) -> "?"
      }
      io.println(
        "  replayed the /ok delivery: "
        <> int.to_string(status)
        <> ", "
        <> verdict,
      )
    }
    Error(Nil) -> Nil
  }

  io.println("\n-- telemetry trace for the /flaky delivery")
  process.sleep(100)
  case list.find(outcomes, fn(e) { label_is(e.0, secrets, "/flaky") }) {
    Ok(#(delivery_id, _, _)) ->
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

  http_gun.stop(admin)
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

fn is_processed(verdict: receiver.Verdict) -> Bool {
  case verdict {
    receiver.Processed(_) -> True
    _ -> False
  }
}

/// Sends a recorded request to the receiver again, unchanged.
fn replay(rx: receiver.Receiver, captured: receiver.Received) -> Int {
  let port = receiver.port(rx)
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
      captured.headers,
      request.new()
        |> request.set_scheme(http.Http)
        |> request.set_host("127.0.0.1")
        |> request.set_port(port)
        |> request.set_method(http.Post)
        |> request.set_path(captured.path)
        |> request.set_body(captured.body),
      fn(req, header) {
        case header.0 {
          "host" | "content-length" | "connection" -> req
          name -> request.set_header(req, name, header.1)
        }
      },
    )
  let status = case http_gun.send(client, req) {
    Ok(buffered) -> buffered.response.status
    Error(_) -> 0
  }
  http_gun.stop(client)
  status
}

fn describe_outcome(
  outcome: grind.Outcome(attempt.Receipt, attempt.DeliveryError),
) -> String {
  case outcome {
    grind.Succeeded(receipt) ->
      "delivered "
      <> int.to_string(receipt.status)
      <> case receipt.body {
        attempt.BodyIncomplete(reason) -> " (body not read: " <> reason <> ")"
        attempt.BodyRead(_) -> ""
      }
    grind.Failed(grind.Business(e), cause, _) ->
      "failed: "
      <> attempt.describe_error(e)
      <> " ("
      <> string.inspect(cause)
      <> ")"
    grind.Discarded(reason) -> "discarded: " <> reason
    grind.Pending(state) -> "pending (" <> string.inspect(state) <> ")"
    other -> string.inspect(other)
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
  api_key: String,
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
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_body(bit_array.from_string(body))
  case http_gun.send(admin, req) {
    Ok(buffered) ->
      Ok(#(
        buffered.response.status,
        bit_array.to_string(buffered.response.body) |> result.unwrap(""),
      ))
    Error(failure) -> Error(error.name(failure))
  }
}

fn get_json(admin, port, api_key, path, decoder) {
  case call(admin, port, api_key, http.Get, path, "") {
    Ok(#(200, text)) -> json.parse(text, decoder) |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

fn register(admin, port, key, tenant: String, url: String) {
  let body = json.object([#("url", json.string(url))]) |> json.to_string
  case call(admin, port, key(tenant), http.Post, "/subscriptions", body) {
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

fn publish(admin, port, key, tenant: String, event_type: String, data: String) {
  let body = "{\"type\":\"" <> event_type <> "\",\"data\":" <> data <> "}"
  case call(admin, port, key(tenant), http.Post, "/events", body) {
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
