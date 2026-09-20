// THROWAWAY: A scoped attachment group has one metadata type.
import lab/sinal

pub fn invalid(
  first: sinal.Event(Int, String),
  other: sinal.Event(Int, Bool),
  handler: sinal.Handler(Int, String, Nil),
) {
  sinal.with_attachments(first, [other], handler, fn(_, _) { Nil }, fn() { Nil })
}
