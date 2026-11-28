//// The work that runs outside a request, as Grind jobs.
////
//// - `admit` keeps an inbound message, supersedes what the contact's earlier
////   messages started, records that this message expects a registration
////   (`decisions.expect`), and admits a `clinic.register` job, all in one
////   transaction. A redelivered message admits nothing.
//// - `clinic.register` runs the model outside any transaction, with a
////   deadline, and recommends under the message's key, or records the
////   failed attempt (pointing at the provider exchange when there was one)
////   and lets Grind retry (`decisions_otp/isolated.recommend`). A newer
////   message that superseded the key in between makes the record refuse
////   both, and the job ends done.
//// - The settlement follower admits a `clinic.confirm` job for a released
////   registration, in the transaction that delivers the settlement notice.
//// - `clinic.confirm` sends Ana her confirmation under the release key and
////   reports the effect: performed, not performed, or uncertain until a
////   lookup by the key settles it.
////
//// Wake-ups (escalation and validity) are delivered by
//// `decisions_postgres.wake_worker`, registered by the composition root.

import clinic_registration/domain.{type Inbound, type Registration}
import clinic_registration/llm
import clinic_registration/messaging.{type Messaging}
import clinic_registration/store
import clinic_registration/telemetry
import decisions.{type Desk, type Refusal}
import decisions/model
import decisions/occurrence
import decisions/vocabulary.{NotPerformed, Performed, Ref, Uncertain}
import decisions_otp/isolated
import decisions_postgres
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import grind
import grind/job
import grind/worker.{type Worker}
import http_gun
import pog
import sinal/correlation

/// The queue the clinic's own jobs run in.
pub const queue = "clinic"

/// Everything the jobs need, built by the composition root before the
/// runtime starts.
pub type Env {
  Env(
    jobs: grind.Grind,
    /// The pool the decision record's transactions start on.
    pool: decisions_postgres.Pool,
    desk: Desk(Registration, decisions_postgres.Tx),
    configuration: llm.Configuration,
    provider: llm.Provider,
    llm_client: http_gun.Client,
    messaging: Messaging,
    /// The wait before a failed model attempt is tried again.
    retry_after: Duration,
    /// How many model attempts one message gets.
    max_attempts: Int,
    /// The wait before an uncertain confirmation is looked up.
    reconcile_after: Duration,
    /// Runs after the model answered and before the recommendation's
    /// transaction. Production passes a function that does nothing; a test
    /// kills the worker here.
    after_model: fn(String) -> Nil,
  )
}

// -- Admission -------------------------------------------------------------------

/// Why the admission's transaction rolled back.
type Unadmitted {
  /// The channel delivered this message before.
  Redelivered
  /// A verb, the store or Grind failed, contention included.
  NotAdmitted(reason: String)
}

/// What `admit` did with a message.
pub type Admission {
  /// The message is new: it is kept, the contact's registrations not yet
  /// released (waiting, held, or still expected) are superseded (their ids
  /// are listed), its own registration is expected, and a registration job
  /// is admitted.
  Admitted(superseded: List(String))
  /// The channel delivered this message before; nothing changed.
  Duplicate
}

