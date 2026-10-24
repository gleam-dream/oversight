// THROWAWAY: Interleaved progress is not an assembled terminal tool turn.
import lab/llm
import lab/llm_stream_events as stream
import lab/llm_turn as turn
import lab/value

// Scripted boundary decoder, deliberately not a JSON parser implementation.
fn decode(raw: String) -> Result(value.Value, Nil) {
  case raw {
    "{\"n\":1}" -> Ok(value.Object([#("n", value.Int(1))]))
    "{\"n\":2}" -> Ok(value.Object([#("n", value.Int(2))]))
    _ -> Error(Nil)
  }
}

pub fn probe() -> Nil {
  let a = turn.CallId("call-a")
  let b = turn.CallId("call-b")
  let name = turn.ToolName("lookup")
  let initial = stream.begin()
  let assert Ok(state) =
    stream.progress(
      initial,
      stream.TextDelta(stream.TextBlockId("text"), "Checking"),
      decode,
    )
  let assert Ok(state) =
    stream.progress(state, stream.ToolStarted(a, name), decode)
  let assert Ok(state) =
    stream.progress(state, stream.ToolStarted(b, name), decode)
  let assert Error(stream.DuplicateCall(a)) =
    stream.progress(state, stream.ToolStarted(a, name), decode)
  let assert Ok(state) =
    stream.progress(state, stream.ArgumentsDelta(a, "{\"n\":"), decode)
  let assert Ok(state) =
    stream.progress(state, stream.ArgumentsDelta(b, "{\"n\":2}"), decode)
  let assert Error(stream.IncompleteCall(a)) =
    stream.complete(state, stream.ToolsRequested)
  let assert Ok(state) =
    stream.progress(state, stream.ArgumentsEnded(b), decode)
  let assert Ok(state) =
    stream.progress(state, stream.ArgumentsDelta(a, "1}"), decode)
  let assert Ok(state) =
    stream.progress(state, stream.ArgumentsEnded(a), decode)
  let assert stream.None = stream.terminal(state)
  let assert Error(stream.ArgumentsAlreadyEnded(a)) =
    stream.progress(state, stream.ArgumentsDelta(a, "more"), decode)
  let assert Ok(done) = stream.complete(state, stream.ToolsRequested)
  let assert stream.Some(stream.Completed(stream.RequestsTools(
    "Checking",
    [first, second],
  ))) = stream.terminal(done)
  let assert True = first.id == a && second.id == b
  let assert True = first.arguments == value.Object([#("n", value.Int(1))])
  let assert True = second.arguments == value.Object([#("n", value.Int(2))])
  let assert Error(stream.StreamTerminated) =
    stream.complete(done, stream.ToolsRequested)
  let assert Error(stream.StreamTerminated) =
    stream.fail(done, llm.TransportUnavailable)
  let assert True = stream.close(done) == done
  let assert Ok(failed_early) = stream.fail(initial, llm.RateLimited)
  let assert stream.Some(stream.Failed(stream.BeforeProgress(llm.RateLimited))) =
    stream.terminal(failed_early)
  let assert Ok(failed_late) = stream.fail(state, llm.TransportUnavailable)
  let assert stream.Some(stream.Failed(stream.AfterProgress(
    llm.TransportUnavailable,
  ))) = stream.terminal(failed_late)
  let closed = stream.close(state)
  let assert stream.Some(stream.ConsumerClosed) = stream.terminal(closed)
  let assert True = stream.close(closed) == closed
  let assert Error(stream.StreamTerminated) =
    stream.progress(closed, stream.ArgumentsDelta(a, "x"), decode)
  let assert Error(stream.UnknownCall(a)) =
    stream.progress(initial, stream.ArgumentsDelta(a, "x"), decode)
  let assert Error(stream.NoToolCalls) =
    stream.complete(initial, stream.ToolsRequested)
  let assert Ok(partial) =
    stream.progress(initial, stream.ToolStarted(a, name), decode)
  let assert Error(stream.InvalidArguments(a)) =
    stream.progress(partial, stream.ArgumentsEnded(a), decode)
  let assert Error(stream.UnexpectedToolCalls) =
    stream.complete(partial, stream.FinalText)
  let assert Ok(limited) = stream.complete(partial, stream.OutputLimited)
  let assert stream.Some(stream.Completed(stream.Limited(""))) =
    stream.terminal(limited)
  let assert Ok(final) = stream.complete(initial, stream.FinalText)
  let assert stream.Some(stream.Completed(stream.Final(""))) =
    stream.terminal(final)
  Nil
}
