//// The application's own tables, on the pool it shares with Grind, Fabric,
//// Saga and the decision record. The pool puts the application's schema
//// first on its `search_path`, so these unqualified tables live beside
//// theirs.
////
//// | Table | Holds |
//// | --- | --- |
//// | `sellers` | Balance and what is reserved for payouts in flight |
//// | `orders`, `disputes`, `paid_out`, `chargebacks` | What the agent's read tools answer |
//// | `requests` | A seller's request as support recorded it, and who asked |
//// | `evidence` | What each read returned, captured before the model saw it |
//// | `policies` | Each published policy version of a point, as JSON |
//// | `staff` | Which decision sets each person holds |
//// | `instructions` | One payout instruction per release, written by the gated tool |
//// | `reservations`, `postings` | The workflow's reservation and its posting |
//// | `replies` | What the seller was told, once per payout |

import decisions
import decisions/model
import decisions/policy.{type Policy}
import decisions/vocabulary.{type Ref, type Validator, Ref, Validator}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import payout_desk/domain.{
  type Dispute, type History, type Order, type Request, Dispute, History, Order,
}
import pog

pub type DbError {
  Query(detail: String)
  NotFound(what: String)
  /// The seller's available balance does not cover the payout.
  Insufficient(available_cents: Int, asked_cents: Int)
}

pub fn describe(error: DbError) -> String {
  case error {
    Query(detail) -> "database: " <> detail
    NotFound(what) -> "not found: " <> what
    Insufficient(available_cents:, asked_cents:) ->
      "the balance has "
      <> domain.money(available_cents)
      <> " available, the payout asks "
      <> domain.money(asked_cents)
  }
}

const tables = [
  "CREATE TABLE IF NOT EXISTS sellers (
     id text PRIMARY KEY, balance_cents bigint NOT NULL,
     reserved_cents bigint NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'active')",
  "CREATE TABLE IF NOT EXISTS orders (
     id text PRIMARY KEY, seller text NOT NULL, total_cents bigint NOT NULL, status text NOT NULL)",
  "CREATE TABLE IF NOT EXISTS disputes (
     order_id text PRIMARY KEY, status text NOT NULL, seller_owed_cents bigint NOT NULL,
     fee_cents bigint NOT NULL, note text NOT NULL)",
  "CREATE TABLE IF NOT EXISTS paid_out (seller text NOT NULL, amount_cents bigint NOT NULL)",
  "CREATE TABLE IF NOT EXISTS chargebacks (seller text NOT NULL, days_ago int NOT NULL)",
  "CREATE TABLE IF NOT EXISTS requests (
     id text PRIMARY KEY, seller text NOT NULL, order_id text NOT NULL, text text NOT NULL,
     requested_by text NOT NULL, occurrence text)",
  "CREATE TABLE IF NOT EXISTS evidence (
     kind text NOT NULL, id text NOT NULL, revision text NOT NULL, body text NOT NULL,
     PRIMARY KEY (kind, id, revision))",
  "CREATE TABLE IF NOT EXISTS policies (
     point text NOT NULL, version int NOT NULL, body text NOT NULL, PRIMARY KEY (point, version))",
  "CREATE TABLE IF NOT EXISTS staff (subject text PRIMARY KEY, sets text[] NOT NULL)",
  "CREATE TABLE IF NOT EXISTS instructions (
     release_key text PRIMARY KEY, occurrence text NOT NULL, seller text NOT NULL,
     order_id text NOT NULL, amount_cents bigint NOT NULL,
     written_at timestamptz NOT NULL DEFAULT clock_timestamp())",
  "CREATE TABLE IF NOT EXISTS reservations (
     release_key text PRIMARY KEY, seller text NOT NULL, amount_cents bigint NOT NULL,
     state text NOT NULL CHECK (state IN ('held', 'released', 'posted')))",
  "CREATE TABLE IF NOT EXISTS postings (
     release_key text PRIMARY KEY, seller text NOT NULL, amount_cents bigint NOT NULL,
     receipt text NOT NULL)",
  "CREATE TABLE IF NOT EXISTS replies (
     occurrence text PRIMARY KEY, seller text NOT NULL, outcome text NOT NULL,
     message text NOT NULL, from_agent bool NOT NULL, agent_message text NOT NULL)",
]

