import lab/saga

pub fn invalid(definition: saga.Definition(Int, String, Nil, Nil)) {
  saga.start_local(definition, "wrong input")
}
