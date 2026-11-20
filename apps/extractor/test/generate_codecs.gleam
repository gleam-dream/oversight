//// The development-time generation task. From this directory:
////
//// ```sh
//// gleam run -m generate_codecs
//// gleam format src/extractor/generated
//// ```
////
//// `generated_codec_test` fails when the committed module drifts from the
//// definition.

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
      case write_file("src/" <> path, without_unreachable_enum_arms(content)) {
        Ok(Nil) -> io.println("Generated src/" <> path)
        Error(reason) -> panic as { "write failed: " <> reason }
      }
  }
}

/// json_blueprint 2.1.1 ends each generated enum encoder with a catch-all arm
/// that an exhaustive enum makes unreachable, and this repository compiles
/// with warnings as errors. The arm is dropped until the generator stops
/// emitting it. A definition that leaves out a constructor then fails to
/// compile as an inexhaustive match instead of passing unnoticed.
fn without_unreachable_enum_arms(content: String) -> String {
  string.replace(content, "\n    _ -> generated.unknown_enum_value()", "")
}