/// Create the schema and the application's tables.
pub fn migrate(db: pog.Connection, schema: String) -> Result(Nil, DbError) {
  use Nil <- result.try(exec(
    db,
    pog.query("CREATE SCHEMA IF NOT EXISTS \"" <> schema <> "\""),
  ))
  list.try_each(tables, fn(text) { exec(db, pog.query(text)) })
}

// -- The marketplace's world -------------------------------------------------------------

pub fn put_seller(
  db: pog.Connection,
  id: String,
  balance_cents: Int,
) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO sellers (id, balance_cents) VALUES ($1, $2)
     ON CONFLICT (id) DO UPDATE SET balance_cents = $2",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(balance_cents))
  |> exec(db, _)
}

pub fn put_order(db: pog.Connection, order: Order) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO orders (id, seller, total_cents, status) VALUES ($1, $2, $3, $4)
     ON CONFLICT (id) DO UPDATE SET status = $4",
  )
  |> pog.parameter(pog.text(order.id))
  |> pog.parameter(pog.text(order.seller))
  |> pog.parameter(pog.int(order.total_cents))
  |> pog.parameter(pog.text(order.status))
  |> exec(db, _)
}

pub fn put_dispute(
  db: pog.Connection,
  dispute: Dispute,
) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO disputes (order_id, status, seller_owed_cents, fee_cents, note)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (order_id) DO UPDATE SET status = $2, seller_owed_cents = $3,
       fee_cents = $4, note = $5",
  )
  |> pog.parameter(pog.text(dispute.order))
  |> pog.parameter(pog.text(dispute.status))
  |> pog.parameter(pog.int(dispute.seller_owed_cents))
  |> pog.parameter(pog.int(dispute.fee_cents))
  |> pog.parameter(pog.text(dispute.note))
  |> exec(db, _)
}

pub fn add_paid_out(
  db: pog.Connection,
  seller: String,
  amount_cents: Int,
) -> Result(Nil, DbError) {
  pog.query("INSERT INTO paid_out (seller, amount_cents) VALUES ($1, $2)")
  |> pog.parameter(pog.text(seller))
  |> pog.parameter(pog.int(amount_cents))
  |> exec(db, _)
}

pub fn add_chargeback(
  db: pog.Connection,
  seller: String,
  days_ago: Int,
) -> Result(Nil, DbError) {
  pog.query("INSERT INTO chargebacks (seller, days_ago) VALUES ($1, $2)")
  |> pog.parameter(pog.text(seller))
  |> pog.parameter(pog.int(days_ago))
  |> exec(db, _)
}

pub fn order(db: pog.Connection, id: String) -> Result(Order, DbError) {
  pog.query("SELECT id, seller, total_cents, status FROM orders WHERE id = $1")
  |> pog.parameter(pog.text(id))
  |> one(db, _, "order " <> id, {
    use id <- decode.field(0, decode.string)
    use seller <- decode.field(1, decode.string)
    use total_cents <- decode.field(2, decode.int)
    use status <- decode.field(3, decode.string)
    decode.success(Order(id:, seller:, total_cents:, status:))
  })
}

pub fn dispute(db: pog.Connection, order: String) -> Result(Dispute, DbError) {
  pog.query(
    "SELECT order_id, status, seller_owed_cents, fee_cents, note FROM disputes
     WHERE order_id = $1",
  )
  |> pog.parameter(pog.text(order))
  |> one(db, _, "dispute of " <> order, {
    use order <- decode.field(0, decode.string)
    use status <- decode.field(1, decode.string)
    use seller_owed_cents <- decode.field(2, decode.int)
    use fee_cents <- decode.field(3, decode.int)
    use note <- decode.field(4, decode.string)
    decode.success(Dispute(
      order:,
      status:,
      seller_owed_cents:,
      fee_cents:,
      note:,
    ))
  })
}

pub fn history(db: pog.Connection, seller: String) -> Result(History, DbError) {
  use paid <- result.try(
    pog.query("SELECT amount_cents FROM paid_out WHERE seller = $1 ORDER BY 1")
    |> pog.parameter(pog.text(seller))
    |> all(db, _, decode.at([0], decode.int)),
  )
  use chargebacks <- result.map(chargebacks_90_days(db, seller))
  History(seller:, paid_cents: paid, chargebacks_90_days: chargebacks)
}

