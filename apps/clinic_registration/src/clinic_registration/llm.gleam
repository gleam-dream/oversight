//// The registration model: one llm_wire call with structured output,
//// reading its context through `decisions` sources so that every read is
//// on the record.
////
//// - `reader` turns the context into a `domain.Context`. The model and the
////   card both use it, so a card shows the value the model had.
//// - `live` sends the request, stores the request and the answer as one
////   evidence document (an exchange) before using the answer, and names it
////   in the recommendation's explanation.
//// - `replaying` sends nothing. It asks its sources for the exchange under
////   the request's key, so it answers only a request the record holds.
//// - `prepared` builds the request a configuration sends for a context,
////   without I/O. Its exact JSON body is the exchange's key.

import clinic_registration/domain.{
  type Context, type Extraction, type Registration, Context,
}
import clinic_registration/store
import decisions/learning.{type Read, Read}
import decisions/model.{type Failure, type Model, type Sources}
import decisions/vocabulary.{
  type Explanation, type Manifest, type Ref, Manifest, ModelCall, Receipt,
  Recommendation, Ref,
}
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/openai
import pog

/// The read a replay answers the provider call from.
pub const call_read = "llm_wire.call"

/// The read that finds patients with the contact's phone or profile name.
pub const similar_read = "patients.similar"

/// The read that lists the insurers the clinic accepts.
pub const insurers_read = "insurers.accepted"

/// The context renderer this model's manifests name.
pub const renderer = "registration-context-1"

/// One model configuration: what is sent, and how the answer becomes a
/// registration. The recommender is `ModelCall(name, version)`.
pub type Configuration {
  Configuration(
    name: String,
    version: String,
    model: String,
    instructions: String,
    /// From the typed context and the provider's answer to the record.
    interpret: fn(Context, Extraction) -> Registration,
  )
}

const instructions_v1 =
  "You register patients for Clínica X. Read the conversation and answer with the patient's full name, birth date (YYYY-MM-DD), phone, insurer and plan, and whether they agreed to be registered. Use null for anything the conversation does not say, list those fields in `missing`, and give your confidence from 0 to 1."

/// The configuration in production.
pub fn first() -> Configuration {
  Configuration(
    name: "registration-extractor",
    version: "1",
    model: "gpt-5-mini",
    instructions: instructions_v1,
    interpret: fn(context: Context, extraction: Extraction) {
      domain.registration_of(extraction, context.conversation.contact)
    },
  )
}

/// A candidate with another prompt: it sends different bytes, so the
/// record holds no answer for it.
pub fn second_prompt() -> Configuration {
  Configuration(
    ..first(),
    version: "2",
    instructions: instructions_v1
      <> " Write names as the patient wrote them, with every surname.",
  )
}

/// A candidate that sends the same request as `first` and reads the answer
/// differently: below 0.9 confidence it leaves the birth date for
/// reception to fill in. The record holds its answer.
pub fn same_request_other_reading() -> Configuration {
  Configuration(
    ..first(),
    version: "1b",
    interpret: fn(context: Context, extraction: Extraction) {
      let registration =
        domain.registration_of(extraction, context.conversation.contact)
      case extraction.confidence <. 0.9 {
        True -> domain.Registration(..registration, birth_date: None)
        False -> registration
      }
    },
  )
}

/// The provider endpoint and the deadline every call is held to.
pub type Provider {
  Provider(config: llm_wire.Config, deadline: Duration)
}

/// The OpenAI Responses wire at `base_url`, the root of the provider
/// server. Production keeps the built-in endpoint and reads the key from
/// its secret store.
pub fn provider(base_url: String, deadline: Duration) -> Provider {
  Provider(
    config: openai.new("sk-scripted")
      |> openai.config
      |> llm_wire.with_endpoint(base_url <> "/openai/v1")
      |> llm_wire.with_call_timeout(llm_wire.After(deadline)),
    deadline:,
  )
}

// -- The context ---------------------------------------------------------------

/// The manifest of a registration: the conversation up to the message
/// that triggered it.
pub fn manifest(message: domain.Inbound) -> Manifest {
  Manifest(
    refs: [Ref(kind: "conversation", id: message.contact, revision: message.id)],
    renderer:,
  )
}

