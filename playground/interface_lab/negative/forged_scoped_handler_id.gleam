// THROWAWAY: Public names cannot manufacture a private scoped registration ID.
import lab/sinal

pub fn invalid() -> sinal.HandlerId {
  sinal.ScopedHandlerId(1)
}
