//// The decision point `registration` bound to its gated tool, its stored
//// policy and the PostgreSQL port, and the card a validator is shown.
////
//// The gated tool `register_patient` inserts the patient row in the
//// verdict's transaction (or the recommendation's, when the policy
//// proceeds). Its guard checks again that no patient has the contact's
//// phone; the desk's release check (`release_check`) sees the record and
//// checks that it is complete, consented, and names a phone no patient
//// has. The release records the evidence both relied on.

import clinic_registration/domain.{type Context, type Registration}
import clinic_registration/llm
import clinic_registration/store
import decisions.{type Card, type Desk, type Gated, Gated}
import decisions/model as decisions_model
import decisions/occurrence
import decisions/policy.{type Policy}
import decisions/store as port
import decisions/view.{type View}
import decisions/vocabulary.{type Ref, Ref}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/codec
import pog

/// The name the release records for the tool.
pub const tool_name = "register_patient"

/// The tool. The guard is handed the subject (the contact): it states the
/// fact "no patient has the contact's phone" and returns the evidence it
/// relied on. The executor inserts the row; the unique phone constraint
/// stays as the database's own backstop. A failure that judges the release
/// is `Refuse`; one that could not tell (a query that failed) is `Unsure`,
/// which rolls back, records no refusal and is tried again.
pub fn register_patient() -> Gated(Registration, pog.Connection) {
  Gated(
    name: tool_name,
    guard: fn(tx, subject) { no_patient_with(tx, subject.id) },
    execute: fn(tx, released) {
      let registration: Registration = decisions.output(released)
      case registration.birth_date {
        None -> Error(decisions.Refuse("the record has no birth date"))
        Some(birth_date) ->
          store.insert_patient(
            tx,
            id: decisions.occurrence_of(released),
            registration:,
            birth_date:,
            by: case decisions.decider(released) {
              occurrence.ByValidator(subject:) -> subject
              occurrence.ByPolicy(version:) ->
                "policy v" <> int.to_string(version)
            },
          )
          |> result.map_error(fn(error) {
            case error {
              pog.ConstraintViolated(..) ->
                decisions.Refuse(store.describe(error))
              _ -> decisions.Unsure(store.describe(error))
            }
          })
      }
    },
  )
}

/// The release check, with the output in hand: the record is complete and
/// consented, and no patient has the phone it names, which a validator may
/// have corrected away from the contact's. Its evidence is recorded beside
/// the guard's.
pub fn release_check(
  tx: pog.Connection,
  release: decisions.ToRelease(Registration),
) -> Result(List(Ref), decisions.Stop) {
  let registration = release.output
  case registration.birth_date, registration.consent {
    None, _ -> Error(decisions.Refuse("the record has no birth date"))
    _, False ->
      Error(decisions.Refuse("the patient has not agreed to be registered"))
    Some(_), True ->
      case registration.phone == release.subject.id {
        // The guard checked the contact's phone already.
        True -> Ok([])
        False -> no_patient_with(tx, registration.phone)
      }
  }
}

fn no_patient_with(
  tx: pog.Connection,
  phone: String,
) -> Result(List(Ref), decisions.Stop) {
  case store.patient_by_phone(tx, phone) {
    Ok(None) ->
      Ok([Ref(kind: "patients.by_phone", id: phone, revision: "absent")])
    Ok(Some(existing)) ->
      Error(decisions.Refuse(
        "a patient with phone "
        <> phone
        <> " is already registered ("
        <> existing.id
        <> ")",
      ))
    Error(error) ->
      Error(decisions.Unsure(
        "the patient table could not be read: " <> store.describe(error),
      ))
  }
}

/// The desk over `port`: the point, the tool and its release check, and
/// the newest stored policy version, read in the verb's own transaction.
pub fn new(
  over port: port.Port(pog.Connection),
) -> Desk(Registration, pog.Connection) {
  decisions.desk(
    domain.point(),
    drives: fn(_) { register_patient() },
    under: fn(tx) { store.current_policy(tx, domain.point_name) },
    over: port,
  )
  |> decisions.checking(with: release_check)
}

