import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import grind/job
import grind/postgres
import grind/queue
import grind/registry
import grind/worker
import relay/client as relay_client
import secure_mcp/app
import secure_mcp/client.{Other, Refused, Structured, ToolError}
import secure_mcp/dev_provider
import secure_mcp/telemetry

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_app(run: fn(app.Running) -> a) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(running) = app.start(app.options(url))
  let result = run(running)
  app.stop(running)
  result
}

fn generate(running: app.Running, token: String, period: String) -> Int {
  let assert Ok(Structured(value)) =
    client.call_tool(
      running.mcp_url,
      Some(token),
      "generate_report",
      json.object([
        #("title", json.string("Revenue")),
        #("period", json.string(period)),
      ]),
    )
  let assert Ok(job_id) =
    decode.run(value, decode.field("job_id", decode.int, decode.success))
  job_id
}

/// Polls `report_status` until the job leaves the queue; returns the state
/// and the summary when present.
fn await_status(
  running: app.Running,
  token: String,
  job_id: Int,
) -> #(String, option.Option(String)) {
  await_loop(running, token, job_id, 100)
}

fn await_loop(running, token, job_id, attempts) {
  let assert Ok(Structured(value)) = status(running, token, job_id)
  let assert Ok(#(state, summary)) = decode.run(value, status_decoder())
  case state, attempts {
    "queued", n | "executing", n | "retryable", n if n > 0 -> {
      process.sleep(50)
      await_loop(running, token, job_id, n - 1)
    }
    _, _ -> #(state, summary)
  }
}

fn status(running: app.Running, token: String, job_id: Int) {
  client.call_tool(
    running.mcp_url,
    Some(token),
    "report_status",
    json.object([#("job_id", json.int(job_id))]),
  )
}

fn status_decoder() -> decode.Decoder(#(String, option.Option(String))) {
  use state <- decode.field("state", decode.string)
  use summary <- decode.optional_field(
    "report",
    None,
    decode.optional(decode.field("summary", decode.string, decode.success)),
  )
  decode.success(#(state, summary))
}

// --- Common path ---------------------------------------------------------------

/// Browser login through Warden, then tool -> Grind job -> result, as the
/// signed-in user.
pub fn report_round_trip_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  assert alice.subject == "alice"
  assert alice.mcp_url == running.mcp_url

  let assert Ok(Other(listing)) =
    client.list_tools(running.mcp_url, alice.access_token)
  assert string.contains(listing, "generate_report")
  assert string.contains(listing, "report_status")

  let job_id = generate(running, alice.access_token, "2026-Q3")
  let #(state, summary) = await_status(running, alice.access_token, job_id)
  assert state == "succeeded"
  // The handler took the owner from the authenticated principal.
  assert summary == Some("REVENUE for 2026-Q3: 42 rows, prepared for alice")
}

/// A business failure in the worker reaches the MCP client as a state.
pub fn failed_report_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let job_id = generate(running, alice.access_token, "never")
  let #(state, summary) = await_status(running, alice.access_token, job_id)
  assert summary == None
  // The worker's error codec keeps its own reason through `bind_handle`.
  assert state == "failed: no data for period"
}

// --- Failure paths -------------------------------------------------------------

/// No token: 401 with an RFC 6750 challenge (no error code) that points at
/// the RFC 9728 metadata, which names the resource and the provider.
pub fn no_token_test() {
  use running <- with_app
  let assert Ok(Refused(401, Some(challenge))) =
    client.discover(running.mcp_url, None)
  let metadata_url =
    running.base_url <> "/.well-known/oauth-protected-resource/mcp"
  assert challenge == "Bearer resource_metadata=\"" <> metadata_url <> "\""

  let assert Ok(req) = request.to(metadata_url)
  let assert Ok(resp) = httpc.send(req)
  let decoder = {
    use resource <- decode.field("resource", decode.string)
    use servers <- decode.field(
      "authorization_servers",
      decode.list(decode.string),
    )
    decode.success(#(resource, servers))
  }
  let assert Ok(#(resource, servers)) = json.parse(resp.body, decoder)
  assert resource == running.mcp_url
  assert servers == [dev_provider.issuer(running.provider)]
}

/// An active token whose audience is another resource is refused.
pub fn token_for_another_audience_test() {
  use running <- with_app
  let token =
    dev_provider.mint(
      running.provider,
      subject: "alice",
      audience: "https://reports.other.example/mcp",
      scopes: ["reports"],
      ttl_seconds: 300,
    )
  let assert Ok(Refused(401, Some(challenge))) =
    client.discover(running.mcp_url, Some(token))
  assert string.starts_with(challenge, "Bearer error=\"invalid_token\"")
  assert string.contains(challenge, "another resource")
}

/// Users only see their own reports: another user's job id is "not found".
pub fn other_users_job_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let assert Ok(bob) = client.sign_in(running.base_url, "bob")
  let job_id = generate(running, alice.access_token, "2026-Q2")
  let assert Ok(ToolError(message)) = status(running, bob.access_token, job_id)
  assert message == "No such report job for this user."
  // The same message as a job id that does not exist.
  let assert Ok(ToolError(missing)) =
    status(running, bob.access_token, 999_999_999)
  assert missing == message
}

// --- Advanced configuration ----------------------------------------------------

/// Expired or revoked tokens: 401 `invalid_token` with the metadata pointer.
pub fn expired_and_revoked_tokens_test() {
  use running <- with_app
  let expired =
    dev_provider.mint(
      running.provider,
      subject: "alice",
      audience: running.mcp_url,
      scopes: ["reports"],
      ttl_seconds: -5,
    )
  let assert Ok(Refused(401, Some(challenge))) =
    client.discover(running.mcp_url, Some(expired))
  assert string.starts_with(challenge, "Bearer error=\"invalid_token\"")
  assert string.contains(challenge, "resource_metadata=")

  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let assert Ok(Other(_)) =
    client.discover(running.mcp_url, Some(alice.access_token))
  dev_provider.revoke(running.provider, alice.access_token)
  let assert Ok(Refused(401, Some(challenge))) =
    client.discover(running.mcp_url, Some(alice.access_token))
  assert string.starts_with(challenge, "Bearer error=\"invalid_token\"")
}

/// The endpoint scope is enforced by Relay's `admit`: 403 insufficient_scope.
pub fn insufficient_scope_test() {
  use running <- with_app
  let token =
    dev_provider.mint(
      running.provider,
      subject: "alice",
      audience: running.mcp_url,
      scopes: ["profile"],
      ttl_seconds: 300,
    )
  let assert Ok(Refused(403, Some(challenge))) =
    client.discover(running.mcp_url, Some(token))
  assert string.starts_with(
    challenge,
    "Bearer error=\"insufficient_scope\", scope=\"reports\"",
  )
}

/// One `/mcp` request followed across packages through Sinal: the app's
/// bridge events join Relay's exchange id and Grind's job id.
pub fn telemetry_correlation_test() {
  let assert Ok(collector) = telemetry.start()
  let #(job_id, lines) = {
    use running <- with_app
    let assert Ok(alice) = client.sign_in(running.base_url, "alice")
    let job_id = generate(running, alice.access_token, "2026-Q1")
    let _ = await_status(running, alice.access_token, job_id)
    process.sleep(100)
    #(job_id, telemetry.lines(collector))
  }
  telemetry.stop(collector)
  let job = "job=" <> string.inspect(job_id)
  let assert Ok(submitted) =
    list.find(lines, fn(l) {
      l.event == "report.submitted" && string.ends_with(l.detail, job)
    })
  // request=R job=J -> the app's mcp.request event for R names the exchange.
  let assert Ok(#(request_part, _)) = string.split_once(submitted.detail, " ")
  let assert Ok(mcp_request) =
    list.find(lines, fn(l) {
      l.event == "mcp.request" && string.starts_with(l.detail, request_part)
    })
  let assert [_, exchange, _] = string.split(mcp_request.detail, " ")
  assert list.any(lines, fn(l) {
    l.event == "request.admitted"
    && string.starts_with(l.detail, exchange <> " ")
  })
  assert list.any(lines, fn(l) {
    l.package == "grind"
    && l.event == "job.admitted"
    && string.starts_with(l.detail, job <> " ")
  })
  assert list.any(lines, fn(l) {
    l.package == "warden" && string.contains(l.detail, "/introspect")
  })
}

/// The caller's `x-request-id` becomes the correlation of the app's events
/// when it is a valid `Correlation`; an oversized one is replaced by a fresh
/// 32-character id instead of reaching telemetry.
pub fn request_id_header_correlation_test() {
  let assert Ok(collector) = telemetry.start()
  let lines = {
    use running <- with_app
    let assert Ok(alice) = client.sign_in(running.base_url, "alice")
    let call = fn(request_id) {
      let assert Ok(Structured(_)) =
        client.call_tool_with_headers(
          running.mcp_url,
          Some(alice.access_token),
          "generate_report",
          json.object([
            #("title", json.string("Revenue")),
            #("period", json.string("2026-Q2")),
          ]),
          [#("x-request-id", request_id)],
        )
      Nil
    }
    call("trace-abc-123")
    call(string.repeat("x", 129))
    process.sleep(100)
    telemetry.lines(collector)
  }
  telemetry.stop(collector)
  let correlations =
    lines
    |> list.filter(fn(l) { l.event == "mcp.request" })
    |> list.filter_map(fn(l) {
      string.split(l.detail, " ")
      |> list.first
      |> result.map(string.replace(_, "correlation=", ""))
    })
  assert list.contains(correlations, "trace-abc-123")
  assert !list.contains(correlations, string.repeat("x", 129))
  assert list.any(correlations, fn(c) { string.length(c) == 32 })
}

// --- Evidence for FEEDBACK -----------------------------------------------------

/// SMCP-6: Relay's own client has no way to attach a bearer token, so it
/// cannot talk to this (or any) protected MCP server.
pub fn relay_client_cannot_authenticate_test() {
  use running <- with_app
  let assert Ok(config) = relay_client.http_config(running.mcp_url)
  let assert Ok(peer) =
    config |> relay_client.with_timeout(2000) |> relay_client.connect_http
  let outcome = relay_client.discover(peer)
  relay_client.close(peer)
  let assert Error(reason) = outcome
  // The 401 reaches the caller only as prose; the challenge is dropped.
  assert reason == "server discovery returned HTTP 401"
}

/// SMCP-7 (fixed by grind 7a04831): a job of a worker defined with
/// `define_with_error_codec` re-binds by id after it succeeds or fails, and
/// the re-bound handle reads the typed result or the typed reason.
pub fn grind_bind_handle_after_terminal_write_test() {
  use running <- with_app
  let assert Ok(text) = worker.codec("text-v1", json.string, decode.string)
  let assert Ok(echo_worker) =
    worker.define_with_error_codec("probe.echo", "v1", text, text, text, fn(s) {
      case s {
        "fail" -> Error("refused")
        _ -> Ok(s)
      }
    })
  let echo_worker =
    worker.with_retry_policy(
      echo_worker,
      worker.retry_policy(fn(_failure, _context) { worker.DoNotRetry }),
    )
  let assert Ok(workers) =
    registry.new("probe") |> result.try(registry.register(_, echo_worker))
  let assert Ok(policy) =
    queue.default_policy() |> queue.with_manual_polling |> queue.validate_policy
  let assert Ok(consumer) = queue.start(running.database, workers, policy)
  let assert Ok(succeeded) =
    postgres.submit(running.database, "probe", echo_worker, "hello")
  let assert Ok(True) = queue.process_one(consumer)
  let assert Ok(failed) =
    postgres.submit(running.database, "probe", echo_worker, "fail")
  let assert Ok(True) = queue.process_one(consumer)
  let _ = queue.stop(consumer)
  // Handles re-bound from the ids alone (as after a restart) read the results.
  let assert Ok(rebound) =
    postgres.bind_handle(running.database, echo_worker, job.id_value(succeeded))
  let assert Ok(job.SucceededWith("hello")) =
    postgres.outcome(running.database, rebound)
  let assert Ok(rebound) =
    postgres.bind_handle(running.database, echo_worker, job.id_value(failed))
  let assert Ok(outcome) = postgres.outcome(running.database, rebound)
  let reason = case outcome {
    job.BusinessFailedWith(reason) | job.BusinessFailedWithCause(reason, _) ->
      reason
    other -> string.inspect(other)
  }
  assert reason == "refused"
}