pub fn chargebacks_90_days(
  db: pog.Connection,
  seller: String,
) -> Result(Int, DbError) {
  pog.query(
    "SELECT count(*) FROM chargebacks WHERE seller = $1 AND days_ago <= 90",
  )
  |> pog.parameter(pog.text(seller))
  |> one(db, _, "chargebacks", decode.at([0], decode.int))
}

// -- Requests -----------------------------------------------------------------------------

pub fn put_request(
  db: pog.Connection,
  request: Request,
  requested_by: String,
) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO requests (id, seller, order_id, text, requested_by)
     VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING",
  )
  |> pog.parameter(pog.text(request.id))
  |> pog.parameter(pog.text(request.seller))
  |> pog.parameter(pog.text(request.order))
  |> pog.parameter(pog.text(request.text))
  |> pog.parameter(pog.text(requested_by))
  |> exec(db, _)
}

/// The request and who asked for it.
pub fn request(
  db: pog.Connection,
  id: String,
) -> Result(#(Request, String), DbError) {
  pog.query(
    "SELECT id, seller, order_id, text, requested_by FROM requests WHERE id = $1",
  )
  |> pog.parameter(pog.text(id))
  |> one(db, _, "request " <> id, {
    use id <- decode.field(0, decode.string)
    use seller <- decode.field(1, decode.string)
    use order <- decode.field(2, decode.string)
    use text <- decode.field(3, decode.string)
    use requested_by <- decode.field(4, decode.string)
    decode.success(#(domain.Request(id:, seller:, order:, text:), requested_by))
  })
}

/// Name the occurrence the request's gated call was admitted as. Written
/// in the transaction that admits it, so the request and the record agree.
pub fn admitted(
  tx: pog.Connection,
  request: String,
  occurrence: String,
) -> Result(Nil, DbError) {
  pog.query("UPDATE requests SET occurrence = $2 WHERE id = $1")
  |> pog.parameter(pog.text(request))
  |> pog.parameter(pog.text(occurrence))
  |> exec(tx, _)
}

/// The occurrence a request was admitted as, once its agent proposed.
pub fn occurrence_of(
  db: pog.Connection,
  request: String,
) -> Result(Option(String), DbError) {
  pog.query("SELECT occurrence FROM requests WHERE id = $1")
  |> pog.parameter(pog.text(request))
  |> one(
    db,
    _,
    "request " <> request,
    decode.at([0], decode.optional(decode.string)),
  )
}

/// The request whose gated call an occurrence is.
pub fn request_of(
  db: pog.Connection,
  occurrence: String,
) -> Result(String, DbError) {
  pog.query("SELECT id FROM requests WHERE occurrence = $1")
  |> pog.parameter(pog.text(occurrence))
  |> one(db, _, "request of " <> occurrence, decode.at([0], decode.string))
}

/// The request as the context holds it: JSON, under a reference whose
/// revision names that exact content.
pub fn request_document(request: Request) -> #(Ref, String) {
  let body = codec.encode_json(domain.request_codec(), request)
  let body = result.unwrap(body, "")
  #(Ref(kind: "request", id: request.id, revision: model.digest(body)), body)
}

// -- Evidence -------------------------------------------------------------------------------

/// Evidence in the `evidence` table: written once, never changed.
pub fn evidence() -> model.Evidence(pog.Connection) {
  model.Evidence(
    put: fn(db, ref: Ref, body) {
      pog.query(
        "INSERT INTO evidence (kind, id, revision, body) VALUES ($1, $2, $3, $4)
         ON CONFLICT DO NOTHING",
      )
      |> pog.parameter(pog.text(ref.kind))
      |> pog.parameter(pog.text(ref.id))
      |> pog.parameter(pog.text(ref.revision))
      |> pog.parameter(pog.text(body))
      |> exec(db, _)
      |> result.map_error(describe)
    },
    get: fn(db, ref: Ref) {
      pog.query(
        "SELECT body FROM evidence WHERE kind = $1 AND id = $2 AND revision = $3",
      )
      |> pog.parameter(pog.text(ref.kind))
      |> pog.parameter(pog.text(ref.id))
      |> pog.parameter(pog.text(ref.revision))
      |> one(db, _, "evidence", decode.at([0], decode.string))
      |> result.map_error(describe)
    },
  )
}

