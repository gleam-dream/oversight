import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit
import grind
import grind/job
import relay/client as mcp
import relay/http as mcp_http
import relay/subscriptions
import secure_mcp/app
import secure_mcp/client
import secure_mcp/reports.{ReportRequest, ReportStatus, StatusRequest}
import secure_mcp/telemetry
import secure_mcp/tools
import warden
import warden/testing

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_app(run: fn(app.Running) -> a) -> a {
  with_app_options(fn(options) { options }, run)
}

fn with_app_options(
  change: fn(app.Options) -> app.Options,
  run: fn(app.Running) -> a,
) -> a {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(running) = app.start(change(app.options(url)))
  let result = run(running)
  app.stop(running)
  result
}

fn connect(running: app.Running, token: String) -> mcp.Client {
  let assert Ok(peer) = client.connect(running.mcp_url, Some(token), [])
  peer
}

fn generate(peer: mcp.Client, period: String) -> Int {
  let assert Ok(mcp.Succeeded(submitted, _)) =
    mcp.call(
      peer,
      tools.generate_definition(),
      ReportRequest(title: "Revenue", period:),
    )
  submitted.job_id
}

fn status(peer: mcp.Client, job_id: Int) {
  mcp.call(peer, tools.status_definition(), StatusRequest(job_id))
}

/// Waits in Grind, not over MCP, until the job leaves its pending states.
fn await_job(
  running: app.Running,
  job_id: Int,
) -> grind.Outcome(reports.Report, String) {
  let assert Ok(handle) =
    grind.bind(running.jobs, running.report_worker, job_id)
  let assert Ok(outcome) =
    grind.await(running.jobs, handle, within: duration.seconds(10))
  outcome
}

/// The job's `report_status` once it has finished.
fn await_status(
  running: app.Running,
  peer: mcp.Client,
  job_id: Int,
) -> reports.ReportStatus {
  let _ = await_job(running, job_id)
  let assert Ok(mcp.Succeeded(report_status, _)) = status(peer, job_id)
  report_status
}

/// The refusal of a `server/discover` with this token (or none).
fn refusal(running: app.Running, token: option.Option(String)) -> mcp.Error {
  let assert Ok(peer) = client.connect(running.mcp_url, token, [])
  let assert Error(error) = mcp.discover(peer)
  mcp.close(peer)
  error
}

fn minted(running: app.Running) -> testing.TokenSpec {
  testing.access_token("alice")
  |> testing.with_audiences([running.mcp_url])
  |> testing.with_scopes(["reports"])
}

// --- Common path ---------------------------------------------------------------

/// Browser login through Warden, then tool -> Grind job -> result, as the
/// signed-in user, through Relay's own client with a bearer header.
pub fn report_round_trip_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  assert alice.subject == "alice"
  assert alice.mcp_url == running.mcp_url
  let peer = connect(running, alice.access_token)

  let assert Ok(listing) = mcp.list_tools(peer)
  assert list.map(listing, fn(d) { d.name })
    == ["generate_report", "report_status"]

  let job_id = generate(peer, "2026-Q3")
  let report_status = await_status(running, peer, job_id)
  mcp.close(peer)
  assert report_status.state == "succeeded"
  // The handler took the owner from the authenticated principal.
  let assert Some(report) = report_status.report
  assert report.summary == "REVENUE for 2026-Q3: 42 rows, prepared for alice"
}

/// A business failure in the worker reaches the MCP client as a state.
pub fn failed_report_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let peer = connect(running, alice.access_token)
  let job_id = generate(peer, "never")
  // The typed outcome carries the worker's own error, and the retry policy
  // that declined another attempt.
  assert await_job(running, job_id)
    == grind.Failed(
      grind.Business("no data for period"),
      option.Some(job.RetryDeclined),
      "worker returned an application error",
    )
  let report_status = await_status(running, peer, job_id)
  mcp.close(peer)
  assert report_status
    == ReportStatus(job_id, "failed: no data for period", None)
}

/// The job's input codec is stricter than the tool's: Grind refuses a report
/// without a title at `submit`, and the caller reads why.
pub fn invalid_report_is_refused_at_submit_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let peer = connect(running, alice.access_token)
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(
      peer,
      tools.generate_definition(),
      ReportRequest(title: "", period: "Q1"),
    )
  mcp.close(peer)
  assert client.text(content)
    == "The report was refused: $[\"title\"]: must not be empty"
}

// --- Failure paths -------------------------------------------------------------

