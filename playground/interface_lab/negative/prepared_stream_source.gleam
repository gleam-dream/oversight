import lab/llm_stream_owner as stream

pub fn invalid(
  prepared: stream.PreparedContinuation(String),
) -> stream.PreparedContinuation(Int) {
  prepared
}
