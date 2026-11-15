//// The clinic's own tables: inbound messages, patients, accepted insurers,
//// published policy versions and captured evidence. The decision record
//// itself lives in the tables of `decisions_postgres`; nothing here reads
//// them.
////
//// Every function takes the connection it runs on: the pool, where each
//// call commits by itself, or an open transaction.

import clinic_registration/domain.{
  type Conversation, type Inbound, type Patient, type Registration, Conversation,
  Line, Patient,
}
import decisions/model
import decisions/policy.{type Policy}
import decisions/vocabulary.{type Ref}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import pog

const schema = [
  "CREATE TABLE IF NOT EXISTS clinic_messages (
     id text PRIMARY KEY,
     contact text NOT NULL,
     profile_name text NOT NULL,
     body text NOT NULL,
     position bigserial NOT NULL UNIQUE,
     received_at timestamptz NOT NULL DEFAULT clock_timestamp())",
  "CREATE INDEX IF NOT EXISTS clinic_messages_contact
     ON clinic_messages (contact, position)",
  "CREATE TABLE IF NOT EXISTS clinic_patients (
     id text PRIMARY KEY,
     name text NOT NULL,
     birth_date text NOT NULL,
     phone text NOT NULL,
     insurer text,
     plan text,
     registered_by text NOT NULL,
     registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
     CONSTRAINT clinic_patients_one_per_phone UNIQUE (phone))",
  "CREATE TABLE IF NOT EXISTS clinic_insurers (
     name text PRIMARY KEY)",
  "CREATE TABLE IF NOT EXISTS clinic_policies (
     point text NOT NULL,
     version integer NOT NULL,
     body text NOT NULL,
     published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
     PRIMARY KEY (point, version))",
  "CREATE TABLE IF NOT EXISTS clinic_evidence (
     kind text NOT NULL,
     id text NOT NULL,
     revision text NOT NULL,
     body text NOT NULL,
     PRIMARY KEY (kind, id, revision))",
]

/// Create the clinic's tables when they do not exist yet.
pub fn migrate(db: pog.Connection) -> Result(Nil, String) {
  list.try_each(schema, fn(statement) {
    pog.query(statement) |> pog.execute(db) |> result.replace(Nil)
  })
  |> result.map_error(describe)
}

/// A query failure as one line, for a log.
pub fn describe(error: pog.QueryError) -> String {
  case error {
    pog.ConstraintViolated(constraint:, ..) ->
      "constraint " <> constraint <> " refused the write"
    pog.PostgresqlError(code:, message:, ..) -> code <> ": " <> message
    pog.QueryTimeout -> "the query timed out"
    pog.ConnectionUnavailable -> "no database connection is available"
    other -> string.inspect(other)
  }
}

// -- Messages -------------------------------------------------------------------

/// Serialise the transactions that change one contact's conversation or
/// recommend for it, until the transaction ends.
pub fn lock_contact(
  tx: pog.Connection,
  contact: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "SELECT 1 FROM (SELECT pg_advisory_xact_lock(hashtextextended($1, 41))) AS held",
  )
  |> pog.parameter(pog.text("clinic-contact:" <> contact))
  |> pog.execute(tx)
  |> result.replace(Nil)
}

/// Keep an inbound message. `True` when it is new, `False` when the
/// channel delivered it before.
pub fn insert_message(
  tx: pog.Connection,
  message: Inbound,
) -> Result(Bool, pog.QueryError) {
  pog.query(
    "INSERT INTO clinic_messages (id, contact, profile_name, body)
     VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(message.id))
  |> pog.parameter(pog.text(message.contact))
  |> pog.parameter(pog.text(message.profile_name))
  |> pog.parameter(pog.text(message.text))
  |> pog.execute(tx)
  |> result.map(fn(returned) { returned.count == 1 })
}

/// A kept message, by id.
pub fn message(
  db: pog.Connection,
  id: String,
) -> Result(Option(Inbound), pog.QueryError) {
  pog.query(
    "SELECT id, contact, profile_name, body FROM clinic_messages WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> pog.returning({
    use id <- decode.field(0, decode.string)
    use contact <- decode.field(1, decode.string)
    use profile_name <- decode.field(2, decode.string)
    use text <- decode.field(3, decode.string)
    decode.success(domain.Inbound(id:, contact:, profile_name:, text:))
  })
  |> pog.execute(db)
  |> result.map(fn(returned) { list.first(returned.rows) |> option.from_result })
}

/// Whether no later message from the same contact has arrived.
pub fn is_latest(
  db: pog.Connection,
  message_id: String,
) -> Result(Bool, pog.QueryError) {
  pog.query(
    "SELECT NOT EXISTS (
       SELECT 1 FROM clinic_messages later, clinic_messages this
       WHERE this.id = $1 AND later.contact = this.contact
         AND later.position > this.position)",
  )
  |> pog.parameter(pog.text(message_id))
  |> pog.returning(decode.at([0], decode.bool))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows == [True] })
}

