//// Start a wisp handler on mist at a free loopback port.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option, None, Some}
import gleam/result
import mist
import wisp
import wisp/wisp_mist

pub type Server {
  Server(pid: Pid, port: Int)
}

pub type Tls {
  Tls(certfile: String, keyfile: String)
}

/// Serve `handler` on 127.0.0.1 at an OS-assigned port, optionally over TLS.
pub fn start(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
  tls: Option(Tls),
) -> Result(Server, String) {
  start_on(handler, secret_key_base, 0, tls)
}

/// Serve `handler` on 127.0.0.1 at `port` (0: any free port).
pub fn start_on(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
  port: Int,
  tls: Option(Tls),
) -> Result(Server, String) {
  let ports = process.new_subject()
  let builder =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.after_start(fn(port, _scheme, _ip) { process.send(ports, port) })
  let builder = case tls {
    Some(Tls(certfile:, keyfile:)) ->
      mist.with_tls(builder, certfile:, keyfile:)
    None -> builder
  }
  use started <- result.try(
    mist.start(builder) |> result.replace_error("mist did not start"),
  )
  use port <- result.try(
    process.receive(ports, 5000) |> result.replace_error("no port reported"),
  )
  Ok(Server(pid: started.pid, port:))
}

/// Stop the server without taking the caller down with it, and wait until
/// its listener is gone so the port can be bound again.
pub fn stop(server: Server) -> Nil {
  let monitor = process.monitor(server.pid)
  process.unlink(server.pid)
  // `shutdown`, not `kill`: supervisors stop children quietly.
  exit(server.pid, atom.create("shutdown"))
  // A child may use its own five-second shutdown allowance before the
  // supervisor closes the listener. Do not treat a timed-out wait as stopped.
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(30_000)
  Nil
}

@external(erlang, "erlang", "exit")
fn exit(pid: Pid, reason: atom.Atom) -> Bool

/// A port that was free a moment ago. The portal needs its own address
/// before it starts: Warden's `redirect_uri` is fixed in its configuration,
/// and Warden must start before the portal can route to it.
pub fn free_port() -> Result(Int, Nil) {
  use socket <- result.try(tcp_listen(0, []) |> result.replace_error(Nil))
  let port = inet_port(socket) |> result.replace_error(Nil)
  let _ = tcp_close(socket)
  port
}

@external(erlang, "gen_tcp", "listen")
fn tcp_listen(port: Int, options: List(Dynamic)) -> Result(Dynamic, Dynamic)

@external(erlang, "inet", "port")
fn inet_port(socket: Dynamic) -> Result(Int, Dynamic)

@external(erlang, "gen_tcp", "close")
fn tcp_close(socket: Dynamic) -> Dynamic
