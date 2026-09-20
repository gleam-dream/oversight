import consumers/observation
import lab/sinal

pub fn invalid(backend: sinal.Backend, id: sinal.HandlerId) {
  let handler = sinal.handler(fn(_event, _: Int, _: Bool) { Ok(Nil) })
  sinal.attach(backend, id, observation.event(), handler, fn(_, _) { Nil })
}
