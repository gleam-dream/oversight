//// Application financial records. These records outlive queue receipts.

import financial_recovery/domain.{
  type Error, type Operation, type OperationId, type Payment,
}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import pog

const schema = [
  "CREATE TABLE accounts (id text PRIMARY KEY, balance bigint NOT NULL CHECK(balance >= 0), reserved bigint NOT NULL DEFAULT 0 CHECK(reserved >= 0 AND reserved <= balance))",
  "CREATE TABLE operations (id text PRIMARY KEY, debit text NOT NULL REFERENCES accounts, credit text NOT NULL REFERENCES accounts, cents bigint NOT NULL CHECK(cents > 0), reference text, posted boolean NOT NULL DEFAULT false)",
  "CREATE TABLE payment_evidence (operation text PRIMARY KEY REFERENCES operations, reference text NOT NULL)",
  "CREATE TABLE postings (operation text PRIMARY KEY REFERENCES operations, reference text NOT NULL)",
]

pub fn migrate(connection: pog.Connection) -> Result(Nil, Error) {
  list.try_each(schema, fn(sql) {
    pog.query(sql)
    |> pog.execute(connection)
    |> result.replace(Nil)
    |> result.map_error(domain.Database)
  })
}

pub fn account(
  connection: pog.Connection,
  id: String,
  cents: Int,
) -> Result(Nil, Error) {
  pog.query("INSERT INTO accounts(id,balance) VALUES($1,$2)")
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(cents))
  |> pog.execute(connection)
  |> result.replace(Nil)
  |> result.map_error(domain.Database)
}

/// Both rows are locked in ID order by every balance writer. This protects
/// balance >= reserved >= 0 for these known accounts under READ COMMITTED;
/// it makes no claim about arbitrary predicates or writers bypassing this rule.
fn lock_accounts(tx: pog.Connection, payment: Payment) -> Result(Nil, Error) {
  use rows <- result.try(
    pog.query(
      "SELECT id FROM accounts WHERE id IN ($1,$2) ORDER BY id FOR UPDATE",
    )
    |> pog.parameter(pog.text(payment.debit))
    |> pog.parameter(pog.text(payment.credit))
    |> pog.execute(tx)
    |> result.map_error(domain.Database),
  )
  case rows.count {
    2 -> Ok(Nil)
    _ -> Error(domain.AccountMissing)
  }
}

pub fn reserve_in(tx: pog.Connection, payment: Payment) -> Result(Nil, Error) {
  case
    payment.cents > 0
    && payment.debit != payment.credit
    && domain.id(payment.id) != ""
  {
    False -> Error(domain.InvalidPayment)
    True -> {
      use Nil <- result.try(lock_accounts(tx, payment))
      use inserted <- result.try(
        pog.query(
          "INSERT INTO operations(id,debit,credit,cents) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",
        )
        |> pog.parameter(pog.text(domain.id(payment.id)))
        |> pog.parameter(pog.text(payment.debit))
        |> pog.parameter(pog.text(payment.credit))
        |> pog.parameter(pog.int(payment.cents))
        |> pog.execute(tx)
        |> result.map_error(domain.Database),
      )
      case inserted.count {
        0 -> {
          use existing <- result.try(read(tx, payment.id))
          case existing.payment == payment {
            True -> Ok(Nil)
            False -> Error(domain.IdentityConflict)
          }
        }
        _ -> {
          use changed <- result.try(
            pog.query(
              "UPDATE accounts SET reserved=reserved+$2 WHERE id=$1 AND balance-reserved >= $2",
            )
            |> pog.parameter(pog.text(payment.debit))
            |> pog.parameter(pog.int(payment.cents))
            |> pog.execute(tx)
            |> result.map_error(domain.Database),
          )
          case changed.count {
            1 -> Ok(Nil)
            _ -> Error(domain.InsufficientFunds)
          }
        }
      }
    }
  }
}

pub fn read(
  connection: pog.Connection,
  id: OperationId,
) -> Result(Operation, Error) {
  use rows <- result.try(
    pog.query(
      "SELECT debit,credit,cents,reference,posted FROM operations WHERE id=$1",
    )
    |> pog.parameter(pog.text(domain.id(id)))
    |> pog.returning({
      use debit <- decode.field(0, decode.string)
      use credit <- decode.field(1, decode.string)
      use cents <- decode.field(2, decode.int)
      use reference <- decode.field(3, decode.optional(decode.string))
      use posted <- decode.field(4, decode.bool)
      let state = case reference, posted {
        Some(reference), True -> domain.Posted(reference)
        Some(reference), False -> domain.Confirmed(reference)
        None, _ -> domain.Reserved
      }
      decode.success(domain.Operation(
        domain.Payment(id, debit, credit, cents),
        state,
      ))
    })
    |> pog.execute(connection)
    |> result.map_error(domain.Database),
  )
  list.first(rows.rows) |> result.replace_error(domain.OperationMissing)
}

