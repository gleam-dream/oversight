//// The application's own Sinal event: a research request changed state.
////
//// It carries the research id as a `sinal/correlation.Correlation`, so an
//// observer follows a request through these events without a registry.
//// Packages do not carry `Correlation` yet, so Grind, Fabric and http_gun
//// events still join through `telemetry`'s bindings.

import gleam/option.{type Option}
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
  Transition(state: State, correlation: Option(Correlation))
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
  sinal.event(
    ["research_agent", "research", "state"],
    fields.empty(),
    fields.record({
      use state <- fields.parameter
      use correlation <- fields.parameter
      Transition(state:, correlation:)
    })
      |> fields.and(
        fields.enum(
          "state",
          [Queued, Researching, Publishing, Published, Failed, Cancelled],
          state_name,
        ),
        fn(t: Transition) { t.state },
      )
      |> fields.and(correlation.field(), fn(t) { t.correlation })
      |> fields.build,
  )
}

/// Announces that research `id` entered `state`. Ids come from
/// `app.start_research` (`correlation.unique`), so they always fit.
pub fn announce(id: String, state: State) -> Nil {
  sinal.emit(
    state_changed(),
    Nil,
    Transition(
      state:,
      correlation: option.from_result(correlation.from_string(id)),
    ),
  )
}
