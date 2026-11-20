//// The development-time generation task. From this directory:
////
//// ```sh
//// gleam run -m generate_codecs
//// gleam format src/extractor/generated
//// ```
////
//// The module is written exactly as the generator returns it, then
//// formatted. `generated_codec_test` compares its fingerprint with a fresh
//// compilation of the definition.

import document_job_definition
import gleam/io
import gleam/string
import json/blueprint/codegen

@external(erlang, "generate_codecs_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

pub const module_path = "extractor/generated/document_job_codec"

pub const name = "document_job"

pub fn main() -> Nil {
  case
    codegen.compile(module_path, name, document_job_definition.definition())
  {
    Error(error) -> panic as { "generation failed: " <> string.inspect(error) }
    Ok(codegen.GeneratedModule(path:, content:, fingerprint: _)) ->
      case write_file("src/" <> path, content) {
        Ok(Nil) -> io.println("Generated src/" <> path)
        Error(reason) -> panic as { "write failed: " <> reason }
      }
  }
}
