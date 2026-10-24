//// Publishing as a durable Saga: create a draft, upload its body, publish
//// it. A definite failure rolls back by deleting the draft; uncertainty
//// holds its effects for reconciliation and never repeats the mutation.
//// Every step is `recoverable`, so a restarted job reuses saved outputs and
//// asks the publisher what happened to an interrupted step instead of
//// repeating it. Checkpoints go to Postgres through `saga_postgres`.

import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/error as http_error
import json/blueprint/codec
import research_agent/domain.{type Article, type Published, Published}
import research_agent/remote
import research_agent/wire
import saga
import saga/codec as saga_codec
import saga/durable
import saga/execution
import saga/storage.{type Storage}
import sinal/correlation

/// `uncertain` retains whether the mutation may have happened. A false value
/// requires transport NotSent or the publisher's explicit pre-mutation rejection.
pub type PublishError {
  PublishError(step: String, detail: String, uncertain: Bool)
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
  // Every step joins its request: the client takes the run's correlation
  // from the step's key.
  let via = fn(key: saga.EffectKey) {
    http_gun.with_correlation(client, saga.correlation_of(key))
  }
  let delete = fn(key: saga.EffectKey, draft_id: String) {
    remote.call(via(key), http.Delete, base <> "/drafts/" <> draft_id, [], "")
    |> remote.expect([204, 404])
    |> result.replace(Nil)
    |> result.map_error(remote.describe)
  }
  let create_draft =
    saga.effect("create_draft", fn(article: Article, key: saga.EffectKey) {
      remote.call(
        via(key),
        http.Post,
        base <> "/drafts",
        [#("idempotency-key", saga.idempotency_key(key))],
        json.to_string(json.object([#("title", json.string(article.title))])),
      )
      |> remote.expect([201])
      |> result.try(fn(body) {
        json.parse(body, decode.at(["id"], decode.string))
        |> result.replace_error(remote.Status(201, body))
      })
      |> result.map_error(failed("create_draft"))
    })
    |> saga.unknown_when(fn(error) { error.uncertain })
    |> saga.undo(fn(undo) { delete(undo.key, undo.output) })
    |> durable.restore_undo(fn(undo) {
      saga.UndoWith(fn() { delete(undo.key, undo.output) })
    })
    |> durable.recoverable(
      version: "2",
      input: article_codec(),
      output: text,
      resolve: fn(_article, key) {
        // A matching id proves creation. An absent or unavailable lookup
        // cannot rule out a late commit of the interrupted request.
        let url = base <> "/drafts?key=" <> saga.idempotency_key(key)
        case remote.call(via(key), http.Get, url, [], "") {
          Ok(#(200, body)) ->
            case json.parse(body, decode.at(["id"], decode.string)) {
              Ok(id) -> durable.Completed(id)
              Error(_) -> durable.MaybeSent
            }
          _ -> durable.MaybeSent
        }
      },
    )
  let upload =
    saga.effect("upload_body", fn(pair: #(Article, String), key) {
      let #(article, draft_id) = pair
      remote.call(
        via(key),
        http.Put,
        base <> "/drafts/" <> draft_id <> "/body",
        [],
        json.to_string(json.object([#("body", json.string(article.body))])),
      )
      |> remote.expect([204])
      |> result.replace(draft_id)
      |> result.map_error(failed("upload_body"))
    })
    |> saga.unknown_when(fn(error) { error.uncertain })
    // Deleting the resource settles creation and upload. The provider accepts
    // repeated DELETE (204/404), so each completed step owns a real undo.
    |> saga.undo(fn(undo) { delete(undo.key, undo.output) })
    |> durable.restore_undo(fn(undo) {
      saga.UndoWith(fn() { delete(undo.key, undo.output) })
    })
    |> durable.recoverable(
      version: "2",
      input: pair_codec(),
      output: text,
      resolve: fn(pair, key) {
        case read_draft(via(key), base, pair.1) {
          Ok(#("uploaded", _)) | Ok(#("live", _)) -> durable.Completed(pair.1)
          _ -> durable.MaybeSent
        }
      },
    )
  let publish =
    saga.effect("publish", fn(draft_id: String, key) {
      remote.call(
        via(key),
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
    |> saga.unknown_when(fn(error) { error.uncertain })
    |> durable.recoverable(
      version: "2",
      input: text,
      output: published_codec(),
      resolve: fn(draft_id, key) {
        case read_draft(via(key), base, draft_id) {
          Ok(#("live", url)) -> durable.Completed(Published(draft_id, url))
          _ -> durable.MaybeSent
        }
      },
    )
  saga.define("publish_article", fn(article) {
    let draft = article |> saga.perform(create_draft)
    saga.both(article, draft)
    |> saga.perform(upload)
    |> saga.perform(publish)
  })
}

fn failed(step: String) -> fn(remote.Failure) -> PublishError {
  fn(failure) {
    let uncertain = case failure {
      remote.Unreachable(error) ->
        http_error.evidence(error) == http_error.MaybeSent
      // This publisher guarantees that 409 rejects before mutation. Other
      // responses, including malformed success and 5xx, do not settle it.
      remote.Status(409, _) -> False
      remote.Status(_, _) -> True
    }
    PublishError(step, remote.describe(failure), uncertain)
  }
}

// The publisher's readback is evidence of a committed effect. Absence is not
// proof an earlier request cannot still commit, and never authorizes replay.
fn read_draft(
  client: http_gun.Client,
  base: String,
  id: String,
) -> Result(#(String, String), Nil) {
  use body <- result.try(
    remote.call(client, http.Get, base <> "/drafts/" <> id, [], "")
    |> remote.expect([200])
    |> result.replace_error(Nil),
  )
  let decoder = {
    use state <- decode.field("state", decode.string)
    use url <- decode.field("url", decode.string)
    decode.success(#(state, url))
  }
  json.parse(body, decoder) |> result.replace_error(Nil)
}

/// Starts the publication of `article`, or reconnects to the one already
/// stored for its research id, and drives it to an outcome for at most
/// `timeout`. Its saga events carry `correlation`.
pub fn run(
  storage: Storage,
  client: http_gun.Client,
  base: String,
  article: Article,
  correlation: correlation.Correlation,
  timeout timeout: Duration,
) -> Result(Outcome, durable.Error) {
  let persistence =
    durable.new(
      workflow(client, base),
      input: article_codec(),
      output: published_codec(),
      error: error_codec(),
      undo_error: saga_codec.text(),
    )
    |> durable.with_config(
      execution.config()
      |> execution.with_step_timeout(execution.After(duration.seconds(5))),
    )
  use run <- result.try(durable.start_or_reconnect(
    persistence,
    storage,
    id: execution_id(article.research_id),
    input: article,
  ))
  run
  |> durable.with_correlation(correlation)
  |> durable.drive(timeout:)
}

// Saga codecs: the Blueprint codecs of `domain`, versioned for Saga. ------

pub fn article_codec() -> saga_codec.Codec(Article) {
  wire.saga("article-1", domain.article_codec())
}

fn pair_codec() -> saga_codec.Codec(#(Article, String)) {
  wire.saga("article-draft-1", {
    use article <- codec.field("article", domain.article_codec(), get: fn(pair) {
      pair.0
    })
    use draft_id <- codec.field("draft_id", codec.string(), get: fn(pair) {
      pair.1
    })
    codec.success(#(article, draft_id))
  })
}

pub fn published_codec() -> saga_codec.Codec(Published) {
  wire.saga("published-1", domain.published_codec())
}

fn error_codec() -> saga_codec.Codec(PublishError) {
  wire.saga("publish-error-2", {
    use step <- codec.field("step", codec.string(), get: fn(e) { e.step })
    use detail <- codec.field("detail", codec.string(), get: fn(e) { e.detail })
    use uncertain <- codec.field("uncertain", codec.bool(), get: fn(e) {
      e.uncertain
    })
    codec.success(PublishError(step:, detail:, uncertain:))
  })
}

/// A one-line account of an outcome, for logs and job results.
pub fn describe(outcome: Outcome) -> String {
  case outcome {
    execution.Completed(published) -> "published " <> published.url
    execution.Failed(cause, settlement) -> {
      let reason =
        execution.describe_cause(cause, error: fn(e: PublishError) { e.detail })
      let undone = list.map(settlement.undone, saga.address_to_string)
      "failed (" <> reason <> "), undone: " <> string.join(undone, ", ")
    }
    other -> string.inspect(other)
  }
}
