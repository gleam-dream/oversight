// THROWAWAY: Reject metadata inconsistent with the shared event descriptor.
import consumers/observation
import lab/sinal

pub fn invalid() {
  sinal.emit(observation.event(), 17, 42)
}
