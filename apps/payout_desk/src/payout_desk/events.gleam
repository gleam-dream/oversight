//// The application's own Sinal event: a payout request moved on. It
//// carries the request id as a `sinal/correlation.Correlation`, so an
//// observer follows one request from the agent's proposal to what the
//// seller was told. Grind's, Saga's and Fabric's own events are theirs.

import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

pub type Stage {
  /// The agent's gated call was admitted as an occurrence.
  Admitted
  /// The occurrence settled: released, rejected, expired, withdrawn or
  /// refused (`detail` says which).
  Settled
  /// The provider paid.
  Paid
  /// The provider did not pay.
  NotPaid
  /// Nobody knows yet whether the provider paid.
  Uncertain
  /// The seller was told what really happened.
  Told
}

pub type Moved {
  Moved(stage: Stage, detail: String, correlation: Correlation)
}

pub fn stage_name(stage: Stage) -> String {
  case stage {
    Admitted -> "admitted"
    Settled -> "settled"
    Paid -> "paid"
    NotPaid -> "not_paid"
    Uncertain -> "uncertain"
    Told -> "told"
  }
}

pub fn moved() -> sinal.Event(Nil, Moved) {
  sinal.event(["payout_desk", "payout", "moved"], fields.empty(), {
    use stage <- fields.include(
      fields.enum(
        "stage",
        [Admitted, Settled, Paid, NotPaid, Uncertain, Told],
        stage_name,
      ),
      get: fn(m: Moved) { m.stage },
    )
    use detail <- fields.include(fields.string("detail"), get: fn(m: Moved) {
      m.detail
    })
    use correlation <- fields.include(
      correlation.required_field(),
      get: fn(m: Moved) { m.correlation },
    )
    fields.success(Moved(stage:, detail:, correlation:))
  })
}

/// Announce that request `request` reached `stage`.
pub fn announce(request: String, stage: Stage, detail: String) -> Nil {
  sinal.emit(
    moved(),
    Nil,
    Moved(stage:, detail:, correlation: correlation.from_key(request)),
  )
}
