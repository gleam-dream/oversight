//// The live desk: one process per person on duty. A moderator process
//// subscribes to the queues of the decision sets its person holds and is
//// told after each commit that changes one; it then takes the next card
//// nobody else holds, reads it, and gives a verdict. A reviewer process
//// subscribes to the point's review queue and gives reviews the same way.
////
//// A process keeps no truth: what it holds between two transactions is
//// a `decisions.Ticket`, as a page would. Which card a person holds is a
//// claim row in the store, written in the transaction that opens the
//// card and removed in the one that decides it, so two moderators never
//// work one card and a moderator restarted after a crash finds its own
//// claim again.
////
//// A card shown before someone else corrected it is refused
//// (`OutputChanged`); the hint about that occurrence is what tells the
//// moderator to look again. When the store drops hints for a process that
//// is not keeping up, the process is told how many it missed and reads
//// its queues again.
////
//// A verdict the gated tool refuses at release rolls back. The tool
//// refused the verdict, not the person: in a transaction of its own, the
//// desk keeps the attempt on the record as a `verdict_refused` entry,
//// reports the refused release as the world event
//// `point.release_refused`, which supersedes every waiting occurrence
//// about the post, and removes the claim. The card has then ended, so it
//// is in nobody's queue, and its settlement says the release was refused.
//// When that transaction fails, the process crashes before it lets go of
//// the claim: its supervisor starts it again, and the new process finds
//// the claim, opens the card again and records the refusal of that
//// showing. A refusal is recorded once per card, after a restart too.

import decisions.{type Desk, type Ticket}
import decisions/model
import decisions/occurrence
import decisions/view
import decisions/vocabulary.{
  type Validator, type Verdict, Approve, Correct, Reject, Validator,
}
import decisions_otp/live.{type Hint}
import decisions_otp/store.{type Store, type Tx}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import moderation_desk/domain.{type Action}
import moderation_desk/models
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/telemetry
import moderation_desk/wiring
import sinal

/// What a person at the desk does.
pub type Role {
  /// Gives verdicts on waiting occurrences.
  Moderating
  /// Reviews sampled occurrences after their release.
  Reviewing
}

/// One person at the desk.
pub type Person {
  Person(
    validator: Validator,
    role: Role,
    /// How long the person reads a card before giving a verdict, in
    /// milliseconds. The process is busy meanwhile, as the person is.
    think_ms: Int,
    /// How long an idle process waits before it looks again without a
    /// hint, in milliseconds. Hints make this a safety net.
    poll_ms: Int,
    on_duty: Bool,
  )
}

/// What a desk process has done, for a test or an operator.
pub type Snapshot {
  Snapshot(
    decided: Int,
    reviewed: Int,
    /// Verdicts refused because the card was shown before someone else
    /// corrected the output.
    stale: Int,
    /// Hints about a card whose verdict was refused, received after the
    /// refusal: what tells the person to look at it again.
    told: Int,
    /// Hints the store dropped for this process.
    missed: Int,
    /// The card the process last held.
    last: Option(Ticket),
  )
}

pub opaque type Message {
  Look
  Told(Hint)
  Duty(on: Bool)
  Pace(think_ms: Int)
  Inspect(reply: Subject(Snapshot))
}

type State {
  State(
    person: Person,
    /// Who the application is, as its telemetry events say.
    source: String,
    store: Store,
    desk: Desk(Action, Tx),
    self: Subject(Message),
    hints: Subject(Hint),
    /// The subscription to the card the process last held.
    watching: Option(store.Subscription),
    /// The card whose verdict was refused last, while the process still
    /// watches it.
    refused: Option(String),
    snapshot: Snapshot,
    polling: Bool,
  )
}

