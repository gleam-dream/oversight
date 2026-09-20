import lab/blueprint
import lab/sinal
import lab/sinal_fields

pub fn invalid() {
  sinal.event(
    ["bad"],
    blueprint.int(),
    sinal_fields.field("name", blueprint.text()),
  )
}