/// No token: Relay's client reads a typed 401 whose RFC 6750 challenge (no
/// error code) points at the RFC 9728 metadata, which Relay serves.
pub fn no_token_test() {
  use running <- with_app
  let metadata_url =
    running.base_url <> "/.well-known/oauth-protected-resource/mcp"
  assert refusal(running, None)
    == mcp.HttpStatus(
      401,
      Some("Bearer resource_metadata=\"" <> metadata_url <> "\""),
    )

  let assert Ok(req) = request.to(metadata_url)
  let assert Ok(resp) = httpc.send(req)
  let decoder = {
    use resource <- decode.field("resource", decode.string)
    use servers <- decode.field(
      "authorization_servers",
      decode.list(decode.string),
    )
    use scopes <- decode.field("scopes_supported", decode.list(decode.string))
    decode.success(#(resource, servers, scopes))
  }
  assert json.parse(resp.body, decoder)
    == Ok(#(running.mcp_url, [testing.issuer(running.provider)], ["reports"]))
}

/// A token whose audience is another resource is refused by the JWT
/// validator before Relay compares the resource, so the challenge is the
/// generic `invalid_token`.
pub fn token_for_another_audience_test() {
  use running <- with_app
  let token =
    testing.issue_access_token(
      running.provider,
      minted(running)
        |> testing.with_audiences(["https://reports.other.example/mcp"]),
    )
  let assert mcp.HttpStatus(401, Some(challenge)) =
    refusal(running, Some(token))
  assert string.starts_with(
    challenge,
    "Bearer error=\"invalid_token\", error_description=\"The access token is invalid or expired\"",
  )
}

/// Users only see their own reports: another user's job id is "not found".
pub fn other_users_job_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let assert Ok(bob) = client.sign_in(running.base_url, "bob")
  let alice_peer = connect(running, alice.access_token)
  let bob_peer = connect(running, bob.access_token)
  let job_id = generate(alice_peer, "2026-Q2")
  let assert Ok(mcp.ToolFailed(content, _)) = status(bob_peer, job_id)
  assert client.text(content) == "No such report job for this user."
  // The same message as a job id that does not exist.
  let assert Ok(mcp.ToolFailed(missing, _)) = status(bob_peer, 999_999_999)
  assert missing == content
  mcp.close(alice_peer)
  mcp.close(bob_peer)
}

/// Expired, unsigned, algorithm-confused, unknown-key, untyped and
/// foreign-issuer tokens: each 401 `invalid_token` with the metadata pointer.
pub fn rejected_jwt_tokens_test() {
  use running <- with_app
  let specs = [
    minted(running) |> testing.with_ttl(duration.seconds(-5)),
    minted(running) |> testing.forged(testing.UnsignedToken),
    minted(running) |> testing.forged(testing.HmacWithPublicKey),
    minted(running) |> testing.forged(testing.UnknownKey),
    minted(running) |> testing.with_token_type(None),
    minted(running) |> testing.with_issuer("https://issuer.other.example"),
  ]
  list.each(specs, fn(spec) {
    let token = testing.issue_access_token(running.provider, spec)
    let assert mcp.HttpStatus(401, Some(challenge)) =
      refusal(running, Some(token))
    assert string.starts_with(challenge, "Bearer error=\"invalid_token\"")
    assert string.contains(challenge, "resource_metadata=")
  })
}

/// The endpoint scope is enforced by Relay's `admit`: 403 insufficient_scope.
pub fn insufficient_scope_test() {
  use running <- with_app
  let token =
    testing.issue_access_token(
      running.provider,
      minted(running) |> testing.with_scopes(["profile"]),
    )
  let assert mcp.HttpStatus(403, Some(challenge)) =
    refusal(running, Some(token))
  assert string.starts_with(
    challenge,
    "Bearer error=\"insufficient_scope\", scope=\"reports\"",
  )
}

// --- Advanced configuration ----------------------------------------------------

/// Local JWT validation sends no request per token, and an RFC 9068 token
/// carries no revocation channel, so a token revoked at the provider stays
/// usable until `exp`. The provider itself does consider it revoked, which
/// introspection shows; `introspection_mode_test` covers refusal at once.
pub fn revoked_token_still_valid_locally_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  testing.revoke_access_token(running.provider, alice.access_token)
  let peer = connect(running, alice.access_token)
  let assert Ok(_) = mcp.discover(peer)
  mcp.close(peer)
  assert testing.requests(running.provider).introspections == 0
  // Revoked at the provider all the same.
  let assert Ok(warden.InactiveToken) =
    warden.introspect(running.warden, alice.access_token)
}

/// The introspection mode: revocation takes effect at once, and Relay's own
/// audience check names the wrong resource.
pub fn introspection_mode_test() {
  use running <- with_app_options(fn(options) {
    app.Options(..options, verification: app.Introspection)
  })
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let peer = connect(running, alice.access_token)
  let job_id = generate(peer, "2026-Q4")
  assert await_status(running, peer, job_id).state == "succeeded"
  mcp.close(peer)

  let foreign =
    testing.issue_access_token(
      running.provider,
      minted(running) |> testing.with_audiences(["https://other.example/mcp"]),
    )
  let assert mcp.HttpStatus(401, Some(challenge)) =
    refusal(running, Some(foreign))
  assert string.contains(challenge, "issued for another resource")

  let expired =
    testing.issue_access_token(
      running.provider,
      minted(running) |> testing.with_ttl(duration.seconds(-5)),
    )
  let assert mcp.HttpStatus(401, _) = refusal(running, Some(expired))

  testing.revoke_access_token(running.provider, alice.access_token)
  let assert mcp.HttpStatus(401, Some(challenge)) =
    refusal(running, Some(alice.access_token))
  assert string.starts_with(challenge, "Bearer error=\"invalid_token\"")
  assert testing.requests(running.provider).introspections >= 4
}

