// THROWAWAY: Does a shared event descriptor constrain emitted values?
import lab/blueprint.{type Codec, type EncodeError}

pub opaque type Event(measurements, metadata) {
  Event(
    name: List(String),
    measurements: Codec(measurements),
    metadata: Codec(metadata),
  )
}

pub fn event(
  name: List(String),
  measurements: Codec(m),
  metadata: Codec(d),
) -> Event(m, d) {
  Event(name, measurements, metadata)
}

pub type EmitError {
  EncodingFailed(EncodeError)
  BackendUnavailable
}

pub fn emit(
  _event: Event(m, d),
  _measurements: m,
  _metadata: d,
) -> Result(Nil, EmitError) {
  todo as "Synchronous telemetry bridge is outside the type experiment"
}