/// A desk process as a child of the application's tree, registered under
/// `name` so that a restarted process takes the same name.
pub fn supervised(
  store_name: store.Name,
  desk: Desk(Action, Tx),
  person: Person,
  name: Name(Message),
  source source: String,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(self) {
      // The store as it runs now: a restarted store is a new one.
      use s <- result.try(
        store.named(store_name) |> result.replace_error("no store is running"),
      )
      let hints = process.new_subject()
      let topics = case person.role {
        Moderating -> list.map(person.validator.holds, live.ToQueue)
        Reviewing -> [live.ToReviews(point.name)]
      }
      // A person whose queues cannot be watched would wait for hints that
      // never come: the process does not start, and its supervisor tries
      // again.
      use _ <- result.try(
        list.try_map(topics, store.subscribe(s, _, hints))
        |> result.replace_error("the store took no subscription"),
      )
      process.send(self, Look)
      let selector =
        process.new_selector()
        |> process.select(self)
        |> process.select_map(hints, Told)
      State(
        person:,
        source:,
        store: s,
        desk:,
        self:,
        hints:,
        watching: None,
        refused: None,
        snapshot: Snapshot(0, 0, 0, 0, 0, None),
        polling: False,
      )
      |> actor.initialised
      |> actor.selecting(selector)
      |> actor.returning(Nil)
      |> Ok
    })
    |> actor.named(name)
    |> actor.on_message(handle)
    |> actor.start
  })
}

/// Put the person on or off duty. Off duty, the process keeps listening
/// but takes no card.
pub fn on_duty(name: Name(Message), on: Bool) -> Nil {
  process.send(process.named_subject(name), Duty(on:))
}

/// Change how long the person reads each card.
pub fn pace(name: Name(Message), think_ms: Int) -> Nil {
  process.send(process.named_subject(name), Pace(think_ms:))
}

/// Ask the process to look at its queue now.
pub fn look(name: Name(Message)) -> Nil {
  process.send(process.named_subject(name), Look)
}

/// What the process has done so far. It waits while the person reads a
/// card.
pub fn snapshot(name: Name(Message)) -> Snapshot {
  process.call(process.named_subject(name), 10_000, Inspect)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Inspect(reply:) -> {
      process.send(reply, state.snapshot)
      actor.continue(state)
    }
    Duty(on:) -> {
      let state = State(..state, person: Person(..state.person, on_duty: on))
      actor.continue(work(state))
    }
    Pace(think_ms:) ->
      actor.continue(State(..state, person: Person(..state.person, think_ms:)))
    Look -> actor.continue(work(State(..state, polling: False)))
    Told(live.Changed(occurrence:, ..)) -> {
      let about_last = state.refused == Some(occurrence)
      let state = case about_last {
        True ->
          State(
            ..state,
            snapshot: Snapshot(..state.snapshot, told: state.snapshot.told + 1),
          )
        False -> state
      }
      actor.continue(work(state))
    }
    Told(live.Missed(count:)) -> {
      sinal.emit(
        telemetry.hints_missed(),
        telemetry.Count(count),
        telemetry.Missed(
          source: state.source,
          moderator: state.person.validator.subject,
        ),
      )
      let state =
        State(
          ..state,
          snapshot: Snapshot(
            ..state.snapshot,
            missed: state.snapshot.missed + count,
          ),
        )
      // Hints were dropped: the queue is read again in full.
      actor.continue(work(state))
    }
  }
}

/// Take cards until none is left, then wait for a hint or the next poll.
fn work(state: State) -> State {
  case state.person.on_duty {
    False -> state
    True ->
      case take(state) {
        // After a refusal, wait to be told: the hint about the card, or
        // the next poll, says when to look again.
        Some(State(refused: Some(_), ..) as state) -> poll(state)
        Some(state) -> work(state)
        None -> poll(state)
      }
  }
}

fn poll(state: State) -> State {
  case state.polling {
    True -> state
    False -> {
      process.send_after(state.self, state.person.poll_ms, Look)
      State(..state, polling: True)
    }
  }
}

/// A card opened for the person: its ticket, who it is about, and the
/// verdict they reached reading it.
type Opened {
  Opened(ticket: Ticket, subject: vocabulary.Subject, verdict: Verdict(Action))
}

