import gleam/dynamic/decode
import gleam/json
import pog

pub type OperationId {
  OperationId(String)
}

pub type Payment {
  Payment(id: OperationId, debit: String, credit: String, cents: Int)
}

pub type State {
  Reserved
  Confirmed(reference: String)
  Posted(reference: String)
}

pub type Operation {
  Operation(payment: Payment, state: State)
}

pub type Error {
  InvalidPayment
  IdentityConflict
  InsufficientFunds
  AccountMissing
  OperationMissing
  EvidenceConflict
  EvidenceRequired
  Database(pog.QueryError)
}

pub fn id(id: OperationId) -> String {
  let OperationId(value) = id
  value
}

pub fn encode(payment: Payment) -> json.Json {
  json.object([
    #("id", json.string(id(payment.id))),
    #("debit", json.string(payment.debit)),
    #("credit", json.string(payment.credit)),
    #("cents", json.int(payment.cents)),
  ])
}

pub fn decoder() -> decode.Decoder(Payment) {
  use id <- decode.field("id", decode.string)
  use debit <- decode.field("debit", decode.string)
  use credit <- decode.field("credit", decode.string)
  use cents <- decode.field("cents", decode.int)
  decode.success(Payment(OperationId(id), debit, credit, cents))
}
