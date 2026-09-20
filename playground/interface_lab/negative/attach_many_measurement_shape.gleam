// THROWAWAY: A single attachment group has one measurement type.
import lab/sinal

pub fn invalid(
  backend: sinal.Backend,
  id: sinal.HandlerId,
  first: sinal.Event(Int, String),
  other: sinal.Event(Bool, String),
  handler: sinal.Handler(Int, String, Nil),
) {
  sinal.attach_many(backend, id, first, [other], handler, fn(_, _) { Nil })
}
