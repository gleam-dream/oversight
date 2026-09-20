import consumers/observation
import lab/sinal

pub fn invalid(id: sinal.HandlerId) {
  let handler = sinal.handler(fn(_event, _: Int, _: Bool) { Ok(Nil) })
  sinal.attach(id, observation.event(), handler, fn(_, _) { Nil })
}
