//// What an operator watches. The application emits its own Sinal events
//// (a post received, a post recommended, a verdict, a refused card,
//// missed hints) beside the library's (`decisions_otp/telemetry`), and a
//// collector process turns both into counts.
////
//// Every event is emitted after the transaction it describes has
//// committed. Handlers run in the emitting process and only send one
//// message to the collector. The collector is a child of the
//// application's tree under a name, so a handler addresses its
//// replacement after a restart; the counts the old collector held are
//// lost with it. Handlers are node-wide, so every event carries its
//// `source` and a collector counts only its own application's.

import decisions_otp/telemetry as library
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal.{type Event}
import sinal/fields

/// How many times something happened, as an event's measurement.
pub type Count {
  Count(count: Int)
}

fn count_fields() -> fields.Fields(Count) {
  use count <- fields.include(fields.int("count"), get: fn(m: Count) { m.count })
  fields.success(Count(count:))
}

/// `[moderation_desk, post, received]` metadata. `duplicate` is a
/// delivery of a post revision already admitted.
pub type Received {
  Received(
    /// Which application emitted it.
    source: String,
    post: String,
    duplicate: Bool,
  )
}

pub fn post_received() -> Event(Count, Received) {
  let metadata = {
    use source <- fields.include(fields.string("source"), get: fn(m: Received) {
      m.source
    })
    use post <- fields.include(fields.string("post"), get: fn(m: Received) {
      m.post
    })
    use duplicate <- fields.include(
      fields.bool("duplicate"),
      get: fn(m: Received) { m.duplicate },
    )
    fields.success(Received(source:, post:, duplicate:))
  }
  sinal.event(["moderation_desk", "post", "received"], count_fields(), metadata)
}

/// What the policy said about a fresh recommendation.
pub type Outcome {
  /// It proceeded without a person.
  Proceeded
  /// It waits for a person.
  Waiting
}

pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Proceeded -> "proceeded"
    Waiting -> "waiting"
  }
}

/// `[moderation_desk, post, recommended]` metadata.
pub type Recommended {
  Recommended(
    /// Which application emitted it.
    source: String,
    occurrence: String,
    stage: String,
    outcome: Outcome,
    sampled: Bool,
  )
}

pub fn post_recommended() -> Event(Count, Recommended) {
  let metadata = {
    use source <- fields.include(
      fields.string("source"),
      get: fn(m: Recommended) { m.source },
    )
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(m: Recommended) { m.occurrence },
    )
    use stage <- fields.include(fields.string("stage"), get: fn(m: Recommended) {
      m.stage
    })
    use outcome <- fields.include(
      fields.enum("outcome", [Proceeded, Waiting], outcome_name),
      get: fn(m: Recommended) { m.outcome },
    )
    use sampled <- fields.include(
      fields.bool("sampled"),
      get: fn(m: Recommended) { m.sampled },
    )
    fields.success(Recommended(source:, occurrence:, stage:, outcome:, sampled:))
  }
  sinal.event(
    ["moderation_desk", "post", "recommended"],
    count_fields(),
    metadata,
  )
}

/// What a person at the desk gave.
pub type Given {
  Approved
  Corrected
  Rejected
  Reviewed
}

pub fn given_name(given: Given) -> String {
  case given {
    Approved -> "approved"
    Corrected -> "corrected"
    Rejected -> "rejected"
    Reviewed -> "reviewed"
  }
}

/// `[moderation_desk, verdict, given]` metadata.
pub type Verdict {
  Verdict(
    /// Which application emitted it.
    source: String,
    occurrence: String,
    moderator: String,
    given: Given,
  )
}

pub fn verdict_given() -> Event(Count, Verdict) {
  let metadata = {
    use source <- fields.include(fields.string("source"), get: fn(m: Verdict) {
      m.source
    })
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(m: Verdict) { m.occurrence },
    )
    use moderator <- fields.include(
      fields.string("moderator"),
      get: fn(m: Verdict) { m.moderator },
    )
    use given <- fields.include(
      fields.enum(
        "given",
        [Approved, Corrected, Rejected, Reviewed],
        given_name,
      ),
      get: fn(m: Verdict) { m.given },
    )
    fields.success(Verdict(source:, occurrence:, moderator:, given:))
  }
  sinal.event(["moderation_desk", "verdict", "given"], count_fields(), metadata)
}

