//// Reads a request body under a byte limit. `mist.read_body` checks only a
//// declared Content-Length and reads a chunked body whole, so a framed body
//// or a missing or negative length is refused before any of it is read, and
//// the body is streamed so that a wrong declared length still stops at the
//// limit.

import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result
import mist

pub type BodyError {
  /// Transfer-Encoding is present, or Content-Length is absent (411).
  LengthRequired
  /// Content-Length is negative (400).
  InvalidLength
  /// The declared or streamed length exceeds the limit (413).
  TooLarge
  /// The connection failed while reading (400).
  Unreadable
}

pub fn read(
  req: Request(mist.Connection),
  limit: Int,
) -> Result(BitArray, BodyError) {
  let framed = result.is_ok(request.get_header(req, "transfer-encoding"))
  let declared =
    request.get_header(req, "content-length") |> result.try(int.parse)
  case framed, declared {
    True, _ | False, Error(Nil) -> Error(LengthRequired)
    False, Ok(length) if length < 0 -> Error(InvalidLength)
    False, Ok(length) if length > limit -> Error(TooLarge)
    False, Ok(_) ->
      case mist.stream(req) {
        Error(_) -> Error(Unreadable)
        Ok(consume) -> read_chunks(consume, limit, <<>>)
      }
  }
}

fn read_chunks(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  limit: Int,
  body: BitArray,
) -> Result(BitArray, BodyError) {
  let remaining = limit - bit_array.byte_size(body)
  case consume(int.min(65_536, remaining + 1)) {
    Error(_) -> Error(Unreadable)
    Ok(mist.Done) -> Ok(body)
    Ok(mist.Chunk(chunk, next)) ->
      case bit_array.byte_size(chunk) > remaining {
        True -> Error(TooLarge)
        False -> read_chunks(next, limit, bit_array.append(body, chunk))
      }
  }
}

/// The response to a refused body. The connection closes, since the unread
/// body would otherwise be parsed as the next request.
pub fn refusal(error: BodyError) -> Response(mist.ResponseData) {
  let #(status, text) = case error {
    LengthRequired -> #(411, "a body needs a Content-Length")
    InvalidLength -> #(400, "the Content-Length is invalid")
    TooLarge -> #(413, "the body exceeds the limit")
    Unreadable -> #(400, "the body could not be read")
  }
  response.new(status)
  |> response.set_header("connection", "close")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}
