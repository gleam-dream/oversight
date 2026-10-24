//// `gleam run`: start the system on loopback and narrate one session.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import hellhound/testing
import relay/client as mcp
import secure_mcp/app
import secure_mcp/client
import secure_mcp/reports.{ReportRequest, StatusRequest}
import secure_mcp/telemetry
import secure_mcp/tools
import sinal/correlation

pub fn main() {
  let database_url =
    envoy.get("DATABASE_URL")
    |> result.unwrap("postgres://app@127.0.0.1:5432/app")
  let assert Ok(collector) = telemetry.start()
  case app.start(app.options(database_url)) {
    Error(reason) -> io.println("startup failed: " <> reason)
    Ok(running) -> {
      narrate(running, collector)
      app.stop(running)
    }
  }
  telemetry.stop(collector)
}

fn narrate(running: app.Running, collector: telemetry.Collector) -> Nil {
  io.println("secure_mcp listening at " <> running.base_url)
  io.println("  MCP endpoint: " <> running.mcp_url)

  let assert Ok(alice) = client.sign_in(running.base_url, "alice")
  io.println(
    "1. alice signed in through Hellhound (OIDC code + PKCE); token audience "
    <> alice.mcp_url,
  )

  io.println("2. MCP call without a token -> " <> refusal(running, None))

  let assert Ok(peer) =
    client.connect(running.mcp_url, Some(alice.access_token), [])
  let assert Ok(mcp.Succeeded(submitted, _)) =
    mcp.call(
      peer,
      tools.generate_definition(),
      ReportRequest(title: "Revenue", period: "2026-Q3"),
    )
  io.println(
    "3. generate_report as alice -> Grind job "
    <> int.to_string(submitted.job_id),
  )

  // The app runs in this process, so wait in Grind instead of polling MCP.
  let assert Ok(handle) =
    grind.bind(running.jobs, running.report_worker, submitted.job_id)
  let assert Ok(_) =
    grind.await(running.jobs, handle, within: duration.seconds(10))
  let summary = case
    mcp.call(peer, tools.status_definition(), StatusRequest(submitted.job_id))
  {
    Ok(mcp.Succeeded(reports.ReportStatus(report: Some(report), ..), _)) ->
      report.summary
    other -> "unexpected reply " <> string.inspect(other)
  }
  io.println("4. report_status as alice -> " <> summary)

  let assert Ok(bob) = client.sign_in(running.base_url, "bob")
  let assert Ok(bob_peer) =
    client.connect(running.mcp_url, Some(bob.access_token), [])
  let assert Ok(mcp.ToolFailed(content, _)) =
    mcp.call(
      bob_peer,
      tools.status_definition(),
      StatusRequest(submitted.job_id),
    )
  io.println(
    "5. bob asks for alice's job -> tool error: " <> client.text(content),
  )

  let foreign =
    testing.issue_access_token(
      running.provider,
      testing.access_token("alice")
        |> testing.with_audiences(["https://other.example/api"])
        |> testing.with_scopes(["reports"]),
    )
  io.println(
    "6. token issued for another resource -> "
    <> refusal(running, Some(foreign)),
  )

  let forged =
    testing.issue_access_token(
      running.provider,
      testing.access_token("alice")
        |> testing.with_audiences([running.mcp_url])
        |> testing.with_scopes(["reports"])
        |> testing.forged(testing.HmacWithPublicKey),
    )
  io.println(
    "7. HS256 token keyed with the provider's public key -> "
    <> refusal(running, Some(forged)),
  )

  testing.revoke_access_token(running.provider, alice.access_token)
  let still = case mcp.discover(peer) {
    Ok(_) -> "still accepted: local JWT validation sees no revocation"
    Error(error) -> mcp.describe_error(error)
  }
  io.println("8. alice's token revoked at the provider -> " <> still)
  mcp.close(peer)
  mcp.close(bob_peer)

  // Let Grind's forwarder deliver its asynchronous events.
  process.sleep(200)
  io.println("Telemetry (one line per Sinal event, all packages):")
  telemetry.lines(collector)
  |> list.map(telemetry.format)
  |> list.each(io.println)
}

/// The status and challenge of a refused `server/discover`.
fn refusal(running: app.Running, token: option.Option(String)) -> String {
  let assert Ok(peer) = client.connect(running.mcp_url, token, [])
  let outcome = mcp.discover(peer)
  mcp.close(peer)
  case outcome {
    Error(error) ->
      case mcp.reason(error) {
        mcp.HttpStatus(status, challenge) ->
          int.to_string(status)
          <> " WWW-Authenticate: "
          <> option.unwrap(challenge, "-")
          <> " correlation="
          <> correlation.to_string(mcp.error_correlation(error))
        _ -> "unexpected " <> mcp.describe_error(error)
      }
    Ok(_) -> "unexpected success"
  }
}