// -- Policies ---------------------------------------------------------------------------------

/// Publish a policy version for `point`, refused unless the point may use
/// it (`decisions.publishable`).
pub fn publish(
  db: pog.Connection,
  point: decisions.Point(o),
  published: Policy,
) -> Result(Nil, DbError) {
  use Nil <- result.try(
    decisions.publishable(point, published)
    |> result.map_error(fn(faults) {
      Query(string.join(list.map(faults, policy.describe), "; "))
    }),
  )
  pog.query(
    "INSERT INTO policies (point, version, body) VALUES ($1, $2, $3)
     ON CONFLICT (point, version) DO NOTHING",
  )
  |> pog.parameter(pog.text(decisions.name(point)))
  |> pog.parameter(pog.int(published.version))
  |> pog.parameter(pog.text(json.to_string(policy.to_json(published))))
  |> exec(db, _)
}

/// The latest published version of `point`'s policy, read in the caller's
/// transaction.
pub fn current_policy(
  tx: pog.Connection,
  point: String,
) -> Result(Policy, String) {
  use body <- result.try(
    pog.query(
      "SELECT body FROM policies WHERE point = $1 ORDER BY version DESC LIMIT 1",
    )
    |> pog.parameter(pog.text(point))
    |> one(tx, _, "policy of " <> point, decode.at([0], decode.string))
    |> result.map_error(describe),
  )
  json.parse(body, policy.decoder())
  |> result.replace_error(
    "the stored policy of " <> point <> " does not decode",
  )
}

// -- Staff --------------------------------------------------------------------------------------

pub fn put_staff(
  db: pog.Connection,
  subject: String,
  sets: List(String),
) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO staff (subject, sets) VALUES ($1, $2)
     ON CONFLICT (subject) DO UPDATE SET sets = $2",
  )
  |> pog.parameter(pog.text(subject))
  |> pog.parameter(pog.array(pog.text, sets))
  |> exec(db, _)
}

/// The validator an authenticated subject is: the decision sets the
/// application gives them. Someone who is not staff holds none.
pub fn validator(
  db: pog.Connection,
  subject: String,
) -> Result(Validator, DbError) {
  pog.query("SELECT sets FROM staff WHERE subject = $1")
  |> pog.parameter(pog.text(subject))
  |> all(db, _, decode.at([0], decode.list(decode.string)))
  |> result.map(fn(rows) {
    Validator(subject:, holds: list.first(rows) |> result.unwrap([]))
  })
}

// -- The gated tool's instruction -------------------------------------------------------------

pub type Instruction {
  Instruction(
    release_key: String,
    occurrence: String,
    seller: String,
    order: String,
    amount_cents: Int,
  )
}