/// The trigger. Safe to call again with the same message: the message's id
/// is its key, and the job's id is derived from it.
///
/// One transaction supersedes what the contact's earlier messages started
/// (`happened`), keeps the message, records that a recommendation is
/// expected for it (`expect`, after `happened`, so a message does not
/// supersede its own), and admits the job. A model call for an older
/// message that finishes later is then refused by the record
/// (`SupersededBefore`) and writes nothing. The library serialises
/// admissions about one contact: `happened` takes its lock on the contact
/// first. Keeping the message after that lock makes the message kept
/// second the one admitted second, so its conversation holds the first.
/// A redelivered message rolls the transaction back, supersession
/// included, and admits nothing.
pub fn admit(
  env: Env,
  message: Inbound,
  register: Worker(String, String, String),
) -> Result(Admission, String) {
  let not_admitted = fn(refusal) {
    decisions_postgres.Own(NotAdmitted(decisions.describe(refusal)))
  }
  let ran =
    decisions_postgres.transaction_with(env.pool, fn(tx) {
      use superseded <- result.try(
        decisions.happened(
          env.desk,
          tx,
          domain.newer_message,
          about: domain.subject(message.contact),
        )
        |> result.map_error(not_admitted),
      )
      use new <- result.try(
        store.insert_message(decisions_postgres.connection(tx), message)
        |> result.map_error(fn(error) {
          decisions_postgres.Own(NotAdmitted(store.describe(error)))
        }),
      )
      use Nil <- result.try(case new {
        True -> Ok(Nil)
        False -> Error(decisions_postgres.Own(Redelivered))
      })
      use Nil <- result.try(
        decisions.expect(
          env.desk,
          tx,
          key: domain.key(message.id),
          trigger: domain.trigger(message.id),
          about: domain.subject(message.contact),
        )
        |> result.map_error(not_admitted),
      )
      use _ <- result.try(
        grind.submit_in(
          env.jobs,
          decisions_postgres.connection(tx),
          job.new(register, message.id)
            // Keys built from the channel's id are bounded
            // (`domain.bounded`): the store refuses an occurrence id over
            // 255 bytes.
            |> job.with_id("register:" <> domain.bounded(message.id))
            |> job.with_correlation(
              correlation.from_key(domain.key(message.id)),
            ),
        )
        |> result.map_error(fn(error) {
          decisions_postgres.Own(
            NotAdmitted(grind.describe_submit_error(error)),
          )
        }),
      )
      Ok(
        Admitted(list.append(
          list.map(superseded.expired, fn(known) { known.id }),
          superseded.not_begun,
        )),
      )
    })
  case ran {
    Ok(admission) -> Ok(admission)
    Error(decisions_postgres.OwnFailed(Redelivered)) -> Ok(Duplicate)
    // Nothing was kept: the channel delivers the message again.
    Error(decisions_postgres.OwnFailed(NotAdmitted(reason))) -> Error(reason)
    Error(decisions_postgres.LibraryFailed(failure)) ->
      Error(decisions_postgres.describe(failure))
  }
  |> result.map(fn(admission) {
    telemetry.emit(
      telemetry.admitted(),
      telemetry.Admitted(
        message: message.id,
        contact: message.contact,
        duplicate: admission == Duplicate,
      ),
    )
    admission
  })
}

// -- Registration ----------------------------------------------------------------

fn text_codec() -> worker.Codec(String) {
  worker.codec(worker.infallible(json.string), decode.string)
}

/// The registration worker: input is the message id.
pub fn register_worker(env: Env) -> Worker(String, String, String) {
  worker.responding(
    "clinic.register",
    input: text_codec(),
    output: text_codec(),
    handle: fn(context, message_id) {
      register(env, worker.connection(context), message_id)
    },
  )
  |> worker.with_queue(queue)
  |> worker.with_error_codec(text_codec())
  |> worker.with_max_attempts(env.max_attempts)
  |> worker.with_retry_policy(fn(_, _) { worker.RetryAfter(env.retry_after) })
  // The handler is idempotent by its key: an attempt cut short is run again.
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(5))
}

/// One delivery of the registration job, outside any transaction until the
/// model has answered.
pub fn register(
  env: Env,
  db: pog.Connection,
  message_id: String,
) -> worker.Response(String, String) {
  let key = domain.key(message_id)
  case store.message(db, message_id) {
    Error(error) -> worker.Failed(store.describe(error))
    Ok(None) -> worker.Discarded("no message " <> message_id)
    Ok(Some(message)) ->
      // A delivery after the recommendation, or after the record ended
      // before it began, has nothing to do; the record says which.
      case
        decisions_postgres.refusing(env.pool, decisions.read_record(
          env.desk,
          _,
          key:,
        ))
      {
        Ok(decisions.Begun(_)) ->
          worker.Succeeded("recommended by an earlier delivery")
        Ok(decisions.NotBegun(occurrence.Pending(
          ended: Some(vocabulary.Superseded(_)),
          ..,
        ))) -> worker.Succeeded("a newer message superseded it")
        // No message is expected with a deadline of its own today.
        Ok(decisions.NotBegun(occurrence.Pending(
          ended: Some(vocabulary.DeadlinePassed),
          ..,
        ))) -> worker.Succeeded("its deadline passed before a recommendation")
        Ok(decisions.NotBegun(_)) | Error(decisions.UnknownOccurrence) ->
          attempt(env, db, message, key)
        Error(refusal) -> refused(refusal)
      }
  }
}