/// Why a policy version was not published.
pub type PublishError {
  /// The version reads a fact the point does not declare, or reads one as
  /// the wrong type.
  Unpublishable(faults: List(policy.Fault))
  /// The store refused it, for one because the version exists.
  NotStored(reason: String)
}

/// Publish a policy version: check it against the point's declared facts,
/// then store it. The desk reads the newest stored version.
pub fn publish(
  db: pog.Connection,
  version: Policy,
) -> Result(Nil, PublishError) {
  use Nil <- result.try(
    decisions.publishable(domain.point(), version)
    |> result.map_error(Unpublishable),
  )
  store.store_policy(db, domain.point_name, version)
  |> result.map_error(fn(error) { NotStored(store.describe(error)) })
}

// -- The card ----------------------------------------------------------------------

/// The card as Felipe sees it: the card document of `decisions/view` (the
/// ticket fields, the recommendation, the output that stands, who has
/// approved, every input with its content as read and its newer revision
/// when it changed), the context as the model's own reader reads it from
/// the record, the exact prompt and answer, and the failed attempts before
/// the recommendation.
pub type CardDocument {
  CardDocument(
    card: View(Registration),
    /// `None` when the record no longer resolves.
    context: Option(Context),
    exchange: Option(ModelExchange),
    attempts: List(String),
    policy_version: Option(Int),
  )
}

/// The provider call behind the recommendation.
pub type ModelExchange {
  ModelExchange(request: String, answer: String)
}

/// The card, resolved from the record.
pub fn card(db: pog.Connection, card: Card(Registration)) -> CardDocument {
  let shown = decisions.shown(card)
  let resolve = store.resolver(db)
  CardDocument(
    card: view.of(card, content: resolve),
    context: view.context(shown, with: llm.reader(), content: resolve)
      |> option.from_result,
    exchange: llm.exchange(shown.recommendation.explanation, content: resolve)
      |> result.map(fn(exchange) {
        ModelExchange(request: exchange.request, answer: exchange.text)
      })
      |> option.from_result,
    attempts: list.map(shown.attempts, fn(attempt) {
      decisions_model.describe(attempt.failure)
    }),
    policy_version: shown.policy_version,
  )
}

/// The card document's JSON form, with its schema.
pub fn card_codec() -> codec.Codec(CardDocument) {
  let exchange = {
    use request <- codec.field(
      "request",
      codec.string(),
      get: fn(e: ModelExchange) { e.request },
    )
    use answer <- codec.field(
      "answer",
      codec.string(),
      get: fn(e: ModelExchange) { e.answer },
    )
    codec.success(ModelExchange(request:, answer:))
  }
  use card <- codec.field(
    "card",
    view.codec(decisions.codec(domain.point())),
    get: fn(d: CardDocument) { d.card },
  )
  use context <- codec.field(
    "context",
    codec.nullable(domain.context_codec()),
    get: fn(d: CardDocument) { d.context },
  )
  use exchange <- codec.field(
    "model_exchange",
    codec.nullable(exchange),
    get: fn(d: CardDocument) { d.exchange },
  )
  use attempts <- codec.field(
    "attempts",
    codec.list(codec.string()),
    get: fn(d: CardDocument) { d.attempts },
  )
  use policy_version <- codec.field(
    "policy_version",
    codec.nullable(codec.int()),
    get: fn(d: CardDocument) { d.policy_version },
  )
  codec.success(CardDocument(
    card:,
    context:,
    exchange:,
    attempts:,
    policy_version:,
  ))
}

/// The card as JSON text.
pub fn card_json(db: pog.Connection, shown: Card(Registration)) -> String {
  codec.encode_json(card_codec(), card(db, shown))
  |> result.unwrap("null")
}
