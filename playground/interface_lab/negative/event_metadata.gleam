// THROWAWAY: Reject metadata inconsistent with the shared event descriptor.
import consumers/observation
import lab/sinal

pub fn invalid(backend: sinal.Backend) {
  sinal.emit(backend, observation.event(), 17, 42)
}
