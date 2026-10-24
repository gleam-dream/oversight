import gleam/bytes_tree
import gleam/result
import gleam/string
import glisten/socket
import glisten/socket/options
import glisten/tcp as native

pub type Socket =
  socket.Socket

pub type ListenSocket =
  socket.ListenSocket

/// Local transport for the pilot's scripted provider, independent of LLM Wire internals.
pub fn listen(port: Int) -> Result(#(ListenSocket, Int), String) {
  use listener <- result.try(
    native.listen(port, [options.Ip(options.Loopback)])
    |> result.map_error(reason_text),
  )
  case native.sockname(listener) {
    Ok(#(_, assigned_port)) -> Ok(#(listener, assigned_port))
    Error(reason) -> {
      let _ = native.close(listener)
      Error(reason_text(reason))
    }
  }
}

pub fn accept(
  listener: ListenSocket,
  timeout_ms: Int,
) -> Result(Socket, String) {
  native.accept_timeout(listener, timeout_ms)
  |> result.map_error(reason_text)
}

pub fn send(socket: Socket, data: BitArray) -> Result(Nil, String) {
  native.send(socket, bytes_tree.from_bit_array(data))
  |> result.map_error(reason_text)
}

pub fn recv(
  socket: Socket,
  length: Int,
  timeout_ms: Int,
) -> Result(BitArray, String) {
  native.receive_timeout(socket, length, timeout_ms)
  |> result.map_error(reason_text)
}

pub fn close(socket: Socket) -> Nil {
  let _ = native.close(socket)
  Nil
}

pub fn close_listener(listener: ListenSocket) -> Nil {
  let _ = native.close(listener)
  Nil
}

fn reason_text(reason: socket.SocketReason) -> String {
  reason |> socket.reason_to_string |> string.lowercase
}
