//// Structured invoice extraction through llm_wire.
////
//// The provider-specific code is the `settings` case below: one options
//// builder, one config constructor and one endpoint each. Everything after
//// `settings` is shared by the three providers.

import extractor/invoice.{type Invoice}
import gleam/result
import http_gun
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/anthropic
import llm_wire/provider/google
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

pub type Provider {
  OpenAi
  Anthropic
  Google
}

pub fn provider_name(provider: Provider) -> String {
  case provider {
    OpenAi -> "openai"
    Anthropic -> "anthropic"
    Google -> "google"
  }
}

pub fn provider_codec() -> codec.Codec(Provider) {
  codec.string_enum([
    #("openai", OpenAi),
    #("anthropic", Anthropic),
    #("google", Google),
  ])
}

/// A prepared provider choice: settings plus the model to ask.
pub type Model {
  Model(provider: Provider, settings: config.Config, model: types.ModelId)
}

/// Builds the settings for one provider behind `base_url`, the root of a
/// scripted loopback server. Production would keep the built-in endpoints and
/// read the key from the environment.
pub fn model(
  provider: Provider,
  base_url: String,
  api_key: String,
) -> Result(Model, types.WireError) {
  use key <- result.try(types.api_key(api_key))
  let #(settings, path, model_name) = case provider {
    OpenAi -> #(config.openai(openai.options(key)), "/openai/v1", "gpt-5-mini")
    Anthropic -> #(
      config.anthropic(
        anthropic.options(key) |> anthropic.with_version("2023-06-01"),
      ),
      "/anthropic/v1",
      "claude-sonnet-4-5",
    )
    Google -> #(
      config.google(google.options(key)),
      "/google/v1beta",
      "gemini-2.5-flash",
    )
  }
  use endpoint <- result.try(types.endpoint(base_url <> path))
  use model <- result.try(types.model_id(model_name))
  let deadlines =
    types.Deadlines(
      overall_timeout_ms: 10_000,
      idle_timeout_ms: 5000,
      read_timeout_ms: 1000,
    )
  Ok(Model(
    provider:,
    settings: settings
      |> config.with_endpoint(endpoint)
      |> config.with_deadlines(deadlines),
    model:,
  ))
}

pub type ExtractError {
  /// Preparation failed before any I/O: schema projection, limits, config.
  NotPrepared(types.WireError)
  /// The provider call failed. `provider` is carried because retry
  /// assessment needs it and `RunFailure` does not include it.
  CallFailed(
    provider: types.Provider,
    error: types.WireError,
    evidence: types.RetryEvidence,
  )
  Refused(reason: String)
  Truncated
  UnexpectedToolCall
}

const instructions = "Extract the invoice in the document. Answer only with the JSON object described by the schema. Amounts are integer cents."

pub fn request(
  model: Model,
  document_id: String,
  text: String,
) -> types.Request {
  types.new_request(model.model, [
    types.SystemMessage(instructions),
    types.UserMessage("[[doc:" <> document_id <> "]]\n" <> text),
  ])
  |> types.with_max_tokens(2048)
  |> types.with_temperature(0.0)
}

pub fn prepare(
  model: Model,
  document_id: String,
  text: String,
) -> Result(session.PreparedStructuredCall(Invoice), types.WireError) {
  session.prepare_structured(
    model.settings,
    request(model, document_id, text),
    "invoice",
    invoice.codec(),
  )
}

pub fn extract(
  client: http_gun.Client,
  model: Model,
  document_id: String,
  text: String,
) -> Result(Invoice, ExtractError) {
  use prepared <- result.try(
    prepare(model, document_id, text) |> result.map_error(NotPrepared),
  )
  case session.run_structured(client, prepared) {
    Ok(session.StructuredValue(value:, ..)) -> Ok(value)
    Ok(session.StructuredRefusal(reason:, ..)) -> Error(Refused(reason))
    Ok(session.StructuredOutputLimited(..)) -> Error(Truncated)
    Ok(session.StructuredNeedsTools(..)) -> Error(UnexpectedToolCall)
    Error(session.RunFailure(error:, retry:)) ->
      Error(CallFailed(
        provider: provider.identity(config.adapter(model.settings)),
        error:,
        evidence: retry,
      ))
  }
}