/// A verb that failed in a transaction of its own, as the job's answer.
fn store_failed(
  failure: decisions_postgres.Failure,
) -> worker.Response(String, String) {
  case failure {
    decisions_postgres.Refused(refusal:) -> refused(refusal)
    _ -> worker.Failed(decisions_postgres.describe(failure))
  }
}

/// A refusal as the job's answer, as `decisions.handling` classifies it:
/// delivered again when it can help, ended otherwise.
fn refused(refusal: Refusal) -> worker.Response(String, String) {
  case decisions.handling(decisions.DeskRefused(refusal)) {
    decisions.Redeliver | decisions.Backoff ->
      worker.Failed(decisions.describe(refusal))
    decisions.SetAside | decisions.Drop ->
      worker.Discarded(decisions.describe(refusal))
  }
}

/// The heap the model's process may grow to before it is killed and its
/// call is a raise: the provider's answer and the prepared request.
fn model_heap() -> isolated.HeapLimit {
  let assert Ok(heap) = isolated.heap_limit(megabytes: 256)
  heap
}

fn attempt(
  env: Env,
  db: pog.Connection,
  message: Inbound,
  key: String,
) -> worker.Response(String, String) {
  let chosen =
    llm.live(env.configuration, env.provider, env.llm_client, llm.capture(db))
    |> isolated.model(
      within: duration.add(env.provider.deadline, duration.seconds(1)),
      heap: model_heap(),
    )
    |> after_answer(env.after_model, message.id)
  let attempted =
    isolated.recommend(
      env.desk,
      in: decisions_postgres.refusing(env.pool, _),
      request: isolated.Request(
        source: "clinic_registration",
        key:,
        trigger: domain.trigger(message.id),
        about: domain.subject(message.contact),
        context: llm.manifest(message),
        sources: llm.sources(db),
      ),
      model: chosen,
    )
  case attempted {
    Ok(isolated.Recommended(known)) -> {
      telemetry.emit(
        telemetry.recommended(),
        telemetry.Recommended(
          occurrence: known.id,
          status: occurrence.status_name(known.status),
          policy_version: option.unwrap(known.policy_version, 0),
        ),
      )
      worker.Succeeded(occurrence.status_name(known.status))
    }
    // A newer message superseded the key before this answer arrived: the
    // record refused it and nothing was written.
    Ok(isolated.Superseded(event:)) ->
      worker.Succeeded("superseded by " <> event)
    // Only `recommend_when` skips.
    Ok(isolated.Skipped(reason)) -> worker.Succeeded(reason)
    // Only a key expected with `decisions.expect_until` lapses, and no
    // message is. The record refused the failed attempt and wrote nothing.
    Ok(isolated.Lapsed(_)) ->
      worker.Succeeded("its deadline passed before a recommendation")
    Ok(isolated.Failed(failure:, attempts:)) -> {
      let retry =
        model.retryable(failure) && list.length(attempts) < env.max_attempts
      telemetry.emit(
        telemetry.attempt_failed(),
        telemetry.AttemptFailed(
          occurrence: key,
          failure: model.describe(failure),
          attempts: list.length(attempts),
          retry:,
        ),
      )
      case retry {
        True -> worker.Failed(model.describe(failure))
        False -> worker.Discarded(model.describe(failure))
      }
    }
    Error(refusal) -> refused(refusal)
  }
}

/// The model, followed by `hook` once it has answered.
fn after_answer(
  inner: model.Model(Registration),
  hook: fn(String) -> Nil,
  message_id: String,
) -> model.Model(Registration) {
  model.reporting(fn(context, sources) {
    let answered = model.run(inner, context, sources)
    hook(message_id)
    answered
  })
}

// -- The confirmation ------------------------------------------------------------

/// What the confirmation job sends, and under which key.
pub type Confirmation {
  Confirmation(occurrence: String, key: String, phone: String, name: String)
}

fn confirmation_codec() -> worker.Codec(Confirmation) {
  worker.codec(
    worker.infallible(fn(c: Confirmation) {
      json.object([
        #("occurrence", json.string(c.occurrence)),
        #("key", json.string(c.key)),
        #("phone", json.string(c.phone)),
        #("name", json.string(c.name)),
      ])
    }),
    {
      use occurrence <- decode.field("occurrence", decode.string)
      use key <- decode.field("key", decode.string)
      use phone <- decode.field("phone", decode.string)
      use name <- decode.field("name", decode.string)
      decode.success(Confirmation(occurrence:, key:, phone:, name:))
    },
  )
}

