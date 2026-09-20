// THROWAWAY: Project accepted Fabric reports onto a small Sinal event.
import lab/blueprint
import lab/fabric_agent as agent
import lab/llm_turn as model
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type ActionDisposition {
  ModelVisible
  HostFailure
  OutcomeUnknown
}

pub type AcceptedActionMeasurements {
  AcceptedActionMeasurements(turn: Int)
}

pub type AcceptedActionMetadata {
  AcceptedActionMetadata(call_id: model.CallId, disposition: ActionDisposition)
}

pub opaque type AcceptedActionFact {
  AcceptedActionFact(
    measurements: AcceptedActionMeasurements,
    metadata: AcceptedActionMetadata,
  )
}

pub fn accepted_action_fact(report: agent.ActionReport) -> AcceptedActionFact {
  let agent.ActionIdentity(_, _, turn, call_id) = agent.report_identity(report)
  let disposition = case agent.report_outcome(report) {
    agent.ModelVisible(_, _) -> ModelVisible
    agent.HostFailure(_) -> HostFailure
    agent.OutcomeUnknown(_) -> OutcomeUnknown
  }
  AcceptedActionFact(
    AcceptedActionMeasurements(turn),
    AcceptedActionMetadata(call_id, disposition),
  )
}

pub fn fact_measurements(
  fact: AcceptedActionFact,
) -> AcceptedActionMeasurements {
  fact.measurements
}

pub fn fact_metadata(fact: AcceptedActionFact) -> AcceptedActionMetadata {
  fact.metadata
}

pub fn action_event() -> sinal.Event(
  AcceptedActionMeasurements,
  AcceptedActionMetadata,
) {
  let measurements =
    fields.imap(
      fields.field("turn", blueprint.int()),
      AcceptedActionMeasurements,
      fn(measurements) {
        let AcceptedActionMeasurements(turn) = measurements
        turn
      },
    )
  let assert Ok(metadata) =
    fields.pair(
      fields.field("call_id", call_id_codec()),
      fields.field("disposition", disposition_codec()),
    )
  let metadata =
    fields.imap(
      metadata,
      fn(pair) {
        let #(call_id, disposition) = pair
        AcceptedActionMetadata(call_id, disposition)
      },
      fn(metadata) {
        let AcceptedActionMetadata(call_id, disposition) = metadata
        #(call_id, disposition)
      },
    )
  sinal.event(
    ["fabric", "action", "report", "accepted"],
    measurements,
    metadata,
  )
}

pub fn emit_accepted(
  backend: sinal.Backend,
  fact: AcceptedActionFact,
) -> Result(Nil, sinal.EmitError) {
  sinal.emit(backend, action_event(), fact.measurements, fact.metadata)
}

fn call_id_codec() -> blueprint.Codec(model.CallId) {
  blueprint.imap(blueprint.text(), model.CallId, fn(call_id) {
    let model.CallId(value) = call_id
    value
  })
}

fn disposition_codec() -> blueprint.Codec(ActionDisposition) {
  blueprint.new(
    fn(disposition) {
      let encoded = case disposition {
        ModelVisible -> "model-visible"
        HostFailure -> "host-failure"
        OutcomeUnknown -> "outcome-unknown"
      }
      Ok(value.Text(encoded))
    },
    fn(raw) {
      case raw {
        value.Text("model-visible") -> Ok(ModelVisible)
        value.Text("host-failure") -> Ok(HostFailure)
        value.Text("outcome-unknown") -> Ok(OutcomeUnknown)
        _ -> Error(blueprint.CannotDecode("unknown Fabric action disposition"))
      }
    },
  )
}
