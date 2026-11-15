//// The clinic's own types and pure decisions: an inbound message, the
//// patient record a registration produces, what the model is asked for,
//// what it had to read, and the decision point `registration` with its
//// declared facts and its policy versions.
////
//// Nothing here performs I/O. The boundaries (store, llm, desk, jobs,
//// web) build on these values.

import decisions
import decisions/fact
import decisions/policy.{
  type Policy, AnyoneHolding, Ask, Either, PerCent, Policy, Proceed, When,
}
import decisions/vocabulary.{
  type Facts, type Subject, type Trigger, type Validator, ApproveRejectOrCorrect,
  Subject, Trigger, Validator,
}
import decisions/wire
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import json/blueprint/codec.{type Codec}

// -- The channel ---------------------------------------------------------------

/// A message as the messaging channel delivers it, at least once. `id` is
/// the channel's own message id; `contact` is the sender's phone number and
/// `profile_name` the name the sender's profile shows.
pub type Inbound {
  Inbound(id: String, contact: String, profile_name: String, text: String)
}

/// One message of a conversation, as the model reads it.
pub type Line {
  Line(id: String, text: String)
}

/// Everything a contact has written so far, up to one message.
pub type Conversation {
  Conversation(contact: String, profile_name: String, lines: List(Line))
}

// -- The patient record --------------------------------------------------------

/// A health insurer and the plan the patient holds with it.
pub type Coverage {
  Coverage(insurer: String, plan: String)
}

/// The point's output: the patient record that registration releases to
/// the patient table. `coverage` is `None` for a patient who pays
/// privately; `birth_date` is `None` while nobody has found it.
pub type Registration {
  Registration(
    name: String,
    birth_date: Option(String),
    phone: String,
    coverage: Option(Coverage),
    consent: Bool,
  )
}

/// An existing patient a lookup found with the same phone or name.
pub type Patient {
  Patient(id: String, name: String, phone: String, birth_date: String)
}

/// What the model had to work from: the conversation, the patients with a
/// similar name or phone, and the insurers the clinic accepts. The model
/// and the card both get this value from one reader
/// (`clinic_registration/llm.reader`).
pub type Context {
  Context(
    conversation: Conversation,
    similar: List(Patient),
    insurers: List(String),
  )
}

/// What the model is asked to answer: the record's fields as it found them,
/// how sure it is, and the fields it could not find.
pub type Extraction {
  Extraction(
    name: String,
    birth_date: Option(String),
    phone: Option(String),
    insurer: Option(String),
    plan: Option(String),
    consent: Bool,
    confidence: Float,
    missing: List(String),
  )
}

/// The clinic this application registers for.
pub const clinic = "clinica-x"

/// Who an occurrence is about: the contact who wrote.
pub fn subject(contact: String) -> Subject {
  Subject(kind: "contact", id: contact)
}

/// What asked for the decision: one inbound message.
pub fn trigger(message_id: String) -> Trigger {
  Trigger(kind: "message", id: message_id)
}

/// The occurrence key of a message. One message admits at most one
/// occurrence; the prefix keeps the key inside this point's namespace. The
/// store refuses an occurrence id over 255 bytes, and the channel's ids
/// are its own: an id longer than 200 bytes is replaced by its SHA-256, so
/// every key fits and stays one per message.
pub fn key(message_id: String) -> String {
  "registration:" <> bounded(message_id)
}

/// A message id short enough to build keys from: itself up to 200 bytes,
/// otherwise `sha256:` and its digest.
pub fn bounded(message_id: String) -> String {
  case string.byte_size(message_id) > 200 {
    False -> message_id
    True ->
      "sha256:"
      <> {
        crypto.hash(crypto.Sha256, bit_array.from_string(message_id))
        |> bit_array.base16_encode
        |> string.lowercase
      }
  }
}

/// The record the model's answer proposes, with the contact's phone when
/// the conversation names none.
pub fn registration_of(
  extraction: Extraction,
  contact: String,
) -> Registration {
  Registration(
    name: string.trim(extraction.name),
    birth_date: extraction.birth_date,
    phone: option.unwrap(extraction.phone, contact),
    coverage: case extraction.insurer {
      Some(insurer) ->
        Some(Coverage(insurer:, plan: option.unwrap(extraction.plan, "")))
      None -> None
    },
    consent: extraction.consent,
  )
}

