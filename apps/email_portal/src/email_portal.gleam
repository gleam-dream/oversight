//// Application-owned account policy, pending evidence, and sequential session
//// publication. Callers own the Correio service, capture, and runtime lifecycle.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/passwordless
import correio/passwordless/memory
import correio/testing
import correio_mailbox
import gleam/dict.{type Dict}
import gleam/http/request
import gleam/io
import gleam/list
import gleam/result
import gleam/string

pub type AccountId {
  AccountId(Int)
}

pub type Account {
  Account(id: AccountId, email: address.Address, enabled: Bool)
}

pub type Authentication {
  EmailVerification
}

pub type Principal {
  Principal(account: AccountId, authentication: Authentication)
}

pub opaque type Session {
  Session(id: String, principal: Principal)
}

pub opaque type Portal {
  Portal(
    service: passwordless.Service(AccountId),
    from: address.Address,
    sender: delivery.Sender,
    sessions: Dict(String, Session),
  )
}

pub opaque type Pending {
  Pending(id: String, account: AccountId, destination: String, phase: Phase)
}

type Phase {
  AwaitingAnswer
  Recovering(passwordless.VerifyRecovery(AccountId))
  Confirmed(passwordless.Verified(AccountId))
}

pub type RequestError {
  AccountDeniedForRequest
  IssuanceFailed(passwordless.IssueError(AccountId))
  InvalidMail(message.MessageError)
}

pub type ConfirmationError {
  AccountDenied
  VerificationFailed(passwordless.VerifyError(AccountId))
  PublicationFailed
}

pub type Confirmation {
  Retry(pending: Pending, reason: ConfirmationError)
  SignedIn(Session)
}

/// The caller threads this state sequentially. A real application supplies a
/// durable, atomic publisher keyed by session_id; this local recipe is ephemeral.
pub fn new(
  service: passwordless.Service(AccountId),
  from: address.Address,
  sender: delivery.Sender,
) -> Portal {
  Portal(service, from, sender, dict.new())
}

/// Delivery outcomes remain explicit. In particular, OutcomeUnknown is returned
/// unchanged and never retried. Pending metadata itself grants no session.
pub fn request(
  portal: Portal,
  account: Account,
  method: passwordless.Method,
) -> Result(#(Pending, delivery.Outcome), RequestError) {
  use _ <- result.try(case account.enabled {
    True -> Ok(Nil)
    False -> Error(AccountDeniedForRequest)
  })
  let destination = address.email(account.email)
  use challenge <- result.try(
    passwordless.issue(portal.service, account.id, destination, method)
    |> result.map_error(IssuanceFailed),
  )
  let id = passwordless.challenge_id(challenge)
  let answer = passwordless.challenge_answer(challenge)
  let body = case method {
    passwordless.MagicLink ->
      "Confirm sign-in:\nhttps://portal.example/confirm/" <> id <> "/" <> answer
    passwordless.EmailCode(_) -> "Verification code: " <> answer
  }
  use mail <- result.try(
    message.new(
      portal.from,
      account.email,
      "Confirm sign-in",
      message.Text(body),
    )
    |> result.map_error(InvalidMail),
  )
  Ok(#(
    Pending(id, account.id, destination, AwaitingAnswer),
    portal.sender(mail),
  ))
}

