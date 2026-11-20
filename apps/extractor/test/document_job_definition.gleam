//// The typed definition the job payload codec is generated from. It names
//// the native type, constructors and mapping functions the generated module
//// calls, so it lives beside the generation task rather than in production
//// code.

import extractor/document_job.{type DocumentJob}
import extractor/llm
import json/blueprint/codegen

pub fn definition() -> codegen.Definition(DocumentJob) {
  let assert Ok(openai) =
    codegen.enum_variant("openai", llm.OpenAi, "extractor/llm.OpenAi")
  let assert Ok(anthropic) =
    codegen.enum_variant("anthropic", llm.Anthropic, "extractor/llm.Anthropic")
  let assert Ok(google) =
    codegen.enum_variant("google", llm.Google, "extractor/llm.Google")
  let assert Ok(provider) =
    codegen.string_enum("llm.Provider", [openai, anthropic, google])
  let properties =
    codegen.combine(
      codegen.required("document_id", codegen.string()),
      codegen.required("url", codegen.string()),
    )
    |> codegen.combine(codegen.required("provider", provider))
  let assert Ok(mapping) =
    codegen.named_mapping(
      document_job.from_fields,
      "extractor/document_job.from_fields",
      document_job.to_fields,
      "extractor/document_job.to_fields",
    )
  let assert Ok(definition) =
    codegen.imap(
      codegen.object(properties),
      "document_job.DocumentJob",
      mapping,
    )
  definition
}