/// The one function that reads a registration's context. It resolves the
/// conversation, then reads the patients similar to the contact and the
/// accepted insurers.
pub fn reader() -> model.Reader(Context) {
  fn(manifest: Manifest, sources: Sources) {
    use ref <- result.try(
      list.find(manifest.refs, fn(ref) { ref.kind == "conversation" })
      |> result.replace_error(model.Declined(
        "the context names no conversation",
      )),
    )
    use text <- result.try(sources.resolve(ref))
    use conversation <- result.try(decoded(
      domain.conversation_codec(),
      text,
      ref.kind,
      ref.id,
    ))
    let argument = conversation.contact <> "|" <> conversation.profile_name
    use similar <- result.try(sources.read(similar_read, argument))
    use similar <- result.try(decoded(
      codec.list(domain.patient_codec()),
      similar.body,
      similar_read,
      argument,
    ))
    use insurers <- result.try(sources.read(insurers_read, domain.clinic))
    use insurers <- result.try(decoded(
      codec.list(codec.string()),
      insurers.body,
      insurers_read,
      domain.clinic,
    ))
    Ok(Context(conversation:, similar:, insurers:))
  }
}

fn decoded(
  with: codec.Codec(a),
  text: String,
  read: String,
  argument: String,
) -> Result(a, Failure) {
  codec.decode_json(with, text)
  |> result.map_error(fn(problem) {
    model.ReadFailed(
      read:,
      argument:,
      reason: codec.describe_decode_error(problem),
    )
  })
}

/// The sources the model reads in production: the conversation from the
/// messages, and every read captured as evidence before the model sees it.
pub fn sources(db: pog.Connection) -> Sources {
  model.Sources(resolve: store.resolver(db), read: fn(name, argument) {
    case fetch(db, name, argument) {
      Error(reason) -> Error(model.ReadFailed(read: name, argument:, reason:))
      Ok(fetch) ->
        model.capture(
          store.evidence(),
          db,
          source: name,
          request: argument,
          fetch:,
        )
        |> result.map_error(model.ReadFailed(read: name, argument:, reason: _))
    }
  })
}

