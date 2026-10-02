//// The application's own Sinal event: a research request changed state.
////
//// It carries the research id as a `sinal/correlation.Correlation`, so an
//// observer follows a request through these events without a registry.
//// http_gun carries it too (`remote.correlated`); Grind, Fabric, llm_wire and
//// Saga events still join through `telemetry`'s bindings.

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
    Cancelled -> "cancelled"
  }
}

pub fn state_changed() -> sinal.Event(Nil, Transition) {
  sinal.event(["research_agent", "research", "state"], fields.empty(), {
    use state <- fields.include(
      fields.enum(
        "state",
        [Queued, Researching, Publishing, Published, Failed, Cancelled],
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

/// Announces that research `id` entered `state`. Ids come from
/// `app.start_research` (`correlation.unique`), so they always fit; an id
/// that does not is not announced.
pub fn announce(id: String, state: State) -> Nil {
  case correlation.from_string(id) {
    Ok(correlation) ->
      sinal.emit(state_changed(), Nil, Transition(state:, correlation:))
    Error(_) -> Nil
  }
}