/// Why a card could not be opened.
type NotOpened {
  /// Another person holds it.
  Taken
  /// The desk refused to open it.
  Unopened(decisions.Refusal)
}

/// Open the first card of the queue that nobody else holds, read it, and
/// give the verdict. `None` when there is none to take.
fn take(state: State) -> Option(State) {
  let handle = store.handle(state.store)
  let candidates = case state.person.role {
    Moderating -> store.queue_page_for(handle, state.person.validator, 20)
    Reviewing -> store.review_queue_of(handle, point.name, 20)
  }
  list.find_map(candidates, fn(id) {
    open(state, id) |> result.replace_error(Nil)
  })
  |> option.from_result
  |> option.map(fn(opened) {
    // Watch the card from now on, and stop watching the one before.
    case state.watching {
      Some(subscription) -> store.unsubscribe(state.store, subscription)
      None -> Nil
    }
    // Without a subscription to the card, the next poll is what tells the
    // person to look again after a refusal.
    let watching =
      store.subscribe(
        state.store,
        live.ToOccurrence(opened.ticket.occurrence),
        state.hints,
      )
      |> option.from_result
    process.sleep(state.person.think_ms)
    State(
      ..state,
      watching:,
      refused: None,
      snapshot: Snapshot(..state.snapshot, last: Some(opened.ticket)),
    )
    |> give(opened, 3)
  })
}

