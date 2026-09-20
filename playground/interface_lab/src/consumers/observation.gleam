// THROWAWAY: Can an event constrain both measurements and metadata?
import lab/blueprint
import lab/sinal
import lab/sinal_fields

pub fn event() -> sinal.Event(Int, String) {
  sinal.event(
    ["application", "completed"],
    sinal_fields.field("duration", blueprint.int()),
    sinal_fields.field("run", blueprint.text()),
  )
}

pub fn completed(
  backend: sinal.Backend,
  duration: Int,
  run_label: String,
) -> Result(Nil, sinal.EmitError) {
  sinal.emit(backend, event(), duration, run_label)
}
