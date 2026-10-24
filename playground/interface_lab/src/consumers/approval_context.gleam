// THROWAWAY: Can approval retain trusted input separately from the answer?
import lab/blueprint
import lab/saga
import lab/value

pub type Order {
  Order(sku: String, quantity: Int)
}

pub type Decision {
  PlaceOriginalOrder(Order)
  Declined(Order)
}

pub fn decide(approval: saga.ApprovalResult(Order, Bool)) -> Decision {
  case approval.decision {
    saga.Approved(True) -> PlaceOriginalOrder(approval.input)
    saga.Approved(False) -> Declined(approval.input)
    saga.Denied -> Declined(approval.input)
  }
}

pub fn codec() -> blueprint.Codec(saga.ApprovalResult(Order, Bool)) {
  let order =
    blueprint.imap(
      blueprint.pair(blueprint.text(), blueprint.int()),
      fn(pair) { Order(pair.0, pair.1) },
      fn(order) { #(order.sku, order.quantity) },
    )
  saga.approval_result_codec(order, blueprint.bool())
}

// Pure construction/codec probe only; no approval store or workflow is run.
pub fn probe() -> Nil {
  let original = Order("original-sku", 3)
  let approved = saga.ApprovalResult(original, saga.Approved(True))
  let assert Ok(encoded) = blueprint.encode(codec(), approved)
  let assert Ok(decoded) = blueprint.decode(codec(), encoded)
  let assert True = decoded.input == original
  let assert True = decide(decoded) == PlaceOriginalOrder(original)
  let assert True =
    decide(saga.ApprovalResult(original, saga.Denied)) == Declined(original)
  let bad_quantity =
    value.Array([
      value.Array([value.Text("original-sku"), value.Text("three")]),
      value.Object([#("approved", value.Bool(True))]),
    ])
  let assert Error(blueprint.DecodeAtIndex(0, blueprint.DecodeAtIndex(1, _))) =
    blueprint.decode(codec(), bad_quantity)
  Nil
}
