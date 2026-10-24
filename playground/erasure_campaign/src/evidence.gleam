import domain.{type Command, type Receipt, Receipt}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import http_gun/error
import pog

pub type Evidence {
  Unseen
  Pending
  Confirmed(Receipt)
  Rejected
}

pub fn install(db: pog.Connection) {
  list.each(
    [
      "CREATE TABLE erasure_evidence (identity text PRIMARY KEY, state text NOT NULL, receipt text NOT NULL DEFAULT '', transport text)",
      "CREATE TABLE erasure_preparation (operation text PRIMARY KEY, frozen boolean NOT NULL, staged boolean NOT NULL, undos integer NOT NULL DEFAULT 0)",
    ],
    fn(sql) {
      let assert Ok(_) = pog.query(sql) |> pog.execute(db)
    },
  )
}

pub fn transport_failure(
  db: pog.Connection,
  command: Command,
  failure: error.Failure,
) {
  let assert Ok(_) =
    pog.query("UPDATE erasure_evidence SET transport=$2 WHERE identity=$1")
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.parameter(pog.text(error.to_json(failure) |> json.to_string))
    |> pog.execute(db)
  Nil
}

pub fn failure(db: pog.Connection, command: Command) -> error.Failure {
  let assert Ok(rows) =
    pog.query("SELECT transport FROM erasure_evidence WHERE identity=$1")
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.returning({
      use text <- decode.field(0, decode.string)
      decode.success(text)
    })
    |> pog.execute(db)
  let assert [text] = rows.rows
  let assert Ok(failure) = json.parse(text, error.decoder())
  failure
}

pub fn read(db: pog.Connection, command: Command) -> Evidence {
  let assert Ok(rows) =
    pog.query("SELECT state,receipt FROM erasure_evidence WHERE identity=$1")
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.returning({
      use state <- decode.field(0, decode.string)
      use receipt <- decode.field(1, decode.string)
      decode.success(#(state, receipt))
    })
    |> pog.execute(db)
  case rows.rows {
    [] -> Unseen
    [#("pending", _)] -> Pending
    [#("confirmed", receipt)] -> Confirmed(Receipt(receipt))
    [#("rejected", _)] -> Rejected
    _ -> panic as "invalid application evidence"
  }
}

/// A committed attempt marker prevents a fresh delivery from blindly repeating DELETE.
/// It deliberately does not infer nonexecution when an effect lookup returns 404.
pub fn begin(db: pog.Connection, command: Command) -> Bool {
  let assert Ok(rows) =
    pog.query(
      "INSERT INTO erasure_evidence(identity,state) VALUES($1,'pending') ON CONFLICT DO NOTHING",
    )
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.execute(db)
  rows.count == 1
}

pub fn confirm(db: pog.Connection, command: Command, receipt: Receipt) {
  let assert Ok(rows) =
    pog.query(
      "UPDATE erasure_evidence SET state='confirmed',receipt=$2 WHERE identity=$1 AND (state='pending' OR (state='confirmed' AND receipt=$2))",
    )
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.parameter(pog.text(receipt.reference))
    |> pog.execute(db)
  assert rows.count == 1
}

pub fn reject(db: pog.Connection, command: Command) {
  let assert Ok(_) =
    pog.query("UPDATE erasure_evidence SET state='rejected' WHERE identity=$1")
    |> pog.parameter(pog.text(domain.identity(command)))
    |> pog.execute(db)
  Nil
}
