import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/passwordless
import correio/passwordless/memory
import correio/passwordless/store
import correio/testing
import correio_mailbox
import email_portal as portal
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn account() {
  let assert Ok(email) = address.parse("alice@example.com")
  portal.Account(portal.AccountId(42), email, True)
}

fn setup(capacity) {
  let assert Ok(runtime) = memory.start(20)
  let assert Ok(capture) = capture.start(capacity)
  let assert Ok(service) =
    passwordless.new(memory.store(runtime), "portal", "login", <<0:256>>)
  let assert Ok(from) = address.parse("login@example.com")
  #(
    runtime,
    capture,
    service,
    portal.new(service, from, capture.sender(capture)),
  )
}

fn finish(runtime, capture) {
  memory.stop(runtime) |> should.equal(Ok(Nil))
  capture.stop(capture) |> should.equal(Ok(Nil))
}

fn delivered(app, capture, method) {
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  let assert Ok(#(pending, delivery.Accepted(_))) =
    portal.request(app, account(), method)
  let assert Ok(mail) =
    testing.await(checkpoint, testing.to(account().email), 0)
  let assert message.Text(body) = message.view(mail).body
  let answer = case method {
    passwordless.MagicLink ->
      body |> string.split("/") |> list.last |> should.be_ok
    passwordless.EmailCode(_) -> string.replace(body, "Verification code: ", "")
  }
  #(pending, answer)
}

pub fn mailbox_inspection_then_intentional_confirmation_test() {
  let #(runtime, capture, _, app) = setup(10)
  let #(pending, answer) = delivered(app, capture, passwordless.MagicLink)
  let assert Ok(mailbox) = correio_mailbox.new(capture, at: "/dev/mail")
  let assert Ok(inbox) = request.to("http://localhost/dev/mail")
  let assert Ok(detail) = request.to("http://localhost/dev/mail/1")
  correio_mailbox.handle(mailbox, inbox).status |> should.equal(200)
  correio_mailbox.handle(mailbox, detail).body
  |> string.contains(answer)
  |> should.be_true
  portal.session_count(app) |> should.equal(0)
  let #(app, outcome) =
    portal.confirm(app, pending, answer, account(), fn(_) { Ok(Nil) })
  let assert portal.SignedIn(session) = outcome
  portal.principal(session)
  |> should.equal(portal.Principal(account().id, portal.EmailVerification))
  portal.session_count(app) |> should.equal(1)
  finish(runtime, capture)
}

pub fn publication_retry_retains_evidence_and_is_idempotent_test() {
  let #(runtime, capture, service, app) = setup(10)
  let #(original, answer) = delivered(app, capture, passwordless.MagicLink)
  let #(app, outcome) =
    portal.confirm(app, original, answer, account(), fn(_) { Error(Nil) })
  let assert portal.Retry(pending, portal.PublicationFailed) = outcome
  portal.session_count(app) |> should.equal(0)
  passwordless.verify(
    service,
    portal.pending_id(original),
    address.email(account().email),
    answer,
  )
  |> should.equal(Error(passwordless.Refused(store.Consumed)))
  let #(app, outcome) =
    portal.confirm(app, pending, "ignored after consumption", account(), fn(_) {
      Ok(Nil)
    })
  let assert portal.SignedIn(session) = outcome
  portal.session_id(session) |> should.equal(portal.pending_id(original))
  let #(app, outcome) =
    portal.confirm(app, pending, "", account(), fn(_) {
      panic as "Publication must not repeat"
    })
  outcome |> should.equal(portal.SignedIn(session))
  portal.session_count(app) |> should.equal(1)
  finish(runtime, capture)
}

pub fn current_account_policy_applies_to_confirmation_and_recovery_test() {
  let #(runtime, capture, _, app) = setup(10)
  let #(pending, answer) = delivered(app, capture, passwordless.MagicLink)
  let disabled = portal.Account(..account(), enabled: False)
  let #(_, refused) =
    portal.confirm(app, pending, answer, disabled, fn(_) { panic })
  refused |> should.equal(portal.Retry(pending, portal.AccountDenied))
  let assert Ok(changed_email) = address.parse("changed@example.com")
  let changed = portal.Account(..account(), email: changed_email)
  let #(_, refused) =
    portal.confirm(app, pending, answer, changed, fn(_) { panic })
  refused |> should.equal(portal.Retry(pending, portal.AccountDenied))
  let #(app, failure) =
    portal.confirm(app, pending, answer, account(), fn(_) { Error(Nil) })
  let assert portal.Retry(confirmed, portal.PublicationFailed) = failure
  let #(_, refused) =
    portal.confirm(app, confirmed, "", disabled, fn(_) { panic })
  refused |> should.equal(portal.Retry(confirmed, portal.AccountDenied))
  let #(_, refused) =
    portal.confirm(app, confirmed, "", changed, fn(_) { panic })
  refused |> should.equal(portal.Retry(confirmed, portal.AccountDenied))
  portal.session_count(app) |> should.equal(0)
  finish(runtime, capture)
}

pub fn email_code_with_advanced_policy_and_custom_mount_test() {
  let #(runtime, capture, service, _) = setup(10)
  let assert Ok(service) = passwordless.with_policy(service, 90_000, 2, 180_000)
  let assert Ok(from) = address.parse("security@example.com")
  let app = portal.new(service, from, capture.sender(capture))
  let #(pending, answer) = delivered(app, capture, passwordless.EmailCode(8))
  string.length(answer) |> should.equal(8)
  let assert Ok(mailbox) =
    correio_mailbox.new(capture, at: "/tools/development-mail")
  let assert Ok(request) = request.to("http://localhost/tools/development-mail")
  correio_mailbox.handle(mailbox, request).status |> should.equal(200)
  let #(app, outcome) =
    portal.confirm(app, pending, "wrong", account(), fn(_) { panic })
  let assert portal.Retry(
    pending,
    portal.VerificationFailed(passwordless.Refused(store.WrongAnswer)),
  ) = outcome
  let #(app, outcome) =
    portal.confirm(app, pending, answer, account(), fn(_) { Ok(Nil) })
  let assert portal.SignedIn(_) = outcome
  let #(_, outcome) =
    portal.confirm(app, pending, answer, account(), fn(_) { panic })
  let assert portal.Retry(
    _,
    portal.VerificationFailed(passwordless.Refused(store.Consumed)),
  ) = outcome
  finish(runtime, capture)
}

pub fn delivery_capacity_and_stopped_runtime_are_typed_test() {
  let #(runtime, capture, _, app) = setup(1)
  let _ = delivered(app, capture, passwordless.MagicLink)
  let assert Ok(#(_, outcome)) =
    portal.request(app, account(), passwordless.MagicLink)
  outcome |> should.equal(delivery.NotSent(delivery.CapacityReached))
  capture.stop(capture) |> should.equal(Ok(Nil))
  let assert Ok(#(_, outcome)) =
    portal.request(app, account(), passwordless.MagicLink)
  outcome |> should.equal(delivery.NotSent(delivery.CaptureUnavailable))
  portal.session_count(app) |> should.equal(0)
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn unknown_delivery_is_not_automatically_resent_test() {
  let #(runtime, capture, service, _) = setup(10)
  let assert Ok(from) = address.parse("login@example.com")
  let sender = fn(mail) {
    let assert delivery.Accepted(_) = capture.send(capture, mail)
    delivery.OutcomeUnknown
  }
  let app = portal.new(service, from, sender)
  let assert Ok(#(_, delivery.OutcomeUnknown)) =
    portal.request(app, account(), passwordless.MagicLink)
  let assert Ok(messages) = capture.messages(capture)
  list.length(messages) |> should.equal(1)
  portal.session_count(app) |> should.equal(0)
  finish(runtime, capture)
}

pub fn uncertain_consumption_survives_unavailable_recovery_test() {
  let #(runtime, capture, _, _) = setup(10)
  let actual = memory.store(runtime)
  let steps = process.new_subject()
  process.send(steps, 1)
  process.send(steps, 2)
  process.send(steps, 3)
  let commands = process.new_subject()
  // Only the public adapter boundary loses replies; actual memory storage owns
  // challenge consumption and command identity throughout the scenario.
  let uncertain =
    store.Store(..actual, verify: fn(command: store.Verify) {
      process.send(commands, command.command)
      let assert Ok(step) = process.receive(steps, 0)
      case step {
        1 -> {
          let assert Ok(Ok(_)) = actual.verify(command)
          Error(store.Unknown)
        }
        2 -> Error(store.Unavailable)
        3 -> actual.verify(command)
        _ -> panic as "Unexpected additional verification"
      }
    })
  let assert Ok(service) =
    passwordless.new(uncertain, "portal", "login", <<0:256>>)
  let assert Ok(from) = address.parse("login@example.com")
  let app = portal.new(service, from, capture.sender(capture))
  let #(pending, answer) = delivered(app, capture, passwordless.MagicLink)
  let #(app, outcome) =
    portal.confirm(app, pending, answer, account(), fn(_) { panic })
  let assert portal.Retry(
    pending,
    portal.VerificationFailed(passwordless.VerifyUnknown(_)),
  ) = outcome
  let #(app, outcome) =
    portal.confirm(app, pending, "ignored", account(), fn(_) { panic })
  let assert portal.Retry(
    pending,
    portal.VerificationFailed(passwordless.VerifyFailed(store.Unavailable)),
  ) = outcome
  let #(app, outcome) =
    portal.confirm(app, pending, "ignored", account(), fn(_) { Ok(Nil) })
  let assert portal.SignedIn(_) = outcome
  portal.session_count(app) |> should.equal(1)
  let assert Ok(first) = process.receive(commands, 0)
  process.receive(commands, 0) |> should.equal(Ok(first))
  process.receive(commands, 0) |> should.equal(Ok(first))
  process.receive(commands, 0) |> should.equal(Error(Nil))
  finish(runtime, capture)
}

pub fn committed_publication_with_lost_reply_recovers_same_session_test() {
  let #(runtime, capture, _, app) = setup(10)
  let #(pending, answer) = delivered(app, capture, passwordless.MagicLink)
  let published = process.new_subject()
  let committed = process.new_subject()
  let publisher = fn(session) {
    case process.receive(published, 0) {
      Error(Nil) -> {
        // Commit first, then lose its reply. The external store holds the ID.
        process.send(published, session)
        process.send(committed, portal.session_id(session))
        Error(Nil)
      }
      Ok(existing) -> {
        existing |> should.equal(session)
        process.send(published, existing)
        Ok(Nil)
      }
    }
  }
  let #(app, outcome) =
    portal.confirm(app, pending, answer, account(), publisher)
  let assert portal.Retry(confirmed, portal.PublicationFailed) = outcome
  portal.session_count(app) |> should.equal(0)
  let #(app, outcome) = portal.confirm(app, confirmed, "", account(), publisher)
  let assert portal.SignedIn(session) = outcome
  process.receive(committed, 0) |> should.equal(Ok(portal.session_id(session)))
  process.receive(committed, 0) |> should.equal(Error(Nil))
  portal.session_count(app) |> should.equal(1)
  finish(runtime, capture)
}