/// `[moderation_desk, card, refused]` metadata: the desk refused a
/// verdict on a card a moderator held. `stale` is a card shown before
/// someone else corrected the output.
pub type Refused {
  Refused(
    /// Which application emitted it.
    source: String,
    occurrence: String,
    moderator: String,
    stale: Bool,
    reason: String,
  )
}

pub fn card_refused() -> Event(Count, Refused) {
  let metadata = {
    use source <- fields.include(fields.string("source"), get: fn(m: Refused) {
      m.source
    })
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(m: Refused) { m.occurrence },
    )
    use moderator <- fields.include(
      fields.string("moderator"),
      get: fn(m: Refused) { m.moderator },
    )
    use stale <- fields.include(fields.bool("stale"), get: fn(m: Refused) {
      m.stale
    })
    use reason <- fields.include(fields.string("reason"), get: fn(m: Refused) {
      m.reason
    })
    fields.success(Refused(source:, occurrence:, moderator:, stale:, reason:))
  }
  sinal.event(["moderation_desk", "card", "refused"], count_fields(), metadata)
}

/// `[moderation_desk, hints, missed]` metadata: the store dropped hints
/// for a moderator who was not keeping up; `count` is how many.
pub type Missed {
  Missed(
    /// Which application emitted it.
    source: String,
    moderator: String,
  )
}

pub fn hints_missed() -> Event(Count, Missed) {
  let metadata = {
    use source <- fields.include(fields.string("source"), get: fn(m: Missed) {
      m.source
    })
    use moderator <- fields.include(
      fields.string("moderator"),
      get: fn(m: Missed) { m.moderator },
    )
    fields.success(Missed(source:, moderator:))
  }
  sinal.event(["moderation_desk", "hints", "missed"], count_fields(), metadata)
}

// -- The collector -------------------------------------------------------------------

/// The numbers an operator watches.
pub type Numbers {
  Numbers(
    received: Int,
    duplicates: Int,
    by_rules: Int,
    by_classifier: Int,
    proceeded: Int,
    waited: Int,
    sampled: Int,
    deadlines: Int,
    raised: Int,
    /// Attempts the application's own handlers failed, counted toward
    /// setting a job aside.
    jobs_failed: Int,
    /// Deliveries rolled back for a transient reason and not counted.
    jobs_retried: Int,
    /// Jobs the runtime dropped because the verb refused for good.
    jobs_dropped: Int,
    set_aside: Int,
    triggers_worked: Int,
    settlements: Int,
    wakes: Int,
    approved: Int,
    corrected: Int,
    rejected: Int,
    reviewed: Int,
    stale_cards: Int,
    other_refusals: Int,
    hints_missed: Int,
  )
}

pub opaque type Message {
  Add(key: String, count: Int)
  Snapshot(reply: Subject(Dict(String, Int)))
}

/// The collector as a child of the application's tree, registered under
/// `name`. Its process attaches one handler per event while it starts, all
/// or nothing, and owns them: they live as long as this process, and sinal
/// detaches them when it stops or crashes. Each handler counts only the
/// events of the application instance called `source`.
pub fn supervised(
  name: Name(Message),
  source source: String,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new_with_initialiser(5000, fn(_) {
      use _attachments <- result.try(
        subscriptions(name, source)
        |> list.index_map(fn(subscription, index) {
          // Stable ids: a restarted collector takes them over from the
          // incarnation it replaces, so no event is counted twice.
          sinal.with_id(subscription, source <> ":" <> int.to_string(index))
        })
        |> sinal.attach_all
        |> result.map_error(sinal.describe_scope_error),
      )
      actor.initialised(dict.new()) |> actor.returning(Nil) |> Ok
    })
    |> actor.named(name)
    |> actor.on_message(fn(counts, message) {
      case message {
        Add(key:, count:) ->
          actor.continue(
            dict.upsert(counts, key, fn(found) {
              case found {
                option.Some(n) -> n + count
                option.None -> count
              }
            }),
          )
        Snapshot(reply:) -> {
          process.send(reply, counts)
          actor.continue(counts)
        }
      }
    })
    |> actor.start
  })
}

