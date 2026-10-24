// THROWAWAY: Can a runtime-validated Value become a native application type?
import lab/blueprint_runtime

pub type Order {
  Order(id: String)
}

fn accept_order(_order: Order) -> Nil {
  Nil
}

pub fn invalid(witness: blueprint_runtime.ValidatedValue) -> Nil {
  accept_order(witness)
}