/// The facts the model reports beside its output, for the policy: its
/// confidence, how many fields it could not find, whether the insurer is
/// one the clinic accepts, and whether a similar patient exists.
pub fn signals(context: Context, extraction: Extraction) -> Facts {
  let accepted = case extraction.insurer {
    Some(insurer) ->
      list.any(context.insurers, fn(known) {
        string.lowercase(known) == string.lowercase(string.trim(insurer))
      })
    None -> False
  }
  [
    fact.set(confidence(), extraction.confidence),
    fact.set(missing_fields(), int.to_float(list.length(extraction.missing))),
    fact.set(insurer_accepted(), accepted),
    fact.set(similar_patient(), context.similar != []),
  ]
}

// -- The decision point --------------------------------------------------------

/// The decision point's name, kept on every occurrence.
pub const point_name = "registration"

/// The world event that supersedes a waiting recommendation: the same
/// contact wrote again.
pub const newer_message = "newer_message"

/// The decision set reception holds.
pub const reception = "reception"

/// The decision set the manager holds.
pub const manager = "manager"

/// The model's confidence, from 0 to 1.
pub fn confidence() -> fact.Key(Float) {
  fact.number("confidence")
}

/// How many fields the model could not find.
pub fn missing_fields() -> fact.Key(Float) {
  fact.number("missing_fields")
}

/// The insurer named is on the clinic's list.
pub fn insurer_accepted() -> fact.Key(Bool) {
  fact.flag("insurer_accepted")
}

/// A patient with a similar name or the same phone exists: a possible
/// duplicate.
pub fn similar_patient() -> fact.Key(Bool) {
  fact.flag("similar_patient")
}

/// The patient agreed to be registered. A fact of the output: the policy
/// reads it from the recommended record.
pub fn consent() -> fact.Key(Bool) {
  fact.flag("consent")
}

/// The decision point: a registration may be approved, rejected or
/// corrected; a recommendation is valid for 24 hours; a newer message from
/// the same contact supersedes a waiting one; the manager reviews the
/// sampled registrations the policy let proceed.
pub fn point() -> decisions.Point(Registration) {
  decisions.point(point_name, wire.codec(registration_codec()))
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.valid_for(duration.hours(24))
  |> decisions.superseded_by(newer_message)
  |> decisions.reviewed_by(manager)
  |> decisions.fact(consent(), fn(registration: Registration) {
    registration.consent
  })
  |> decisions.signal(confidence())
  |> decisions.signal(missing_fields())
  |> decisions.signal(insurer_accepted())
  |> decisions.signal(similar_patient())
}

/// After 30 minutes without a verdict, anyone at reception or the manager
/// may decide.
fn escalation() -> policy.Rule {
  When(
    policy.waited(30),
    Ask(Either([AnyoneHolding(reception), AnyoneHolding(manager)])),
  )
}

/// Version 1: reception decides every registration.
pub fn always_ask() -> Policy {
  Policy(
    version: 1,
    rules: [escalation()],
    otherwise: Ask(AnyoneHolding(reception)),
  )
}

/// Version 2: a confident, complete, consented registration with an
/// accepted insurer and no similar patient proceeds, and one in five of
/// those is sampled for a review after the fact. A possible duplicate asks
/// the manager. Anything else asks reception.
pub fn proceed_when_sure() -> Policy {
  Policy(
    version: 2,
    rules: [
      When(
        policy.All([
          policy.at_least(confidence(), 0.9),
          policy.below(missing_fields(), 1.0),
          policy.is(insurer_accepted(), True),
          policy.is(similar_patient(), False),
          policy.is(consent(), True),
        ]),
        Proceed(PerCent(20)),
      ),
      escalation(),
      When(policy.is(similar_patient(), True), Ask(AnyoneHolding(manager))),
    ],
    otherwise: Ask(AnyoneHolding(reception)),
  )
}

/// A validator as the desk sees them: a name and the sets they hold.
pub fn validator(name: String, holds: List(String)) -> Validator {
  Validator(subject: name, holds:)
}

// -- Codecs --------------------------------------------------------------------

fn date() -> Codec(String) {
  codec.try_map(
    codec.string(),
    decode: check_date,
    encode: Ok,
    placeholder: "1970-01-01",
  )
  |> codec.describe("A date as YYYY-MM-DD")
}

/// `YYYY-MM-DD` with a plausible month and day.
pub fn check_date(text: String) -> Result(String, String) {
  let parts = string.split(text, "-") |> list.map(int.parse)
  case string.length(text), parts {
    10, [Ok(year), Ok(month), Ok(day)]
      if year >= 1900 && month >= 1 && month <= 12 && day >= 1 && day <= 31
    -> Ok(text)
    _, _ -> Error("not a date: " <> text)
  }
}

