import site/rng

pub fn the_generator_matches_the_reference_sequence_test() {
  // Drawn from the reference's mulberry32 with the seeds the modules use.
  assert rng.take(rng.seed(3), 5).0
    == [
      0.7202267837710679, 0.03866216051392257, 0.4561921926215291,
      0.07492800964973867, 0.7630053898319602,
    ]
  assert rng.take(rng.seed(7), 3).0
    == [0.011704753153026104, 0.06195825757458806, 0.97690763277933]
  assert rng.take(rng.seed(11), 2).0 == [0.5115870486479253, 0.5299464082345366]
  assert rng.take(rng.seed(21), 2).0 == [0.4322912215720862, 0.4470290595199913]
}
