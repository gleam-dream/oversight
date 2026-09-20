// THROWAWAY: Project a pure Grind cancellation transition onto a Sinal event.
import lab/blueprint
import lab/grind
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type CancellationKind {
  CancelledWhileInactive
  CancellationRequested
  AlreadyCancelled
  AlreadyFinishedSucceeded
  AlreadyFinishedFailed
  AlreadyFinishedCancelled
}

pub type CancellationMeasurements {
  CancellationMeasurements(job_id: String)
}

pub type CancellationMetadata {
  CancellationMetadata(kind: CancellationKind, terminal: Bool)
}

pub opaque type CancellationFact(o, e) {
  CancellationFact(
    job_id: grind.JobId,
    next_state: grind.JobState(o, e),
    transition: grind.CancellationTransition(o, e),
    measurements: CancellationMeasurements,
    metadata: CancellationMetadata,
  )
}

pub fn cancellation_fact(
  job_id: grind.JobId,
  state: grind.JobState(o, e),
) -> CancellationFact(o, e) {
  let #(next_state, transition) = grind.cancellation_transition(state)
  let terminal = case next_state {
    grind.JobFinished(_) -> True
    _ -> False
  }
  CancellationFact(
    job_id,
    next_state,
    transition,
    CancellationMeasurements(grind.job_id_value(job_id)),
    CancellationMetadata(cancellation_kind(transition), terminal),
  )
}

pub fn fact_job_id(fact: CancellationFact(o, e)) -> grind.JobId {
  fact.job_id
}

pub fn fact_next_state(fact: CancellationFact(o, e)) -> grind.JobState(o, e) {
  fact.next_state
}

pub fn fact_transition(
  fact: CancellationFact(o, e),
) -> grind.CancellationTransition(o, e) {
  fact.transition
}

pub fn fact_measurements(
  fact: CancellationFact(o, e),
) -> CancellationMeasurements {
  fact.measurements
}

pub fn fact_metadata(fact: CancellationFact(o, e)) -> CancellationMetadata {
  fact.metadata
}

pub fn cancellation_event() -> sinal.Event(
  CancellationMeasurements,
  CancellationMetadata,
) {
  let measurements =
    fields.imap(
      fields.field("job_id", blueprint.text()),
      CancellationMeasurements,
      fn(measurements) {
        let CancellationMeasurements(job_id) = measurements
        job_id
      },
    )
  let assert Ok(metadata) =
    fields.pair(
      fields.field("transition", cancellation_kind_codec()),
      fields.field("terminal", blueprint.bool()),
    )
  let metadata =
    fields.imap(
      metadata,
      fn(pair) {
        let #(kind, terminal) = pair
        CancellationMetadata(kind, terminal)
      },
      fn(metadata) {
        let CancellationMetadata(kind, terminal) = metadata
        #(kind, terminal)
      },
    )
  sinal.event(
    ["grind", "job", "cancellation", "decided"],
    measurements,
    metadata,
  )
}

pub fn emit_decided(
  backend: sinal.Backend,
  fact: CancellationFact(o, e),
) -> Result(Nil, sinal.EmitError) {
  sinal.emit(backend, cancellation_event(), fact.measurements, fact.metadata)
}

fn cancellation_kind(
  transition: grind.CancellationTransition(o, e),
) -> CancellationKind {
  case transition {
    grind.CancelledWhileInactive -> CancelledWhileInactive
    grind.CancellationRequested -> CancellationRequested
    grind.AlreadyCancelled -> AlreadyCancelled
    grind.AlreadyFinished(grind.JobSucceeded(_)) -> AlreadyFinishedSucceeded
    grind.AlreadyFinished(grind.JobFailed(_)) -> AlreadyFinishedFailed
    grind.AlreadyFinished(grind.JobCancelled) -> AlreadyFinishedCancelled
  }
}

fn cancellation_kind_codec() -> blueprint.Codec(CancellationKind) {
  blueprint.new(
    fn(kind) {
      let encoded = case kind {
        CancelledWhileInactive -> "cancelled-inactive"
        CancellationRequested -> "requested"
        AlreadyCancelled -> "already-cancelled"
        AlreadyFinishedSucceeded -> "already-finished-succeeded"
        AlreadyFinishedFailed -> "already-finished-failed"
        AlreadyFinishedCancelled -> "already-finished-cancelled"
      }
      Ok(value.Text(encoded))
    },
    fn(raw) {
      case raw {
        value.Text("cancelled-inactive") -> Ok(CancelledWhileInactive)
        value.Text("requested") -> Ok(CancellationRequested)
        value.Text("already-cancelled") -> Ok(AlreadyCancelled)
        value.Text("already-finished-succeeded") -> Ok(AlreadyFinishedSucceeded)
        value.Text("already-finished-failed") -> Ok(AlreadyFinishedFailed)
        value.Text("already-finished-cancelled") -> Ok(AlreadyFinishedCancelled)
        _ ->
          Error(blueprint.CannotDecode("unknown Grind cancellation transition"))
      }
    },
  )
}