fn open(state: State, id: String) -> Result(Opened, NotOpened) {
  let me = state.person.validator.subject
  store.transaction(state.store, fn(tx) {
    use Nil <- result.try(
      store.lock(tx, "claim:" <> id)
      |> result.map_error(fn(error) { Unopened(decisions.StoreFailed(error)) }),
    )
    use Nil <- result.try(case store.get(tx, wiring.claims, id) {
      Ok(holder) if holder != me -> Error(Taken)
      _ -> Ok(store.put(tx, wiring.claims, id, me))
    })
    use card <- result.try(
      decisions.open(
        state.desk,
        tx,
        occurrence: id,
        by: state.person.validator,
        latest: wiring.latest(tx),
      )
      |> result.map_error(Unopened),
    )
    // The person sees the context the model had, read by the model's own
    // reader from the record. A rule model read only the post.
    let shown = view.of(card, content: wiring.content(state.store))
    use post <- result.try(
      case
        view.context(
          decisions.shown(card),
          with: models.reader(),
          content: wiring.content(state.store),
        )
      {
        Ok(context) -> Ok(context.post)
        Error(_) ->
          models.post_of(
            decisions.shown(card).context,
            model.recorded(
              context: list.filter_map(shown.pushed, fn(item) {
                item.content |> result.map(fn(text) { #(item.ref, text) })
              }),
              reads: [],
            ),
          )
      }
      |> result.replace_error(Unopened(decisions.UnknownOccurrence)),
    )
    Ok(Opened(
      ticket: decisions.ticket(card),
      subject: decisions.shown(card).subject,
      verdict: scripted.judge(
        post,
        shown.standing,
        corrected: shown.standing != shown.recommendation.output,
      ),
    ))
  })
}

/// Give the verdict on the ticket's card, in a transaction that also
/// removes the claim. A transient refusal is tried again up to `tries`
/// times; any other drops the card, which stays in the queue if it still
/// waits.
fn give(state: State, opened: Opened, tries: Int) -> State {
  let person = state.person
  let id = opened.ticket.occurrence
  let outcome =
    store.transaction(state.store, fn(tx) {
      use card <- result.try(decisions.resume(
        state.desk,
        tx,
        opened.ticket,
        by: person.validator,
      ))
      use _ <- result.try(case person.role {
        Moderating -> decisions.decide(state.desk, tx, card, opened.verdict)
        Reviewing -> decisions.review(state.desk, tx, card, opened.verdict)
      })
      store.remove(tx, wiring.claims, id)
      Ok(Nil)
    })
  case outcome {
    Ok(Nil) -> {
      sinal.emit(
        telemetry.verdict_given(),
        telemetry.Count(1),
        telemetry.Verdict(
          source: state.source,
          occurrence: id,
          moderator: person.validator.subject,
          given: case person.role, opened.verdict {
            Reviewing, _ -> telemetry.Reviewed
            Moderating, Approve -> telemetry.Approved
            Moderating, Correct(..) -> telemetry.Corrected
            Moderating, Reject(..) -> telemetry.Rejected
          },
        ),
      )
      let snapshot = case person.role {
        Moderating ->
          Snapshot(..state.snapshot, decided: state.snapshot.decided + 1)
        Reviewing ->
          Snapshot(..state.snapshot, reviewed: state.snapshot.reviewed + 1)
      }
      State(..state, snapshot:)
    }
    Error(refusal) ->
      case decisions.disposition(refusal), tries > 1 {
        decisions.Retry, True -> {
          process.sleep(5)
          give(state, opened, tries - 1)
        }
        _, _ -> refused(state, opened, refusal)
      }
  }
}

fn refused(state: State, opened: Opened, refusal: decisions.Refusal) -> State {
  let me = state.person.validator.subject
  let id = opened.ticket.occurrence
  case refusal {
    // The tool refused the verdict, not the person: the card ends for
    // everyone, with the attempt on the record. The process must not go
    // on without that commit: it crashes still holding the claim, and the
    // restarted process opens the card again.
    decisions.ToolRefused(rollback:, ..) -> {
      let assert Ok(Nil) =
        store.transaction(state.store, fn(tx) {
          // The subject lock before the record, in the order `happened`
          // takes them, so an edit of the post cannot deadlock with this.
          use Nil <- result.try(
            wiring.lock_subject(tx, opened.subject)
            |> result.map_error(decisions.StoreFailed),
          )
          use _ <- result.try(decisions.record_refusal(state.desk, tx, rollback))
          use _ <- result.try(decisions.happened(
            state.desk,
            tx,
            point.release_refused,
            about: opened.subject,
          ))
          release_claim(tx, id, me)
          Ok(Nil)
        })
        as "the refused verdict was not recorded"
      Nil
    }
    _ -> {
      let _ =
        store.transaction(state.store, fn(tx) {
          release_claim(tx, id, me)
          Ok(Nil)
        })
      Nil
    }
  }
  let stale = refusal == decisions.OutputChanged
  sinal.emit(
    telemetry.card_refused(),
    telemetry.Count(1),
    telemetry.Refused(
      source: state.source,
      occurrence: id,
      moderator: me,
      stale:,
      reason: decisions.describe(refusal),
    ),
  )
  State(..state, refused: Some(id), snapshot: case stale {
    True -> Snapshot(..state.snapshot, stale: state.snapshot.stale + 1)
    False -> state.snapshot
  })
}

/// Remove `me`'s claim on the card, in the caller's transaction.
fn release_claim(tx: Tx, id: String, me: String) -> Nil {
  case store.get(tx, wiring.claims, id) {
    Ok(holder) if holder == me -> store.remove(tx, wiring.claims, id)
    _ -> Nil
  }
}

/// The decision sets a moderator, a senior and a reviewer hold.
pub fn moderator(name: String) -> Validator {
  Validator(subject: name, holds: [point.moderators])
}

pub fn senior(name: String) -> Validator {
  Validator(subject: name, holds: [point.moderators, point.seniors])
}

pub fn reviewer(name: String) -> Validator {
  Validator(subject: name, holds: [point.reviewers])
}

/// Open a card and give a verdict on it in one transaction, as a person
/// working outside the desk processes would.
pub fn decide_now(
  s: Store,
  desk: Desk(Action, Tx),
  validator: Validator,
  id: String,
  verdict: Verdict(Action),
) -> Result(occurrence.Occurrence(Action), decisions.Refusal) {
  store.transaction(s, fn(tx) {
    use card <- result.try(decisions.open(
      desk,
      tx,
      occurrence: id,
      by: validator,
      latest: wiring.latest(tx),
    ))
    decisions.decide(desk, tx, card, verdict)
  })
}