/// The conversation of `contact` up to and including the message `upto`.
/// Messages are only ever added, so this value never changes for a given
/// `upto`: it is the content behind the reference
/// `Ref("conversation", contact, upto)`.
pub fn conversation(
  db: pog.Connection,
  contact: String,
  upto: String,
) -> Result(Conversation, String) {
  use returned <- result.try(
    pog.query(
      "SELECT m.id, m.body, m.profile_name FROM clinic_messages m
       WHERE m.contact = $1
         AND m.position <= (SELECT position FROM clinic_messages
                            WHERE id = $2 AND contact = $1)
       ORDER BY m.position",
    )
    |> pog.parameter(pog.text(contact))
    |> pog.parameter(pog.text(upto))
    |> pog.returning({
      use id <- decode.field(0, decode.string)
      use text <- decode.field(1, decode.string)
      use profile <- decode.field(2, decode.string)
      decode.success(#(Line(id:, text:), profile))
    })
    |> pog.execute(db)
    |> result.map_error(describe),
  )
  case list.last(returned.rows) {
    Error(Nil) -> Error("no message " <> upto <> " from " <> contact)
    Ok(#(_, profile_name)) ->
      Ok(Conversation(
        contact:,
        profile_name:,
        lines: list.map(returned.rows, fn(row) { row.0 }),
      ))
  }
}

// -- Patients ---------------------------------------------------------------------

fn patient_row() -> decode.Decoder(Patient) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use phone <- decode.field(2, decode.string)
  use birth_date <- decode.field(3, decode.string)
  decode.success(Patient(id:, name:, phone:, birth_date:))
}

/// Patients with the same phone, or whose name equals `name` ignoring case
/// and surrounding spaces. Ordered by id, so the same table gives the same
/// answer.
pub fn similar(
  db: pog.Connection,
  phone phone: String,
  name name: String,
) -> Result(List(Patient), pog.QueryError) {
  pog.query(
    "SELECT id, name, phone, birth_date FROM clinic_patients
     WHERE phone = $1 OR lower(btrim(name)) = lower(btrim($2))
     ORDER BY id",
  )
  |> pog.parameter(pog.text(phone))
  |> pog.parameter(pog.text(name))
  |> pog.returning(patient_row())
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// The patient registered under this phone, if any.
pub fn patient_by_phone(
  db: pog.Connection,
  phone: String,
) -> Result(Option(Patient), pog.QueryError) {
  pog.query(
    "SELECT id, name, phone, birth_date FROM clinic_patients WHERE phone = $1",
  )
  |> pog.parameter(pog.text(phone))
  |> pog.returning(patient_row())
  |> pog.execute(db)
  |> result.map(fn(returned) { list.first(returned.rows) |> option.from_result })
}

/// Insert the patient row of a released registration. The unique phone
/// constraint refuses a second patient with the same phone.
pub fn insert_patient(
  tx: pog.Connection,
  id id: String,
  registration registration: Registration,
  birth_date birth_date: String,
  by registered_by: String,
) -> Result(Nil, pog.QueryError) {
  let #(insurer, plan) = case registration.coverage {
    Some(coverage) -> #(Some(coverage.insurer), Some(coverage.plan))
    None -> #(None, None)
  }
  pog.query(
    "INSERT INTO clinic_patients
       (id, name, birth_date, phone, insurer, plan, registered_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7)",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(registration.name))
  |> pog.parameter(pog.text(birth_date))
  |> pog.parameter(pog.text(registration.phone))
  |> pog.parameter(pog.nullable(pog.text, insurer))
  |> pog.parameter(pog.nullable(pog.text, plan))
  |> pog.parameter(pog.text(registered_by))
  |> pog.execute(tx)
  |> result.replace(Nil)
}

/// A patient as the clinic keeps it, for a reply or a test.
pub type Row {
  Row(
    id: String,
    name: String,
    birth_date: String,
    phone: String,
    insurer: Option(String),
    registered_by: String,
  )
}

/// Every patient with this phone; at most one.
pub fn patients_with_phone(
  db: pog.Connection,
  phone: String,
) -> Result(List(Row), pog.QueryError) {
  pog.query(
    "SELECT id, name, birth_date, phone, insurer, registered_by
     FROM clinic_patients WHERE phone = $1",
  )
  |> pog.parameter(pog.text(phone))
  |> pog.returning({
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use birth_date <- decode.field(2, decode.string)
    use phone <- decode.field(3, decode.string)
    use insurer <- decode.field(4, decode.optional(decode.string))
    use registered_by <- decode.field(5, decode.string)
    decode.success(Row(
      id:,
      name:,
      birth_date:,
      phone:,
      insurer:,
      registered_by:,
    ))
  })
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

// -- Insurers ---------------------------------------------------------------------

/// The insurers the clinic accepts, by name.
pub fn insurers(db: pog.Connection) -> Result(List(String), pog.QueryError) {
  pog.query("SELECT name FROM clinic_insurers ORDER BY name")
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// Accept another insurer.
pub fn accept_insurer(
  db: pog.Connection,
  name: String,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO clinic_insurers (name) VALUES ($1) ON CONFLICT DO NOTHING",
  )
  |> pog.parameter(pog.text(name))
  |> pog.execute(db)
  |> result.replace(Nil)
}

/// Stop accepting an insurer.
pub fn drop_insurer(
  db: pog.Connection,
  name: String,
) -> Result(Nil, pog.QueryError) {
  pog.query("DELETE FROM clinic_insurers WHERE name = $1")
  |> pog.parameter(pog.text(name))
  |> pog.execute(db)
  |> result.replace(Nil)
}

// -- Evidence ---------------------------------------------------------------------

/// Where captured reads and provider exchanges are kept. A reference names
/// one content, so a second put of the same reference changes nothing.
pub fn evidence() -> model.Evidence(pog.Connection) {
  model.Evidence(
    put: fn(db, ref: Ref, body) {
      pog.query(
        "INSERT INTO clinic_evidence (kind, id, revision, body)
         VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
      )
      |> pog.parameter(pog.text(ref.kind))
      |> pog.parameter(pog.text(ref.id))
      |> pog.parameter(pog.text(ref.revision))
      |> pog.parameter(pog.text(body))
      |> pog.execute(db)
      |> result.replace(Nil)
      |> result.map_error(describe)
    },
    get: fn(db, ref: Ref) {
      pog.query(
        "SELECT body FROM clinic_evidence
         WHERE kind = $1 AND id = $2 AND revision = $3",
      )
      |> pog.parameter(pog.text(ref.kind))
      |> pog.parameter(pog.text(ref.id))
      |> pog.parameter(pog.text(ref.revision))
      |> pog.returning(decode.at([0], decode.string))
      |> pog.execute(db)
      |> result.map_error(describe)
      |> result.try(fn(returned) {
        list.first(returned.rows)
        |> result.replace_error(
          "no evidence " <> ref.kind <> "(" <> ref.id <> ")@" <> ref.revision,
        )
      })
    },
  )
}

/// What a reference names, as the model, the card and an export all
/// resolve it: a conversation is read from the messages, everything else
/// from the evidence.
pub fn resolver(db: pog.Connection) -> model.Resolver {
  fn(ref: Ref) {
    case ref.kind {
      "conversation" ->
        conversation(db, ref.id, ref.revision)
        |> result.map(domain.to_text(domain.conversation_codec(), _))
      _ -> evidence().get(db, ref)
    }
    |> result.map_error(model.ReadFailed(
      read: ref.kind,
      argument: ref.id,
      reason: _,
    ))
  }
}

// -- Policies ---------------------------------------------------------------------

/// Store a policy version for `point`. Refused by the primary key when the
/// version exists. The caller checks it with `decisions.publishable` first.
pub fn store_policy(
  db: pog.Connection,
  point: String,
  version: Policy,
) -> Result(Nil, pog.QueryError) {
  pog.query(
    "INSERT INTO clinic_policies (point, version, body) VALUES ($1, $2, $3)",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.int(version.version))
  |> pog.parameter(pog.text(json.to_string(policy.to_json(version))))
  |> pog.execute(db)
  |> result.replace(Nil)
}

/// The highest stored version of `point`'s policy, read in `tx`.
pub fn current_policy(
  tx: pog.Connection,
  point: String,
) -> Result(Policy, String) {
  use returned <- result.try(
    pog.query(
      "SELECT body FROM clinic_policies WHERE point = $1
       ORDER BY version DESC LIMIT 1",
    )
    |> pog.parameter(pog.text(point))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(tx)
    |> result.map_error(describe),
  )
  case returned.rows {
    [] -> Error("no policy is published for " <> point)
    [body, ..] ->
      json.parse(body, policy.decoder())
      |> result.replace_error("the stored policy does not decode")
  }
}

/// The version numbers stored for `point`, ascending.
pub fn policy_versions(
  db: pog.Connection,
  point: String,
) -> Result(List(Int), pog.QueryError) {
  pog.query(
    "SELECT version FROM clinic_policies WHERE point = $1 ORDER BY version",
  )
  |> pog.parameter(pog.text(point))
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// A count from one query with text parameters, for reports and tests.
pub fn count(
  db: pog.Connection,
  sql: String,
  parameters: List(String),
) -> Result(Int, pog.QueryError) {
  list.fold(parameters, pog.query(sql), fn(query, value) {
    pog.parameter(query, pog.text(value))
  })
  |> pog.returning(decode.at([0], decode.int))
  |> pog.execute(db)
  |> result.map(fn(returned) { list.first(returned.rows) |> result.unwrap(0) })
}

/// The JSON a read returns, as text.
pub fn patients_json(patients: List(Patient)) -> String {
  domain.to_text(codec.list(domain.patient_codec()), patients)
}

/// The insurer list as a read returns it.
pub fn insurers_json(insurers: List(String)) -> String {
  domain.to_text(codec.list(codec.string()), insurers)
}
