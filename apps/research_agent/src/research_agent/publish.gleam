//// Publishing as a durable Saga: create a draft, upload its body, publish
//// it. A failure after the draft exists rolls back by deleting the draft.
//// Every step is `recoverable`, so a restarted job reuses saved outputs and
//// asks the publisher what happened to an interrupted step instead of
//// repeating it. Checkpoints go to Postgres through `saga_store`.

import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import http_gun
import research_agent/domain.{type Article, type Published, Published}
import research_agent/remote
import research_agent/saga_store.{type SagaStore}
import saga
import saga/codec
import saga/durable
import saga/execution

pub type PublishError {
  PublishError(step: String, detail: String)
}

pub type Outcome =
  execution.Outcome(Published, PublishError, String)

/// The execution id of a research request's publication.
pub fn execution_id(research_id: String) -> String {
  "publish-" <> research_id
}

pub fn workflow(
  client: http_gun.Client,
  base: String,
) -> saga.Workflow(Article, Published, PublishError, String) {
  let text = codec.text()
  let delete = fn(draft_id: String) {
    remote.call(client, http.Delete, base <> "/drafts/" <> draft_id, [], "")
    |> remote.expect([204, 404])
    |> result.replace(Nil)
    |> result.map_error(remote.describe)
  }
  let create_draft =
    saga.effect("create_draft", fn(article: Article, key) {
      remote.call(
        client,
        http.Post,
        base <> "/drafts",
        [#("idempotency-key", key)],
        json.to_string(json.object([#("title", json.string(article.title))])),
      )
      |> remote.expect([201])
      |> result.try(fn(body) {
        json.parse(body, decode.at(["id"], decode.string))
        |> result.replace_error(remote.Status(201, body))
      })
      |> result.map_error(failed("create_draft"))
    })
    |> saga.undo(fn(_article, draft_id) { delete(draft_id) })
    |> saga.restore_undo(fn(_article, draft_id, _key) {
      saga.UndoWith(fn() { delete(draft_id) })
    })
    |> saga.recoverable("1", article_codec(), text, fn(_article, key) {
      // The publisher deduplicates on the idempotency key, so it can say
      // whether an interrupted create happened.
      case
        remote.call(client, http.Get, base <> "/drafts?key=" <> key, [], "")
      {
        Ok(#(200, body)) ->
          case json.parse(body, decode.at(["id"], decode.string)) {
            Ok(id) -> saga.EffectCompleted(id)
            Error(_) -> saga.EffectUnknown
          }
        Ok(#(404, _)) -> saga.EffectAbsent
        _ -> saga.EffectUnknown
      }
    })
  let upload =
    saga.step("upload_body", fn(pair: #(Article, String)) {
      let #(article, draft_id) = pair
      remote.call(
        client,
        http.Put,
        base <> "/drafts/" <> draft_id <> "/body",
        [],
        json.to_string(json.object([#("body", json.string(article.body))])),
      )
      |> remote.expect([204])
      |> result.replace(draft_id)
      |> result.map_error(failed("upload_body"))
    })
    // A PUT of the same body is idempotent: an interrupted upload may run again.
    |> saga.recoverable("1", pair_codec(), text, fn(_, _) { saga.EffectAbsent })
  let publish =
    saga.step("publish", fn(draft_id: String) {
      remote.call(
        client,
        http.Post,
        base <> "/drafts/" <> draft_id <> "/publish",
        [],
        "",
      )
      |> remote.expect([200])
      |> result.try(fn(body) {
        json.parse(body, decode.at(["url"], decode.string))
        |> result.replace_error(remote.Status(200, body))
      })
      |> result.map(Published(draft_id, _))
      |> result.map_error(failed("publish"))
    })
    |> saga.recoverable("1", text, published_codec(), fn(_, _) {
      saga.EffectAbsent
    })
  let assert Ok(workflow) =
    saga.define("publish_article", fn(article) {
      let draft = article |> saga.perform(create_draft)
      saga.both(article, draft)
      |> saga.perform(upload)
      |> saga.perform(publish)
    })
  workflow
}

fn failed(step: String) -> fn(remote.Failure) -> PublishError {
  fn(failure) { PublishError(step, remote.describe(failure)) }
}

/// Starts the publication of `article`, or reconnects to the one already
/// stored for its research id, and drives it to an outcome.
pub fn run(
  store: SagaStore,
  client: http_gun.Client,
  base: String,
  article: Article,
) -> Result(Outcome, durable.Error) {
  let workflow = workflow(client, base)
  use persistence <- result.try(durable.prepare(
    workflow,
    "1",
    article_codec(),
    published_codec(),
    error_codec(),
    codec.text(),
  ))
  let id = execution_id(article.research_id)
  let storage = saga_store.storage(store, id)
  use reference <- result.try(durable.start_or_reconnect(
    storage,
    id,
    persistence,
    article,
  ))
  durable.drive(
    storage,
    reference,
    persistence,
    execution.Config(..execution.config(), step_timeout: Some(5000)),
  )
}

// Saga codecs: versioned String codecs, written over gleam_json. ---------

fn json_codec(
  version: String,
  to_json: fn(a) -> json.Json,
  decoder: decode.Decoder(a),
) -> codec.Codec(a) {
  codec.new(version, fn(value) { Ok(json.to_string(to_json(value))) }, fn(text) {
    json.parse(text, decoder) |> result.map_error(string.inspect)
  })
}

pub fn article_codec() -> codec.Codec(Article) {
  json_codec("article-1", domain.article_json, domain.article_decoder())
}

fn pair_codec() -> codec.Codec(#(Article, String)) {
  json_codec(
    "article-draft-1",
    fn(pair: #(Article, String)) {
      json.object([
        #("article", domain.article_json(pair.0)),
        #("draft_id", json.string(pair.1)),
      ])
    },
    {
      use article <- decode.field("article", domain.article_decoder())
      use draft_id <- decode.field("draft_id", decode.string)
      decode.success(#(article, draft_id))
    },
  )
}

pub fn published_codec() -> codec.Codec(Published) {
  json_codec("published-1", domain.published_json, domain.published_decoder())
}

fn error_codec() -> codec.Codec(PublishError) {
  json_codec(
    "publish-error-1",
    fn(e: PublishError) {
      json.object([
        #("step", json.string(e.step)),
        #("detail", json.string(e.detail)),
      ])
    },
    {
      use step <- decode.field("step", decode.string)
      use detail <- decode.field("detail", decode.string)
      decode.success(PublishError(step, detail))
    },
  )
}

/// A one-line account of an outcome, for logs and job results.
pub fn describe(outcome: Outcome) -> String {
  case outcome {
    execution.Completed(published) -> "published " <> published.url
    execution.Failed(cause, settlement) ->
      "failed ("
      <> string.inspect(cause)
      <> "), undone: "
      <> string.inspect(settlement.undone)
    other -> string.inspect(other)
  }
}
