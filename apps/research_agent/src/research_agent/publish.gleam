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
import json/blueprint/codec
import research_agent/domain.{type Article, type Published, Published}
import research_agent/remote
import research_agent/saga_store.{type SagaStore}
import research_agent/wire
import saga
import saga/codec as saga_codec
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
  let text = saga_codec.text()
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
    saga_codec.text(),
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

// Saga codecs: the Blueprint codecs of `domain`, versioned for Saga. ------

pub fn article_codec() -> saga_codec.Codec(Article) {
  wire.saga("article-1", domain.article_codec())
}

fn pair_codec() -> saga_codec.Codec(#(Article, String)) {
  wire.saga("article-draft-1", {
    use article <- codec.field(
      "article",
      domain.article_codec(),
      fn(pair: #(Article, String)) { pair.0 },
    )
    use draft_id <- codec.field(
      "draft_id",
      codec.string(),
      fn(pair: #(Article, String)) { pair.1 },
    )
    codec.success(#(article, draft_id))
  })
}

pub fn published_codec() -> saga_codec.Codec(Published) {
  wire.saga("published-1", domain.published_codec())
}

fn error_codec() -> saga_codec.Codec(PublishError) {
  wire.saga("publish-error-1", {
    use step <- codec.field("step", codec.string(), fn(e: PublishError) {
      e.step
    })
    use detail <- codec.field("detail", codec.string(), fn(e: PublishError) {
      e.detail
    })
    codec.success(PublishError(step:, detail:))
  })
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