/// The counts so far.
pub fn numbers(name: Name(Message)) -> Numbers {
  let counts = process.call(process.named_subject(name), 5000, Snapshot)
  let get = fn(key) { dict.get(counts, key) |> result.unwrap(0) }
  Numbers(
    received: get("received"),
    duplicates: get("duplicates"),
    by_rules: get("by_rules"),
    by_classifier: get("by_classifier"),
    proceeded: get("proceeded"),
    waited: get("waited"),
    sampled: get("sampled"),
    deadlines: get("deadlines"),
    raised: get("raised"),
    jobs_failed: get("jobs_failed"),
    jobs_retried: get("jobs_retried"),
    jobs_dropped: get("jobs_dropped"),
    set_aside: get("set_aside"),
    triggers_worked: get("triggers_worked"),
    settlements: get("settlements"),
    wakes: get("wakes"),
    approved: get("approved"),
    corrected: get("corrected"),
    rejected: get("rejected"),
    reviewed: get("reviewed"),
    stale_cards: get("stale_cards"),
    other_refusals: get("other_refusals"),
    hints_missed: get("hints_missed"),
  )
}

/// One subscription per event, each sending its count to the collector
/// named `name`.
fn subscriptions(
  name: Name(Message),
  source: String,
) -> List(sinal.Subscription) {
  let add = fn(from: String, key: String, count: Int) {
    case from == source {
      True -> process.send(process.named_subject(name), Add(key, count))
      False -> Nil
    }
  }
  [
    sinal.subscription(post_received(), fn(_, m) {
      case m.duplicate {
        True -> add(m.source, "duplicates", 1)
        False -> add(m.source, "received", 1)
      }
    }),
    sinal.subscription(post_recommended(), fn(_, m) {
      add(m.source, "by_" <> m.stage, 1)
      add(m.source, outcome_name(m.outcome) |> rename_outcome, 1)
      case m.sampled {
        True -> add(m.source, "sampled", 1)
        False -> Nil
      }
    }),
    sinal.subscription(verdict_given(), fn(_, m) {
      add(m.source, given_name(m.given), 1)
    }),
    sinal.subscription(card_refused(), fn(_, m) {
      case m.stale {
        True -> add(m.source, "stale_cards", 1)
        False -> add(m.source, "other_refusals", 1)
      }
    }),
    sinal.subscription(hints_missed(), fn(c, m) {
      add(m.source, "hints_missed", c.count)
    }),
    sinal.subscription(library.model_failed(), fn(_, m) {
      case m.failure {
        library.ModelDeadline -> add(m.source, "deadlines", 1)
        library.ModelRaised -> add(m.source, "raised", 1)
      }
    }),
    sinal.subscription(library.job_failed(), fn(_, m) {
      // A transient failure is reported with no attempt counted.
      case m.attempts {
        0 -> add(m.source, "jobs_retried", 1)
        _ -> add(m.source, "jobs_failed", 1)
      }
    }),
    sinal.subscription(library.job_dropped(), fn(_, m) {
      add(m.source, "jobs_dropped", 1)
    }),
    sinal.subscription(library.job_set_aside(), fn(_, m) {
      add(m.source, "set_aside", 1)
    }),
    sinal.subscription(library.trigger_worked(), fn(_, m) {
      add(m.source, "triggers_worked", 1)
    }),
    sinal.subscription(library.settlement_delivered(), fn(_, m) {
      add(m.source, "settlements", 1)
    }),
    sinal.subscription(library.wake_delivered(), fn(_, m) {
      add(m.source, "wakes", 1)
    }),
  ]
}

fn rename_outcome(name: String) -> String {
  case name {
    "waiting" -> "waited"
    other -> other
  }
}
