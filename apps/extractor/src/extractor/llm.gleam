//// Structured invoice extraction through llm_wire.
////
//// The provider-specific code is the `config` case below: one options
//// builder, one config constructor and one path each. Everything after
//// it is shared by the three providers.

import extractor/invoice.{type Invoice}
import gleam/result
import gleam/time/duration
import http_gun
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/openai

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

/// A provider choice: its configuration plus the model to ask.
pub type Model {
  Model(provider: Provider, settings: llm_wire.Config, model: String)
}

/// Builds the configuration for one provider behind `base_url`, the root of
/// a scripted loopback server. Production would keep the built-in endpoints
/// and read the key from the environment. Nothing is checked until
/// `prepare`.
pub fn model(provider: Provider, base_url: String, api_key: String) -> Model {
  let #(settings, path, model_name) = case provider {
    OpenAi -> #(
      openai.new(api_key) |> openai.config,
      "/openai/v1",
      "gpt-5-mini",
    )
    Anthropic -> #(
      anthropic.new(api_key)
        |> anthropic.with_version("2023-06-01")
        |> anthropic.config,
      "/anthropic/v1",
      "claude-sonnet-4-5",
    )
    Google -> #(
      google.new(api_key) |> google.config,
      "/google/v1beta",
      "gemini-2.5-flash",
    )
  }
  Model(
    provider:,
    settings: settings
      |> llm_wire.with_endpoint(base_url <> path)
      |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(10)))
      |> llm_wire.with_first_token_timeout(llm_wire.After(duration.seconds(5)))
      |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(5))),
    model: model_name,
  )
}

pub type ExtractError {
  /// Preparation failed before any I/O: schema projection, limits, config.
  NotPrepared(error.PrepareError)
  /// The provider call failed. The `Failure` carries the provider, whether
  /// the request was sent, and the typed error.
  CallFailed(llm_wire.Failure)
  Refused(reason: String)
  Truncated
  UnexpectedToolCall
}

const instructions = "Extract the invoice in the document. Answer only with the JSON object described by the schema. Amounts are integer cents."

pub fn request(
  model: Model,
  document_id: String,
  text: String,
) -> llm_wire.Request(String) {
  llm_wire.request(model.model, [
    llm_wire.system(instructions),
    llm_wire.user("[[doc:" <> document_id <> "]]\n" <> text),
  ])
  |> llm_wire.with_max_tokens(2048)
  |> llm_wire.with_temperature(0.0)
}

pub fn prepare(
  model: Model,
  document_id: String,
  text: String,
) -> Result(llm_wire.Prepared(Invoice), error.PrepareError) {
  llm_wire.prepare(
    model.settings,
    request(model, document_id, text)
      |> llm_wire.with_output("invoice", invoice.codec()),
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
  case llm_wire.run(client, prepared) {
    Ok(llm_wire.Answer(output:, ..)) -> Ok(output)
    Ok(llm_wire.Refused(reason:, ..)) -> Error(Refused(reason))
    Ok(llm_wire.OutputLimited(..)) -> Error(Truncated)
    Ok(llm_wire.NeedsTools(..)) -> Error(UnexpectedToolCall)
    Error(failure) -> Error(CallFailed(failure))
  }
}
