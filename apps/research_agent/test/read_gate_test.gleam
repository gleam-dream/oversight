//// The read tool's policy and the scripted services' body limit, without a
//// database.

import fabric/policy
import fabric/run
import gleam/int
import gleam/json
import gleam/list
import http_gun
import http_gun/config as http_config
import research_agent/app
import research_agent/researcher
import research_agent/services

const library = "http://127.0.0.1:4100"

fn decide(url: String) -> policy.Decision {
  let assert Ok(http) = http_gun.start(http_config.default())
  let action =
    policy.Action(
      run: run.new_id(),
      step: policy.ToolCall(run.ActionId(1, "call_1")),
      name: "read",
      arguments_json: json.to_string(json.object([#("url", json.string(url))])),
      target: policy.InvokeTool,
    )
  let gate = researcher.gate(app.endpoints(library))
  let assert Ok(decision) = gate(researcher.Context(http), action)
  http_gun.stop(http)
  decision
}

/// A page of the library is read.
pub fn a_library_page_is_allowed_test() {
  assert decide(library <> "/pages/gleam-1") == policy.Allow
}

/// The gate compares the parsed URL's scheme, host and port exactly and the
/// path segment by segment, so a URL that only starts with the library's
/// text, or whose path climbs out of it once the server normalises it, is
/// denied before any request.
pub fn urls_outside_the_library_are_denied_test() {
  let denied = [
    // Dot segments, plain and percent-encoded in either case.
    library <> "/pages/../drafts/d-1",
    library <> "/pages/./../openai/v1/responses",
    library <> "/pages/%2e%2e/drafts/d-1",
    library <> "/pages/%2E%2E/drafts/d-1",
    library <> "/pages/.%2e/drafts/d-1",
    library <> "/pages/%2e",
    // Encoded separators that a server may decode into another path.
    library <> "/pages/..%2fdrafts%2fd-1",
    library <> "/pages/x%2F..%2F..%2Fdrafts",
    library <> "/pages/..%5cdrafts",
    library <> "/pages/x\\..\\drafts",
    // The library itself, an empty segment, and a sibling prefix.
    library <> "/pages/",
    library <> "/pages//gleam-1",
    library <> "/pagesx/gleam-1",
    // Another authority that shares the library's text.
    library <> "0/pages/gleam-1",
    library <> "@evil.test/pages/gleam-1",
    "http://127.0.0.1:4100.evil.test/pages/gleam-1",
    "https://127.0.0.1:4100/pages/gleam-1",
    "http://localhost:4100/pages/gleam-1",
    // Undecodable escapes.
    library <> "/pages/%zz",
  ]
  list.each(denied, fn(url) {
    let decision = decide(url)
    assert decision == policy.Deny("only the research library may be read")
      as url
  })
}

@external(erlang, "research_agent_raw_http_ffi", "status")
fn raw_status(port: Int, request: String) -> Result(Int, Nil)

/// The scripted provider reads a body only under a declared length within
/// its limit: a chunked body, which mist would otherwise read whole, and a
/// missing length are refused with 411, a declared length over the limit
/// with 413, before the request is recorded.
pub fn the_scripted_provider_bounds_request_bodies_test() {
  let assert Ok(world) = services.start()
  let head = "POST /openai/v1/responses HTTP/1.1\r\nhost: 127.0.0.1\r\n"
  let assert Ok(411) =
    raw_status(
      world.port,
      head <> "transfer-encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    )
  let assert Ok(413) =
    raw_status(
      world.port,
      head
        <> "content-length: "
        <> int.to_string(services.max_body_bytes + 1)
        <> "\r\n\r\n",
    )
  let assert Ok(411) =
    raw_status(world.port, head <> "connection: close\r\n\r\n")
  assert services.llm_requests(world, "") == []
}

/// A negative declared length is malformed framing: the scripted provider
/// refuses it with 400 before the request is recorded.
pub fn the_scripted_provider_refuses_a_negative_length_test() {
  let assert Ok(world) = services.start()
  let head = "POST /openai/v1/responses HTTP/1.1\r\nhost: 127.0.0.1\r\n"
  let assert Ok(400) =
    raw_status(world.port, head <> "content-length: -1\r\n\r\n{}")
  assert services.llm_requests(world, "") == []
}