fn coverage_codec() -> Codec(Coverage) {
  use insurer <- codec.field("insurer", codec.string(), get: fn(c: Coverage) {
    c.insurer
  })
  use plan <- codec.field("plan", codec.string(), get: fn(c: Coverage) {
    c.plan
  })
  codec.success(Coverage(insurer:, plan:))
}

/// The record's JSON form: what the store keeps, what a card shows with
/// its schema, and what a correction sends back.
pub fn registration_codec() -> Codec(Registration) {
  use name <- codec.field("name", codec.string(), get: fn(r: Registration) {
    r.name
  })
  use birth_date <- codec.field(
    "birth_date",
    codec.nullable(date()),
    get: fn(r: Registration) { r.birth_date },
  )
  use phone <- codec.field("phone", codec.string(), get: fn(r: Registration) {
    r.phone
  })
  use coverage <- codec.field(
    "coverage",
    codec.nullable(coverage_codec()),
    get: fn(r: Registration) { r.coverage },
  )
  use consent <- codec.field("consent", codec.bool(), get: fn(r: Registration) {
    r.consent
  })
  codec.success(Registration(name:, birth_date:, phone:, coverage:, consent:))
}

/// The structured output the model is asked for. Every field is present;
/// an unknown one is `null`, so the schema stays within what providers
/// accept for strict structured output.
pub fn extraction_codec() -> Codec(Extraction) {
  let text = codec.nullable(codec.string())
  use name <- codec.field("name", codec.string(), get: fn(e: Extraction) {
    e.name
  })
  use birth_date <- codec.field(
    "birth_date",
    codec.nullable(date()),
    get: fn(e: Extraction) { e.birth_date },
  )
  use phone <- codec.field("phone", text, get: fn(e: Extraction) { e.phone })
  use insurer <- codec.field("insurer", text, get: fn(e: Extraction) {
    e.insurer
  })
  use plan <- codec.field("plan", text, get: fn(e: Extraction) { e.plan })
  use consent <- codec.field("consent", codec.bool(), get: fn(e: Extraction) {
    e.consent
  })
  use confidence <- codec.field(
    "confidence",
    codec.float(),
    get: fn(e: Extraction) { e.confidence },
  )
  use missing <- codec.field(
    "missing",
    codec.list(codec.string()),
    get: fn(e: Extraction) { e.missing },
  )
  codec.success(Extraction(
    name:,
    birth_date:,
    phone:,
    insurer:,
    plan:,
    consent:,
    confidence:,
    missing:,
  ))
}

fn line_codec() -> Codec(Line) {
  use id <- codec.field("id", codec.string(), get: fn(l: Line) { l.id })
  use text <- codec.field("text", codec.string(), get: fn(l: Line) { l.text })
  codec.success(Line(id:, text:))
}

/// The conversation document the store resolves a conversation reference
/// to.
pub fn conversation_codec() -> Codec(Conversation) {
  use contact <- codec.field(
    "contact",
    codec.string(),
    get: fn(c: Conversation) { c.contact },
  )
  use profile_name <- codec.field(
    "profile_name",
    codec.string(),
    get: fn(c: Conversation) { c.profile_name },
  )
  use lines <- codec.field(
    "lines",
    codec.list(line_codec()),
    get: fn(c: Conversation) { c.lines },
  )
  codec.success(Conversation(contact:, profile_name:, lines:))
}

/// A patient as a lookup returns it.
pub fn patient_codec() -> Codec(Patient) {
  use id <- codec.field("id", codec.string(), get: fn(p: Patient) { p.id })
  use name <- codec.field("name", codec.string(), get: fn(p: Patient) { p.name })
  use phone <- codec.field("phone", codec.string(), get: fn(p: Patient) {
    p.phone
  })
  use birth_date <- codec.field(
    "birth_date",
    codec.string(),
    get: fn(p: Patient) { p.birth_date },
  )
  codec.success(Patient(id:, name:, phone:, birth_date:))
}

/// The typed context as JSON, for the card.
pub fn context_codec() -> Codec(Context) {
  use conversation <- codec.field(
    "conversation",
    conversation_codec(),
    get: fn(c: Context) { c.conversation },
  )
  use similar <- codec.field(
    "similar_patients",
    codec.list(patient_codec()),
    get: fn(c: Context) { c.similar },
  )
  use insurers <- codec.field(
    "accepted_insurers",
    codec.list(codec.string()),
    get: fn(c: Context) { c.insurers },
  )
  codec.success(Context(conversation:, similar:, insurers:))
}

/// Encode a value with a codec this module defines. Its encoders cannot
/// fail for values built by this application.
pub fn to_text(codec: Codec(a), value: a) -> String {
  codec.encode_json(codec, value) |> result.unwrap("null")
}
