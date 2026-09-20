// THROWAWAY: A start callback cannot attach to the stop descriptor.
import consumers/span_events as examples
import lab/sinal
import lab/sinal_span as span

pub fn invalid(
  event: sinal.Event(
    span.StopMeasurements(examples.ResponseMeasurements),
    span.StopMetadata(examples.RequestStopMetadata),
  ),
  handler: sinal.Handler(
    span.StartMeasurements,
    span.StartMetadata(examples.RequestStartMetadata),
    Nil,
  ),
) -> Result(sinal.Attachment, sinal.AttachError) {
  let assert Ok(id) = sinal.handler_id("span-start-for-stop")
  sinal.attach(id, event, handler, fn(_failure) { Nil })
}
