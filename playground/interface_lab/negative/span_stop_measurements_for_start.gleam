// THROWAWAY: Stop-only measurements cannot replace start measurements.
import consumers/span_events as examples
import lab/sinal
import lab/sinal_span as span

pub fn invalid(
  backend: sinal.Backend,
  event: sinal.Event(
    span.StartMeasurements,
    span.StartMetadata(examples.RequestStartMetadata),
  ),
  handler: sinal.Handler(
    span.StopMeasurements(examples.ResponseMeasurements),
    span.StartMetadata(examples.RequestStartMetadata),
    Nil,
  ),
) -> Result(sinal.Attachment, sinal.AttachError) {
  let assert Ok(id) = sinal.handler_id("span-stop-measurements-for-start")
  sinal.attach(backend, id, event, handler, fn(_event, _failure) { Nil })
}
