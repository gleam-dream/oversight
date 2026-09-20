// THROWAWAY: An event descriptor does not own a registration.
import lab/sinal

pub fn invalid(event: sinal.Event(Int, String)) {
  sinal.detach(event)
}
