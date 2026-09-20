// THROWAWAY: Stop metadata cannot replace the exception metadata shape.
import consumers/span_events as examples
import lab/sinal
import lab/sinal_span as span

pub fn invalid(
  backend: sinal.Backend,
  event: sinal.Event(
    span.ExceptionMeasurements,
    span.ExceptionMetadata(examples.RequestStartMetadata),
  ),
  handler: sinal.Handler(
    span.ExceptionMeasurements,
    span.StopMetadata(examples.RequestStopMetadata),
    Nil,
  ),
) -> Result(sinal.Attachment, sinal.AttachError) {
  let assert Ok(id) = sinal.handler_id("span-stop-meta-for-exception")
  sinal.attach(backend, id, event, handler, fn(_event, _failure) { Nil })
}
