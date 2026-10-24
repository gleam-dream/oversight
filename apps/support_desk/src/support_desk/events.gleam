//// The desk's own Sinal events. A ticket is the unit of work the desk
//// chose its own correlation for: `ticket.opened` joins that correlation
//// to the fabric run id, and `ticket.answered` records how the agent's
//// final answer decoded. The collector in `support_desk/telemetry` uses
//// the first to attribute a run's events to its ticket.

import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

/// How the agent's final answer decoded.
pub type Answered {
  /// A `Resolution` matching the schema.
  AnsweredTyped
  /// Text that is not a `Resolution`.
  AnsweredUntyped
  /// The run ended without an answer.
  AnsweredNothing
}

pub type TicketMetadata {
  TicketOpened(ticket: Correlation, run: String)
}

pub type AnswerMetadata {
  TicketAnswered(ticket: Correlation, run: String, answer: Answered)
}

pub fn ticket_opened() -> sinal.Event(Nil, TicketMetadata) {
  sinal.event(["support_desk", "ticket", "opened"], fields.empty(), {
    use ticket <- fields.include(correlation.required_field(), get: fn(m) {
      m.ticket
    })
    use run <- fields.include(fields.string("run"), get: fn(m) { m.run })
    fields.success(TicketOpened(ticket:, run:))
  })
}

pub fn ticket_answered() -> sinal.Event(Nil, AnswerMetadata) {
  sinal.event(["support_desk", "ticket", "answered"], fields.empty(), answer())
}

/// The metadata of `ticket.answered`, exposed so a test can check that every
/// `Answered` constructor is in the `fields.enum` list.
pub fn answer() -> fields.Fields(AnswerMetadata) {
  use ticket <- fields.include(correlation.required_field(), get: fn(m) {
    m.ticket
  })
  use run <- fields.include(fields.string("run"), get: fn(m) { m.run })
  use answer <- fields.include(
    fields.enum(
      "answer",
      [AnsweredTyped, AnsweredUntyped, AnsweredNothing],
      fn(answer) {
        case answer {
          AnsweredTyped -> "typed"
          AnsweredUntyped -> "untyped"
          AnsweredNothing -> "nothing"
        }
      },
    ),
    get: fn(m) { m.answer },
  )
  fields.success(TicketAnswered(ticket:, run:, answer:))
}

pub fn opened(ticket: Correlation, run: String) -> Nil {
  sinal.emit(ticket_opened(), Nil, TicketOpened(ticket, run))
}

pub fn answered(ticket: Correlation, run: String, answer: Answered) -> Nil {
  sinal.emit(ticket_answered(), Nil, TicketAnswered(ticket, run, answer))
}