pub fn balance(
  connection: pog.Connection,
  id: String,
) -> Result(#(Int, Int), Error) {
  use rows <- result.try(
    pog.query("SELECT balance,reserved FROM accounts WHERE id=$1")
    |> pog.parameter(pog.text(id))
    |> pog.returning({
      use balance <- decode.field(0, decode.int)
      use reserved <- decode.field(1, decode.int)
      decode.success(#(balance, reserved))
    })
    |> pog.execute(connection)
    |> result.map_error(domain.Database),
  )
  list.first(rows.rows) |> result.replace_error(domain.AccountMissing)
}

/// Only the provider adapter or an authenticated reconciliation path supplies
/// evidence. Receiving the same evidence twice does not duplicate posting.
pub fn evidence(
  connection: pog.Connection,
  id: OperationId,
  reference: String,
) -> Result(Nil, Error) {
  pog.transaction(connection, fn(tx) { evidence_in(tx, id, reference) })
  |> result.map_error(transaction_error)
}

fn evidence_in(
  tx: pog.Connection,
  id: OperationId,
  reference: String,
) -> Result(Nil, Error) {
  use locked <- result.try(
    pog.query("SELECT reference FROM operations WHERE id=$1 FOR UPDATE")
    |> pog.parameter(pog.text(domain.id(id)))
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(tx)
    |> result.map_error(domain.Database),
  )
  case locked.rows {
    [] -> Error(domain.OperationMissing)
    [Some(old)] if old != reference -> Error(domain.EvidenceConflict)
    _ -> {
      use _ <- result.try(
        pog.query(
          "INSERT INTO payment_evidence(operation,reference) VALUES($1,$2) ON CONFLICT DO NOTHING",
        )
        |> pog.parameter(pog.text(domain.id(id)))
        |> pog.parameter(pog.text(reference))
        |> pog.execute(tx)
        |> result.map_error(domain.Database),
      )
      pog.query("UPDATE operations SET reference=$2 WHERE id=$1")
      |> pog.parameter(pog.text(domain.id(id)))
      |> pog.parameter(pog.text(reference))
      |> pog.execute(tx)
      |> result.replace(Nil)
      |> result.map_error(domain.Database)
    }
  }
}

pub fn post(
  connection: pog.Connection,
  id: OperationId,
) -> Result(String, Error) {
  pog.transaction(connection, fn(tx) { post_in(tx, id) })
  |> result.map_error(transaction_error)
}

fn post_in(tx: pog.Connection, id: OperationId) -> Result(String, Error) {
  use operation <- result.try(read(tx, id))
  use Nil <- result.try(lock_accounts(tx, operation.payment))
  // Re-read after account locks: another poster may have committed while
  // this transaction waited. All posting writers follow this lock order.
  use operation <- result.try(read(tx, id))
  case operation.state {
    domain.Reserved -> Error(domain.EvidenceRequired)
    domain.Posted(reference) -> Ok(reference)
    domain.Confirmed(reference) -> {
      use _ <- result.try(
        pog.query("INSERT INTO postings(operation,reference) VALUES($1,$2)")
        |> pog.parameter(pog.text(domain.id(id)))
        |> pog.parameter(pog.text(reference))
        |> pog.execute(tx)
        |> result.map_error(domain.Database),
      )
      use _ <- result.try(
        pog.query(
          "UPDATE accounts SET balance=balance-$2,reserved=reserved-$2 WHERE id=$1",
        )
        |> pog.parameter(pog.text(operation.payment.debit))
        |> pog.parameter(pog.int(operation.payment.cents))
        |> pog.execute(tx)
        |> result.map_error(domain.Database),
      )
      use _ <- result.try(
        pog.query("UPDATE accounts SET balance=balance+$2 WHERE id=$1")
        |> pog.parameter(pog.text(operation.payment.credit))
        |> pog.parameter(pog.int(operation.payment.cents))
        |> pog.execute(tx)
        |> result.map_error(domain.Database),
      )
      pog.query("UPDATE operations SET posted=true WHERE id=$1")
      |> pog.parameter(pog.text(domain.id(id)))
      |> pog.execute(tx)
      |> result.replace(reference)
      |> result.map_error(domain.Database)
    }
  }
}

pub fn posting(
  connection: pog.Connection,
  id: OperationId,
) -> Result(String, Error) {
  use rows <- result.try(
    pog.query("SELECT reference FROM postings WHERE operation=$1")
    |> pog.parameter(pog.text(domain.id(id)))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(connection)
    |> result.map_error(domain.Database),
  )
  list.first(rows.rows) |> result.replace_error(domain.EvidenceRequired)
}

pub fn transaction_error(error: pog.TransactionError(Error)) -> Error {
  case error {
    pog.TransactionRolledBack(error) -> error
    pog.TransactionQueryError(error) -> domain.Database(error)
  }
}

/// Records confirmed evidence and posts inside the caller's transaction.
/// The account-before-operation lock order matches the posting path.
pub fn settle_in(
  tx: pog.Connection,
  payment: Payment,
  reference: String,
) -> Result(String, Error) {
  use Nil <- result.try(lock_accounts(tx, payment))
  use operation <- result.try(read(tx, payment.id))
  case operation.payment == payment {
    False -> Error(domain.IdentityConflict)
    True -> {
      use Nil <- result.try(evidence_in(tx, payment.id, reference))
      post_in(tx, payment.id)
    }
  }
}
