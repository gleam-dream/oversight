//// The committed job payload codec must match its typed definition, and the
//// generated functions must agree with the definition's runtime codec.

import document_job_definition
import extractor/document_job.{DocumentJob}
import extractor/generated/document_job_codec
import extractor/llm
import generate_codecs
import gleam/list
import json/blueprint/codec
import json/blueprint/codegen

/// Regenerate with `gleam run -m generate_codecs` and format the output when
/// this fails: the definition changed and the committed module did not.
pub fn committed_job_codec_matches_its_definition_test() {
  let assert Ok(codegen.GeneratedModule(path:, content: _, fingerprint:)) =
    codegen.compile(
      generate_codecs.module_path,
      generate_codecs.name,
      document_job_definition.definition(),
    )
  assert path == "extractor/generated/document_job_codec.gleam"
  assert fingerprint == document_job_codec.generated_fingerprint
}

pub fn generated_job_codec_agrees_with_the_runtime_codec_test() {
  let generated = document_job_codec.document_job_codec()
  let runtime = codegen.runtime(document_job_definition.definition())
  list.each([llm.OpenAi, llm.Anthropic, llm.Google], fn(provider) {
    let job = DocumentJob("acme", "http://docs.test/acme", provider)
    let assert Ok(text) = codec.encode_json(generated, job)
    assert codec.encode_json(runtime, job) == Ok(text)
    assert codec.decode_json(generated, text) == Ok(job)
    assert codec.decode_json(runtime, text) == Ok(job)
  })
  assert codec.schema(generated) == codec.schema(runtime)
}

pub fn generated_job_codec_refuses_an_unknown_provider_test() {
  let text =
    "{\"document_id\":\"acme\",\"url\":\"http://docs.test/acme\",\"provider\":\"other\"}"
  let generated = document_job_codec.document_job_codec()
  let runtime = codegen.runtime(document_job_definition.definition())
  let assert Error(refused) = codec.decode_json(generated, text)
  assert codec.decode_json(runtime, text) == Error(refused)
}