/// The account comes from the application's current trusted lookup. The
/// publisher must treat session_id as an idempotency key even when its reply is
/// lost. Keep returned Retry evidence in application custody, never in a cookie.
pub fn confirm(
  portal: Portal,
  pending: Pending,
  answer: String,
  current_account: Account,
  publish: fn(Session) -> Result(Nil, Nil),
) -> #(Portal, Confirmation) {
  case
    current_account.enabled
    && current_account.id == pending.account
    && address.email(current_account.email) == pending.destination
  {
    False -> #(portal, Retry(pending, AccountDenied))
    True -> {
      let evidence = case pending.phase {
        AwaitingAnswer ->
          passwordless.verify(
            portal.service,
            pending.id,
            pending.destination,
            answer,
          )
        Recovering(recovery) -> passwordless.recover_verify(recovery)
        Confirmed(evidence) -> Ok(evidence)
      }
      case evidence {
        Error(passwordless.VerifyUnknown(recovery) as error) -> #(
          portal,
          Retry(
            Pending(..pending, phase: Recovering(recovery)),
            VerificationFailed(error),
          ),
        )
        Error(passwordless.VerifyFailed(_) as error) -> #(
          portal,
          Retry(pending, VerificationFailed(error)),
        )
        Error(passwordless.Refused(_) as error) -> #(
          portal,
          Retry(
            Pending(..pending, phase: AwaitingAnswer),
            VerificationFailed(error),
          ),
        )
        Ok(evidence) ->
          publish_session(
            portal,
            Pending(..pending, phase: Confirmed(evidence)),
            evidence,
            publish,
          )
      }
    }
  }
}

fn publish_session(
  portal: Portal,
  pending: Pending,
  evidence: passwordless.Verified(AccountId),
  publish: fn(Session) -> Result(Nil, Nil),
) -> #(Portal, Confirmation) {
  let id = passwordless.verification_id(evidence)
  // This is a native application principal, not a Hellhound OIDC identity.
  let session =
    Session(id, Principal(passwordless.subject(evidence), EmailVerification))
  case dict.get(portal.sessions, id) {
    Ok(existing) -> #(portal, SignedIn(existing))
    Error(Nil) ->
      case publish(session) {
        Error(Nil) -> #(portal, Retry(pending, PublicationFailed))
        Ok(Nil) -> #(
          Portal(..portal, sessions: dict.insert(portal.sessions, id, session)),
          SignedIn(session),
        )
      }
  }
}

pub fn pending_id(pending: Pending) -> String {
  pending.id
}

/// Public publication identity, not a browser bearer credential.
pub fn session_id(session: Session) -> String {
  session.id
}

pub fn principal(session: Session) -> Principal {
  session.principal
}

pub fn session_count(portal: Portal) -> Int {
  dict.size(portal.sessions)
}

/// Local executable evidence. The fixed key and domain are test fixtures only.
/// No answers, messages, evidence, account data, or session IDs are printed.
pub fn main() {
  let assert Ok(runtime) = memory.start(10)
  let assert Ok(capture) = capture.start(10)
  let assert Ok(service) =
    passwordless.new(memory.store(runtime), "portal", "login", <<0:256>>)
  let assert Ok(from) = address.parse("login@example.com")
  let assert Ok(email) = address.parse("alice@example.com")
  let account = Account(AccountId(42), email, True)
  let portal = new(service, from, capture.sender(capture))
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  let assert Ok(#(pending, delivery.Accepted(_))) =
    request(portal, account, passwordless.MagicLink)
  let assert Ok(mail) = testing.await(checkpoint, testing.to(email), 0)
  let assert Ok(mailbox) = correio_mailbox.new(capture, at: "/dev/mail")
  let assert Ok(inspect) = request.to("http://localhost/dev/mail/1")
  let assert 200 = correio_mailbox.handle(mailbox, inspect).status
  let assert 0 = session_count(portal)
  let assert message.Text(body) = message.view(mail).body
  let assert Ok(answer) = list.last(string.split(body, "/"))
  let #(portal, confirmation) =
    confirm(portal, pending, answer, account, fn(_) { Error(Nil) })
  let assert Retry(confirmed, PublicationFailed) = confirmation
  let #(portal, confirmation) =
    confirm(portal, confirmed, "", account, fn(_) { Ok(Nil) })
  let assert SignedIn(session) = confirmation
  let assert Principal(AccountId(42), EmailVerification) = principal(session)
  let assert 1 = session_count(portal)
  let assert Ok(Nil) = capture.stop(capture)
  let assert Ok(Nil) = memory.stop(runtime)
  io.println(
    "Email portal: delivery, mailbox inspection, intentional verification, and session recovery passed.",
  )
}
