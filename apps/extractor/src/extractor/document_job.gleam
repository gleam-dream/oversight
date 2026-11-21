//// The Grind job payload: which document to fetch and which provider
//// extracts it. Its shape is fixed at build time and its codec is held by
//// the worker that Grind copies into every job's process, so the codec is
//// generated (`extractor/generated/document_job_codec`)
//// rather than built from combinators. `test/document_job_definition.gleam`
//// holds the typed definition; regenerate with
//// `gleam run -m generate_codecs && gleam format src/extractor/generated`.
//// See the codec practice guide:
//// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md#choose-generated-codecs-or-combinators

import extractor/llm

pub type DocumentJob {
  DocumentJob(document_id: String, url: String, provider: llm.Provider)
}

/// The generated codec's decoding mapping from the object's properties.
pub fn from_fields(fields: #(#(String, String), llm.Provider)) -> DocumentJob {
  let #(#(document_id, url), provider) = fields
  DocumentJob(document_id:, url:, provider:)
}

/// The generated codec's encoding mapping to the object's properties.
pub fn to_fields(job: DocumentJob) -> #(#(String, String), llm.Provider) {
  #(#(job.document_id, job.url), job.provider)
}