/// The fetch behind a named read, or why there is none.
fn fetch(
  db: pog.Connection,
  name: String,
  argument: String,
) -> Result(fn() -> Result(String, String), String) {
  case name {
    "patients.similar" ->
      case string.split_once(argument, "|") {
        Ok(#(phone, profile)) ->
          Ok(fn() {
            store.similar(db, phone:, name: profile)
            |> result.map(store.patients_json)
            |> result.map_error(store.describe)
          })
        Error(Nil) -> Error("the argument is not phone|name")
      }
    "insurers.accepted" ->
      Ok(fn() {
        store.insurers(db)
        |> result.map(store.insurers_json)
        |> result.map_error(store.describe)
      })
    _ -> Error("no read is named " <> name)
  }
}

/// The revision a reference would have if it were read now. A card marks a
/// read whose revision changed since the model received it, and an export
/// flags it as drift. A conversation and an exchange never change.
pub fn latest(db: pog.Connection) -> fn(Ref) -> String {
  fn(ref: Ref) {
    case fetch(db, ref.kind, ref.id) {
      Ok(fetch) ->
        case fetch() {
          Ok(body) -> model.digest(body)
          Error(_) -> ref.revision
        }
      Error(_) -> ref.revision
    }
  }
}

// -- The request -----------------------------------------------------------------

/// The request a configuration sends for a context. The contact marker lets
/// the scripted provider pick its answer; a real provider ignores it.
pub fn prompt(
  configuration: Configuration,
  context: Context,
) -> llm_wire.Request(String) {
  let conversation = context.conversation
  let lines =
    list.map(conversation.lines, fn(line) { "- " <> line.text })
    |> string.join("\n")
  llm_wire.request(configuration.model, [
    llm_wire.system(configuration.instructions),
    llm_wire.user(
      "[[contact:"
      <> conversation.contact
      <> "]]\nProfile name: "
      <> conversation.profile_name
      <> "\nConversation:\n"
      <> lines
      <> "\nInsurers the clinic accepts: "
      <> string.join(context.insurers, ", "),
    ),
  ])
  |> llm_wire.with_max_tokens(1024)
  |> llm_wire.with_temperature(0.0)
}

/// The request admitted and encoded for the provider. No I/O.
pub fn prepared(
  configuration: Configuration,
  provider: Provider,
  context: Context,
) -> Result(llm_wire.Prepared(Extraction), Failure) {
  prompt(configuration, context)
  |> llm_wire.with_output("registration", domain.extraction_codec())
  |> llm_wire.prepare(provider.config, _)
  |> result.map_error(fn(problem) {
    model.Declined(
      "the request was refused: " <> error.describe_prepare_error(problem),
    )
  })
}

/// The exchange's key: the SHA-256 of the exact body sent. One changed
/// byte is another call.
pub fn call_key(prepared: llm_wire.Prepared(a)) -> String {
  crypto.hash(crypto.Sha256, <<llm_wire.request_json(prepared):utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

// -- The models ------------------------------------------------------------------

/// How an exchange becomes evidence: given the call's key and its document.
pub type Capture =
  fn(String, String) -> Result(model.Captured, String)

/// Store an exchange in the clinic's evidence table, on `db`.
pub fn capture(db: pog.Connection) -> Capture {
  fn(key, document) {
    model.capture(
      store.evidence(),
      db,
      source: call_read,
      request: key,
      fetch: fn() { Ok(document) },
    )
  }
}

/// The configuration as a model that calls its provider through `client`.
/// A call that produced a response is stored before the answer is used,
/// whatever the answer was; a call that failed in transport stores nothing.
pub fn live(
  configuration: Configuration,
  provider: Provider,
  client: http_gun.Client,
  capture: Capture,
) -> Model(Registration) {
  build(configuration, provider, fn(key, prepared, _sources) {
    case exchange_with(client, prepared) {
      Ok(document) ->
        capture(key, document)
        |> result.map_error(model.ReadFailed(
          read: call_read,
          argument: key,
          reason: _,
        ))
      Error(failure) -> Error(transport_failure(failure, provider))
    }
  })
}

/// The configuration as a model with no transport: the exchange is
/// whatever its sources hold under the request's key. A request the record
/// never saw is `NotRecorded`.
pub fn replaying(
  configuration: Configuration,
  provider: Provider,
) -> Model(Registration) {
  build(configuration, provider, fn(key, _prepared, sources: Sources) {
    sources.read(call_read, key)
  })
}

fn build(
  configuration: Configuration,
  provider: Provider,
  ask: fn(String, llm_wire.Prepared(Extraction), Sources) ->
    Result(model.Captured, Failure),
) -> Model(Registration) {
  model.new(fn(manifest, sources) {
    use context <- result.try(reader()(manifest, sources))
    use prepared <- result.try(prepared(configuration, provider, context))
    use captured <- result.try(ask(call_key(prepared), prepared, sources))
    // A failure after the exchange was captured points at it, so the
    // recorded attempt shows what the provider answered.
    let with_exchange = model.with_evidence(_, [captured.ref])
    use exchange <- result.try(
      parse(captured.body) |> result.map_error(with_exchange),
    )
    use extraction <- result.try(
      answer_of(exchange) |> result.map_error(with_exchange),
    )
    Ok(
      Recommendation(
        output: configuration.interpret(context, extraction),
        by: ModelCall(
          configuration: configuration.name,
          version: configuration.version,
        ),
        explanation: Receipt(evidence: captured.ref),
        signals: domain.signals(context, extraction),
        reads: [],
      ),
    )
  })
}

fn transport_failure(failure: llm_wire.Failure, provider: Provider) -> Failure {
  case failure.error {
    error.DeadlineExceeded(_) -> model.Deadline(after: provider.deadline)
    _ ->
      model.ProviderFailed(
        provider: string.inspect(failure.provider),
        reason: llm_wire.describe_failure(failure),
      )
  }
}

// -- The exchange as evidence ----------------------------------------------------

/// How a call that produced a response ended.
pub type Ending {
  Answered
  /// The provider's text is not the structured answer.
  Undecodable
  Refused
  OutputLimited
  NeedsTools
}

/// One request and what came back, as stored.
pub type Exchange {
  Exchange(
    /// The exact JSON body sent.
    request: String,
    ending: Ending,
    /// The provider's text, whatever became of it.
    text: String,
    /// Why, for an ending that is not `Answered`.
    detail: String,
    tokens: Option(#(Int, Int)),
  )
}

fn exchange_with(
  client: http_gun.Client,
  prepared: llm_wire.Prepared(Extraction),
) -> Result(String, llm_wire.Failure) {
  let request = llm_wire.request_json(prepared)
  let document = fn(ending, text, detail, usage: Option(message.Usage)) {
    Exchange(
      request:,
      ending:,
      text:,
      detail:,
      tokens: option.map(usage, fn(usage) {
        #(usage.input_tokens, usage.output_tokens)
      }),
    )
    |> to_json
    |> json.to_string
    |> Ok
  }
  case llm_wire.run(client, prepared) {
    Ok(llm_wire.Answer(text:, usage:, ..)) ->
      document(Answered, text, "", usage)
    Ok(llm_wire.Refused(reason:, usage:)) ->
      document(Refused, "", reason, usage)
    Ok(llm_wire.OutputLimited(partial_text:, usage:, ..)) ->
      document(OutputLimited, partial_text, "", usage)
    Ok(llm_wire.NeedsTools(usage:, ..)) -> document(NeedsTools, "", "", usage)
    Error(llm_wire.Failure(
      error: error.InvalidOutput(raw_output:, failure:),
      usage:,
      ..,
    )) ->
      document(
        Undecodable,
        raw_output,
        error.describe_value_failure(failure),
        usage,
      )
    Error(failure) -> Error(failure)
  }
}

fn answer_of(exchange: Exchange) -> Result(Extraction, Failure) {
  case exchange.ending {
    Answered ->
      codec.decode_json(domain.extraction_codec(), exchange.text)
      |> result.map_error(fn(problem) {
        model.Undecodable(codec.describe_decode_error(problem))
      })
    Undecodable -> Error(model.Undecodable(exchange.detail))
    Refused -> Error(model.Declined(exchange.detail))
    OutputLimited ->
      Error(model.Undecodable("the answer was cut at the output limit"))
    NeedsTools ->
      Error(model.Undecodable("the model asked for tools; this call has none"))
  }
}

fn ending_name(ending: Ending) -> String {
  case ending {
    Answered -> "answered"
    Undecodable -> "undecodable"
    Refused -> "refused"
    OutputLimited -> "output_limited"
    NeedsTools -> "needs_tools"
  }
}

/// The exchange as the evidence document stores it.
pub fn to_json(exchange: Exchange) -> json.Json {
  json.object([
    #("format", json.string("llm-exchange.v1")),
    #("request", json.string(exchange.request)),
    #("ending", json.string(ending_name(exchange.ending))),
    #("text", json.string(exchange.text)),
    #("detail", json.string(exchange.detail)),
    #("tokens", case exchange.tokens {
      Some(#(input, output)) ->
        json.object([#("input", json.int(input)), #("output", json.int(output))])
      None -> json.null()
    }),
  ])
}

fn parse(document: String) -> Result(Exchange, Failure) {
  json.parse(document, {
    use request <- decode.field("request", decode.string)
    use ending <- decode.field("ending", decode.string)
    use text <- decode.field("text", decode.string)
    use detail <- decode.field("detail", decode.string)
    use tokens <- decode.field(
      "tokens",
      decode.optional({
        use input <- decode.field("input", decode.int)
        use output <- decode.field("output", decode.int)
        decode.success(#(input, output))
      }),
    )
    let ending = case ending {
      "answered" -> Ok(Answered)
      "undecodable" -> Ok(Undecodable)
      "refused" -> Ok(Refused)
      "output_limited" -> Ok(OutputLimited)
      "needs_tools" -> Ok(NeedsTools)
      _ -> Error(Nil)
    }
    case ending {
      Ok(ending) ->
        decode.success(Exchange(request:, ending:, text:, detail:, tokens:))
      Error(Nil) ->
        decode.failure(
          Exchange(request:, ending: Answered, text:, detail:, tokens:),
          "an ending",
        )
    }
  })
  |> result.replace_error(model.Undecodable(
    "the evidence is not an llm exchange",
  ))
}

/// The exact request and answer behind a recommendation, for a card.
pub fn exchange(
  explanation: Explanation,
  content content: model.Resolver,
) -> Result(Exchange, Failure) {
  case explanation {
    Receipt(evidence:) if evidence.kind == call_read ->
      content(evidence) |> result.try(parse)
    _ -> Error(model.Declined("the explanation is not an llm exchange"))
  }
}

/// For `learning.Archive.reads`: the exchange a receipt names, as a read a
/// replaying candidate can make.
pub fn receipt(explanation: Explanation) -> List(Read) {
  case explanation {
    Receipt(evidence:) if evidence.kind == call_read -> [
      Read(name: call_read, argument: evidence.id, result: evidence),
    ]
    _ -> []
  }
}
