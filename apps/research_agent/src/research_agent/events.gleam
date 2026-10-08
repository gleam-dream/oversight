//// The application's own Sinal event: a research request changed state.
////
//// It carries the research id as a `sinal/correlation.Correlation`, so an
//// observer follows a request through these events without a registry.
//// Grind, Saga and http_gun carry it too (`job.with_correlation`,
//// `durable.with_correlation`, `remote.correlated`); Fabric events still
//// join through `telemetry`'s run binding, and llm_wire events not at all.

import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

/// Where a research request is. Refer to the constructors qualified: they
/// would otherwise collide with `domain.Published`.
pub type State {
  Queued
  Researching
  Publishing
  Published
  Failed
  Uncertain
  Cancelled
}

pub type Transition {
  Transition(state: State, correlation: Correlation)
}

pub fn state_name(state: State) -> String {
  case state {
    Queued -> "queued"
    Researching -> "researching"
    Publishing -> "publishing"
    Published -> "published"
    Failed -> "failed"
    Uncertain -> "uncertain"
    Cancelled -> "cancelled"
  }
}

pub fn state_changed() -> sinal.Event(Nil, Transition) {
  sinal.event(["research_agent", "research", "state"], fields.empty(), {
    use state <- fields.include(
      fields.enum(
        "state",
        [
          Queued,
          Researching,
          Publishing,
          Published,
          Failed,
          Uncertain,
          Cancelled,
        ],
        state_name,
      ),
      get: fn(t) { t.state },
    )
    use correlation <- fields.include(correlation.required_field(), get: fn(t) {
      t.correlation
    })
    fields.success(Transition(state:, correlation:))
  })
}

/// Announces that research `id` entered `state`.
pub fn announce(id: String, state: State) -> Nil {
  let correlation = correlation.from_key(id)
  sinal.emit(state_changed(), Nil, Transition(state:, correlation:))
}
