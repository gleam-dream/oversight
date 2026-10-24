// THROWAWAY: Codec revisions stay attached to their independently evolving wire.
import lab/blueprint
import lab/saga

pub fn contract() -> saga.ActivityContract(String, Int, String, String) {
  saga.ActivityContract(
    input: saga.VersionedCodec(version(2), blueprint.text()),
    output: saga.VersionedCodec(version(3), blueprint.int()),
    error: saga.VersionedCodec(version(4), blueprint.text()),
    undo_error: saga.VersionedCodec(version(5), blueprint.text()),
  )
}

pub fn probe() -> Nil {
  let assert Ok(step_id) = saga.step_id("measure")
  let assert Ok(definition_id) = saga.definition_id("measure")
  let operation =
    saga.activity(
      step_id,
      version(6),
      contract(),
      fn(_: String) { Ok(42) },
      saga.Uncompensated,
    )
  let definition =
    saga.define(definition_id, version(1), "measure:v1", operation)
  let assert [step] = saga.steps(definition)
  let assert [2, 3, 4, 5] = saga.codec_version_numbers(step)
  let assert 6 = saga.step_version_number(step)
  Nil
}

fn version(number: Int) -> saga.Version {
  let assert Ok(version) = saga.version(number)
  version
}
