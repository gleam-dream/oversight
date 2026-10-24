import lab/llm_stream_owner as stream

pub fn invalid(
  owner: stream.Owner(String, Nil),
) -> stream.Pending(String, Nil) {
  owner
}