/// What the seller's account allows now: its status and the balance not
/// yet reserved.
pub fn available(
  tx: pog.Connection,
  seller: String,
) -> Result(#(String, Int), DbError) {
  pog.query(
    "SELECT status, balance_cents - reserved_cents FROM sellers WHERE id = $1 FOR UPDATE",
  )
  |> pog.parameter(pog.text(seller))
  |> one(tx, _, "seller " <> seller, {
    use status <- decode.field(0, decode.string)
    use available <- decode.field(1, decode.int)
    decode.success(#(status, available))
  })
}

/// Write the instruction the workflow carries out. The release check has
/// already compared its amount with the balance (`desks`).
pub fn write_instruction(
  tx: pog.Connection,
  instruction: Instruction,
) -> Result(Nil, DbError) {
  pog.query(
    "INSERT INTO instructions (release_key, occurrence, seller, order_id, amount_cents)
     VALUES ($1, $2, $3, $4, $5)",
  )
  |> pog.parameter(pog.text(instruction.release_key))
  |> pog.parameter(pog.text(instruction.occurrence))
  |> pog.parameter(pog.text(instruction.seller))
  |> pog.parameter(pog.text(instruction.order))
  |> pog.parameter(pog.int(instruction.amount_cents))
  |> exec(tx, _)
}

pub fn instruction(
  db: pog.Connection,
  release_key: String,
) -> Result(Instruction, DbError) {
  pog.query(
    "SELECT release_key, occurrence, seller, order_id, amount_cents FROM instructions
     WHERE release_key = $1",
  )
  |> pog.parameter(pog.text(release_key))
  |> one(db, _, "instruction " <> release_key, instruction_decoder())
}

pub fn instructions_of(
  db: pog.Connection,
  occurrence: String,
) -> Result(Int, DbError) {
  pog.query("SELECT count(*) FROM instructions WHERE occurrence = $1")
  |> pog.parameter(pog.text(occurrence))
  |> one(db, _, "count", decode.at([0], decode.int))
}

fn instruction_decoder() -> decode.Decoder(Instruction) {
  use release_key <- decode.field(0, decode.string)
  use occurrence <- decode.field(1, decode.string)
  use seller <- decode.field(2, decode.string)
  use order <- decode.field(3, decode.string)
  use amount_cents <- decode.field(4, decode.int)
  decode.success(Instruction(
    release_key:,
    occurrence:,
    seller:,
    order:,
    amount_cents:,
  ))
}

// -- The workflow's reservation and posting ---------------------------------------------------

/// Reserve the instruction's amount from the seller's balance, once per
/// release key.
pub fn reserve(
  db: pog.Connection,
  instruction: Instruction,
) -> Result(Nil, DbError) {
  transaction(db, fn(tx) {
    case reservation(tx, instruction.release_key) {
      Ok(Some(_)) -> Ok(Nil)
      Ok(None) -> {
        use #(_, available) <- result.try(available(tx, instruction.seller))
        use Nil <- result.try(case available >= instruction.amount_cents {
          True -> Ok(Nil)
          False -> Error(Insufficient(available, instruction.amount_cents))
        })
        use Nil <- result.try(
          pog.query(
            "INSERT INTO reservations (release_key, seller, amount_cents, state)
             VALUES ($1, $2, $3, 'held')",
          )
          |> pog.parameter(pog.text(instruction.release_key))
          |> pog.parameter(pog.text(instruction.seller))
          |> pog.parameter(pog.int(instruction.amount_cents))
          |> exec(tx, _),
        )
        pog.query(
          "UPDATE sellers SET reserved_cents = reserved_cents + $2 WHERE id = $1",
        )
        |> pog.parameter(pog.text(instruction.seller))
        |> pog.parameter(pog.int(instruction.amount_cents))
        |> exec(tx, _)
      }
      Error(error) -> Error(error)
    }
  })
}

/// Give a held reservation back to the balance. Releasing twice, or a
/// reservation already posted, changes nothing.
pub fn release(
  db: pog.Connection,
  release_key: String,
) -> Result(Nil, DbError) {
  pog.query(
    "WITH released AS (
       UPDATE reservations SET state = 'released'
       WHERE release_key = $1 AND state = 'held' RETURNING seller, amount_cents)
     UPDATE sellers s SET reserved_cents = s.reserved_cents - r.amount_cents
     FROM released r WHERE s.id = r.seller",
  )
  |> pog.parameter(pog.text(release_key))
  |> exec(db, _)
}

/// Post a paid reservation: the balance goes down by the amount and the
/// provider's receipt is kept. Posting twice changes nothing.
pub fn post(
  db: pog.Connection,
  release_key: String,
  receipt: String,
) -> Result(Nil, DbError) {
  pog.query(
    "WITH posted AS (
       UPDATE reservations SET state = 'posted'
       WHERE release_key = $1 AND state = 'held' RETURNING release_key, seller, amount_cents),
     kept AS (
       INSERT INTO postings (release_key, seller, amount_cents, receipt)
       SELECT release_key, seller, amount_cents, $2 FROM posted)
     UPDATE sellers s SET reserved_cents = s.reserved_cents - p.amount_cents,
       balance_cents = s.balance_cents - p.amount_cents
     FROM posted p WHERE s.id = p.seller",
  )
  |> pog.parameter(pog.text(release_key))
  |> pog.parameter(pog.text(receipt))
  |> exec(db, _)
}