/// `subscriptions/listen` streams server-sent events through the protected
/// mount: the endpoint is Relay's own streaming handler.
pub fn subscription_stream_through_protected_mount_test() {
  use running <- with_app
  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  let peer = connect(running, alice.access_token)
  let assert Ok(subscription) =
    mcp.listen(peer, [subscriptions.ToolsListChanged])
  mcp_http.notify(running.mcp, subscriptions.ToolsListChanged)
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    mcp.next_notification(subscription, duration.seconds(2))
  mcp.close_subscription(subscription)
  mcp.close(peer)
}

/// One `/mcp` request followed across packages through Sinal with no app
/// event: Relay's admission and invocation events and Grind's job events
/// carry the same correlation.
pub fn telemetry_correlation_test() {
  let assert Ok(collector) = telemetry.start()
  let #(job_id, lines) = {
    use running <- with_app
    let assert Ok(alice) = client.sign_in(running.base_url, "alice")
    let peer = connect(running, alice.access_token)
    let job_id = generate(peer, "2026-Q1")
    let _ = await_status(running, peer, job_id)
    mcp.close(peer)
    process.sleep(100)
    #(job_id, telemetry.lines(collector))
  }
  telemetry.stop(collector)
  let job = "job=" <> string.inspect(job_id)
  let grind_lines = fn(event) {
    list.filter(lines, fn(l) {
      l.package == "grind"
      && l.event == event
      && string.starts_with(l.detail, job <> " ")
    })
  }
  let assert [admitted] = grind_lines("job.admitted")
  let assert Ok(request_id) = field(admitted.detail, "correlation")
  // Every Grind event of the job names the request that submitted it.
  let assert [claimed] = grind_lines("job.claimed")
  assert field(claimed.detail, "correlation") == Ok(request_id)
  let assert [acknowledged] = grind_lines("job.acknowledged")
  assert field(acknowledged.detail, "correlation") == Ok(request_id)
  // Relay's events for that request carry the same correlation.
  let relay_events =
    list.filter(lines, fn(l) {
      l.package == "relay" && field(l.detail, "correlation") == Ok(request_id)
    })
    |> list.map(fn(l) { l.event })
  assert relay_events
    == ["authorization.decided", "request.admitted", "invocation.started"]
  assert list.any(lines, fn(l) {
    l.event == "invocation.started"
    && field(l.detail, "tool") == Ok("generate_report")
  })
  // Local validation sends nothing to the provider per request.
  assert !list.any(lines, fn(l) {
    l.package == "warden" && string.contains(l.detail, "/introspect")
  })
}

/// The value after `key=` in a collector line's detail.
fn field(detail: String, key: String) -> Result(String, Nil) {
  string.split(detail, " ")
  |> list.find_map(fn(part) {
    case string.split_once(part, "=") {
      Ok(#(name, value)) if name == key -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// The caller's `x-request-id` becomes the request's correlation when it is
/// a valid `Correlation`; an oversized one is replaced by a fresh
/// 32-character id instead of reaching telemetry.
pub fn request_id_header_correlation_test() {
  let assert Ok(collector) = telemetry.start()
  let lines = {
    use running <- with_app
    let assert Ok(alice) = client.sign_in(running.base_url, "alice")
    let call = fn(request_id) {
      let assert Ok(peer) =
        client.connect(running.mcp_url, Some(alice.access_token), [
          #("x-request-id", request_id),
        ])
      let _ = generate(peer, "2026-Q2")
      mcp.close(peer)
    }
    call("trace-abc-123")
    call(string.repeat("x", 129))
    process.sleep(100)
    telemetry.lines(collector)
  }
  telemetry.stop(collector)
  let correlations =
    lines
    |> list.filter(fn(l) { l.event == "request.admitted" })
    |> list.filter_map(fn(l) { field(l.detail, "correlation") })
  assert list.contains(correlations, "trace-abc-123")
  // The job inherits it, so Grind's events carry the caller's request id.
  assert list.any(lines, fn(l) {
    l.event == "job.admitted"
    && field(l.detail, "correlation") == Ok("trace-abc-123")
  })
  assert !list.contains(correlations, string.repeat("x", 129))
  assert list.any(correlations, fn(c) { string.length(c) == 32 })
}
