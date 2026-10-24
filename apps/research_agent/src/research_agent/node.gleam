//// A node in another VM, for the crash test: the peer runs the app with
//// its own Grind runtime, Fabric store and HTTP client against the same
//// database, and is then killed with SIGKILL.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/result
import research_agent/app

pub type Peer

@external(erlang, "research_agent_ffi", "start_peer")
pub fn start_peer() -> Result(Peer, String)

/// The peer returns `boot`'s own `Result` term.
@external(erlang, "research_agent_ffi", "peer_call")
fn peer_call(
  peer: Peer,
  module: atom.Atom,
  function: atom.Atom,
  args: List(Dynamic),
) -> Result(Result(String, String), String)

@external(erlang, "research_agent_ffi", "kill_peer")
pub fn kill(peer: Peer) -> Nil

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: a) -> Dynamic

/// Starts a node inside `peer` and submits one research request there.
pub fn start_research_on(
  peer: Peer,
  settings: app.Settings,
  topic: String,
) -> Result(String, String) {
  peer_call(peer, atom.create("research_agent@node"), atom.create("boot"), [
    to_dynamic(settings),
    to_dynamic(topic),
  ])
  |> result.flatten
}

/// Runs in the peer: a long-lived owner process starts the app (its
/// supervision trees link to their starter) and keeps it.
pub fn boot(settings: app.Settings, topic: String) -> Result(String, String) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    case app.start(settings) {
      Ok(node) -> {
        process.send(reply, app.start_research(node, topic))
        process.sleep_forever()
      }
      Error(error) -> process.send(reply, Error(error))
    }
  })
  process.receive(reply, 30_000)
  |> result.replace_error("the peer node did not start")
  |> result.flatten
}