/// The reservation's state: `held`, `released` or `posted`.
pub fn reservation(
  db: pog.Connection,
  release_key: String,
) -> Result(Option(String), DbError) {
  pog.query("SELECT state FROM reservations WHERE release_key = $1")
  |> pog.parameter(pog.text(release_key))
  |> all(db, _, decode.at([0], decode.string))
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub fn posting(
  db: pog.Connection,
  release_key: String,
) -> Result(Option(String), DbError) {
  pog.query("SELECT receipt FROM postings WHERE release_key = $1")
  |> pog.parameter(pog.text(release_key))
  |> all(db, _, decode.at([0], decode.string))
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// The seller's balance and reserved amount.
pub fn balance(
  db: pog.Connection,
  seller: String,
) -> Result(#(Int, Int), DbError) {
  pog.query("SELECT balance_cents, reserved_cents FROM sellers WHERE id = $1")
  |> pog.parameter(pog.text(seller))
  |> one(db, _, "seller " <> seller, {
    use balance <- decode.field(0, decode.int)
    use reserved <- decode.field(1, decode.int)
    decode.success(#(balance, reserved))
  })
}

// -- Replies ---------------------------------------------------------------------------------

pub type Told {
  Told(
    seller: String,
    outcome: String,
    /// What the seller was sent.
    message: String,
    /// Whether that is the agent's own message, or the application's
    /// because the agent's claimed something the record does not say.
    from_agent: Bool,
    /// What the agent said, sent or not.
    agent_message: String,
  )
}

/// Keep what the seller is told about one payout, once.
pub fn tell(
  tx: pog.Connection,
  occurrence: String,
  told: Told,
) -> Result(Bool, DbError) {
  pog.query(
    "INSERT INTO replies (occurrence, seller, outcome, message, from_agent, agent_message)
     VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (occurrence) DO NOTHING",
  )
  |> pog.parameter(pog.text(occurrence))
  |> pog.parameter(pog.text(told.seller))
  |> pog.parameter(pog.text(told.outcome))
  |> pog.parameter(pog.text(told.message))
  |> pog.parameter(pog.bool(told.from_agent))
  |> pog.parameter(pog.text(told.agent_message))
  |> pog.execute(tx)
  |> result.map(fn(returned) { returned.count == 1 })
  |> result.map_error(query_error)
}

pub fn told(
  db: pog.Connection,
  occurrence: String,
) -> Result(Option(Told), DbError) {
  pog.query(
    "SELECT seller, outcome, message, from_agent, agent_message FROM replies
     WHERE occurrence = $1",
  )
  |> pog.parameter(pog.text(occurrence))
  |> all(db, _, {
    use seller <- decode.field(0, decode.string)
    use outcome <- decode.field(1, decode.string)
    use message <- decode.field(2, decode.string)
    use from_agent <- decode.field(3, decode.bool)
    use agent_message <- decode.field(4, decode.string)
    decode.success(Told(
      seller:,
      outcome:,
      message:,
      from_agent:,
      agent_message:,
    ))
  })
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

// -- Helpers -----------------------------------------------------------------------------------

pub fn transaction(
  db: pog.Connection,
  body: fn(pog.Connection) -> Result(a, DbError),
) -> Result(a, DbError) {
  pog.transaction(db, body)
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> query_error(error)
    }
  })
}

fn exec(db: pog.Connection, query: pog.Query(a)) -> Result(Nil, DbError) {
  pog.execute(query, db)
  |> result.replace(Nil)
  |> result.map_error(query_error)
}

fn all(
  db: pog.Connection,
  query: pog.Query(a),
  decoder: decode.Decoder(b),
) -> Result(List(b), DbError) {
  query
  |> pog.returning(decoder)
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(query_error)
}

fn one(
  db: pog.Connection,
  query: pog.Query(a),
  what: String,
  decoder: decode.Decoder(b),
) -> Result(b, DbError) {
  use rows <- result.try(all(db, query, decoder))
  case rows {
    [row, ..] -> Ok(row)
    [] -> Error(NotFound(what))
  }
}

pub fn query_error(error: pog.QueryError) -> DbError {
  Query(string.inspect(error))
}
