//// `gleam run`: start the system on loopback and narrate one session.

import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import secure_mcp/app
import secure_mcp/client.{Refused, Structured, ToolError}
import secure_mcp/dev_provider
import secure_mcp/telemetry

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
    "1. alice signed in through Warden (OIDC code + PKCE); token audience "
    <> alice.mcp_url,
  )

  let assert Ok(Refused(status, challenge)) =
    client.discover(running.mcp_url, None)
  io.println(
    "2. MCP call without a token -> "
    <> int.to_string(status)
    <> " WWW-Authenticate: "
    <> option.unwrap(challenge, "-"),
  )

  let assert Ok(Structured(submitted)) =
    client.call_tool(
      running.mcp_url,
      Some(alice.access_token),
      "generate_report",
      json.object([
        #("title", json.string("Revenue")),
        #("period", json.string("2026-Q3")),
      ]),
    )
  let assert Ok(job_id) =
    decode.run(submitted, decode.field("job_id", decode.int, decode.success))
  io.println(
    "3. generate_report as alice -> Grind job " <> int.to_string(job_id),
  )

  // The app runs in this process, so wait in Grind instead of polling MCP.
  let assert Ok(handle) =
    grind.bind(running.jobs, running.report_worker, job_id)
  let assert Ok(_) =
    grind.await(running.jobs, handle, within: duration.seconds(10))
  let summary = report_summary(running.mcp_url, alice.access_token, job_id)
  io.println("4. report_status as alice -> " <> summary)

  let assert Ok(bob) = client.sign_in(running.base_url, "bob")
  let assert Ok(ToolError(message)) =
    client.call_tool(
      running.mcp_url,
      Some(bob.access_token),
      "report_status",
      json.object([#("job_id", json.int(job_id))]),
    )
  io.println("5. bob asks for alice's job -> tool error: " <> message)

  let foreign =
    dev_provider.mint(
      running.provider,
      subject: "alice",
      audience: "https://other.example/api",
      scopes: ["reports"],
      ttl_seconds: 300,
    )
  let assert Ok(Refused(status, _)) =
    client.discover(running.mcp_url, Some(foreign))
  io.println(
    "6. token issued for another resource -> " <> int.to_string(status),
  )

  dev_provider.revoke(running.provider, alice.access_token)
  let assert Ok(Refused(status, challenge)) =
    client.discover(running.mcp_url, Some(alice.access_token))
  io.println(
    "7. alice's token revoked at the provider -> "
    <> int.to_string(status)
    <> " "
    <> option.unwrap(challenge, "-"),
  )

  // Let Grind's forwarder deliver its asynchronous events.
  process.sleep(200)
  io.println("Telemetry (one line per Sinal event, all packages):")
  telemetry.lines(collector)
  |> list.map(telemetry.format)
  |> list.each(io.println)
}

fn report_summary(mcp_url: String, token: String, job_id: Int) -> String {
  let reply =
    client.call_tool(
      mcp_url,
      Some(token),
      "report_status",
      json.object([#("job_id", json.int(job_id))]),
    )
  let decoder = {
    use state <- decode.field("state", decode.string)
    use summary <- decode.optional_field(
      "report",
      None,
      decode.optional(decode.field("summary", decode.string, decode.success)),
    )
    decode.success(#(state, summary))
  }
  case reply {
    Ok(Structured(value)) ->
      case decode.run(value, decoder) {
        Ok(#(_, Some(summary))) -> summary
        other -> "unexpected status " <> string.inspect(other)
      }
    other -> "unexpected reply " <> string.inspect(other)
  }
}
