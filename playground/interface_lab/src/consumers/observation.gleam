// THROWAWAY: Can an event constrain both measurements and metadata?
import lab/blueprint
import lab/sinal

pub fn event() -> sinal.Event(Int, String) {
  sinal.event(["application", "completed"], blueprint.int(), blueprint.text())
}

pub fn completed(
  duration: Int,
  run_label: String,
) -> Result(Nil, sinal.EmitError) {
  sinal.emit(event(), duration, run_label)
}