/// The confirmation worker.
pub fn confirm_worker(env: Env) -> Worker(Confirmation, String, String) {
  worker.responding(
    "clinic.confirm",
    input: confirmation_codec(),
    output: text_codec(),
    handle: fn(_context, confirmation) { confirm(env, confirmation) },
  )
  |> worker.with_queue(queue)
  |> worker.with_error_codec(text_codec())
  |> worker.with_max_attempts(10)
  |> worker.with_retry_policy(fn(_, _) {
    worker.RetryAfter(env.reconcile_after)
  })
  // A send is idempotent by its key, so an attempt cut short is run again.
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(5))
}

/// The text Ana receives.
pub fn confirmation_text(name: String) -> String {
  "Olá "
  <> first_name(name)
  <> ", your registration at Clínica X is complete. Reply with a day and time to book your appointment."
}

fn first_name(name: String) -> String {
  case string.split(string.trim(name), " ") {
    [first, ..] if first != "" -> first
    _ -> name
  }
}

/// One delivery of the confirmation job: look the message up by its key
/// first, so a send whose answer was lost is never repeated blindly.
pub fn confirm(
  env: Env,
  confirmation: Confirmation,
) -> worker.Response(String, String) {
  let report = fn(effect, done: worker.Response(String, String)) {
    case
      decisions_postgres.transaction(env.pool, decisions.report(
        env.desk,
        _,
        occurrence: confirmation.occurrence,
        effect:,
      ))
    {
      Ok(_) -> {
        telemetry.emit(
          telemetry.effect_reported(),
          telemetry.Reported(
            occurrence: confirmation.occurrence,
            effect: describe_effect(effect),
          ),
        )
        done
      }
      Error(failure) -> store_failed(failure)
    }
  }
  let performed = fn(receipt) {
    Performed(Ref(
      kind: "messaging.message",
      id: confirmation.key,
      revision: receipt,
    ))
  }
  case messaging.lookup(env.messaging, confirmation.key) {
    Error(reason) -> worker.Failed(reason)
    Ok(Some(receipt)) ->
      report(performed(receipt), worker.Succeeded("performed"))
    Ok(None) ->
      case
        messaging.send(
          env.messaging,
          key: confirmation.key,
          to: confirmation.phone,
          text: confirmation_text(confirmation.name),
        )
      {
        messaging.Delivered(receipt) ->
          report(performed(receipt), worker.Succeeded("performed"))
        messaging.Turned(reason) ->
          report(NotPerformed(reason), worker.Discarded(reason))
        messaging.Unreachable(reason) -> worker.Failed(reason)
        messaging.Unknown(reason) ->
          report(
            Uncertain(reason),
            worker.Snoozed(after: env.reconcile_after, reason:),
          )
      }
  }
}

/// An effect as one line.
pub fn describe_effect(effect: vocabulary.Effect) -> String {
  case effect {
    Performed(receipt:) -> "performed (" <> receipt.revision <> ")"
    NotPerformed(reason:) -> "not performed: " <> reason
    Uncertain(reason:) -> "uncertain: " <> reason
  }
}

/// What follows a settled registration: a released one gets a confirmation
/// job, admitted in the transaction that delivers the settlement notice. A
/// rejected, expired, withdrawn or refused one needs nothing here.
pub fn follower(
  env: Env,
  confirm: Worker(Confirmation, String, String),
) -> decisions_postgres.Follower {
  #(domain.point_name, fn(tx, id) {
    // A notice for a record superseded before it began reads as
    // `SupersededBefore`; returned as the desk's refusal, the notice ends
    // delivered.
    use known <- result.try(
      decisions.read(env.desk, tx, occurrence: id)
      |> result.map_error(decisions.DeskRefused),
    )
    case occurrence.account(known) {
      occurrence.Done(final:, key:, ..) ->
        grind.submit_in(
          env.jobs,
          decisions_postgres.connection(tx),
          job.new(
            confirm,
            Confirmation(
              occurrence: id,
              key:,
              phone: known.subject.id,
              name: final.name,
            ),
          )
            |> job.with_id("confirm:" <> key)
            |> job.with_correlation(correlation.from_key(id)),
        )
        |> result.map_error(fn(error) {
          decisions.ApplicationFailed(grind.describe_submit_error(error))
        })
        |> result.replace(Nil)
      _ -> Ok(Nil)
    }
  })
}
