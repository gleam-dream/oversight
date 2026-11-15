//// The models and the worker that runs them. A post goes through a
//// cascade: a cheap rule model answers the obvious cases and abstains on
//// the rest, and a slower classifier answers what remains, reading the
//// author's history and the thread through captured reads. In production
//// each model runs in a process of its own with a deadline
//// (`decisions_otp/isolated`); under replay the same models run as plain
//// functions over the record.

import decisions.{type Desk, type HandlerFailure}
import decisions/fact
import decisions/model.{type Failure, type Model, type Sources, Sources}
import decisions/occurrence.{type Occurrence}
import decisions/store as port
import decisions/vocabulary.{
  type Manifest, Classifier, Manifest, Recommendation, RuleFired, Rules, Trigger,
}
import decisions_otp/backlog.{type Submitted}
import decisions_otp/isolated
import decisions_otp/store.{type Store, type Tx}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}
import moderation_desk/domain.{
  type Action, type Author, type Post, type Thread, Breaks, Clean, Hide, Publish,
  Spam,
}
import moderation_desk/point
import moderation_desk/scripted.{type Fault}
import moderation_desk/telemetry
import moderation_desk/wiring
import sinal

/// What the classifier reads: the post, its author's history and its
/// thread.
pub type PostContext {
  PostContext(post: Post, author: Author, thread: Thread)
}

/// How long each model may take, and how long the scripted classifier
/// takes when nothing goes wrong.
pub type Timing {
  Timing(
    rules_within: Duration,
    classifier_within: Duration,
    classifier_ms: Int,
  )
}

fn decoded(
  codec: Codec(a),
  text: String,
  read: String,
  argument: String,
) -> Result(a, Failure) {
  domain.from_text(codec, text)
  |> result.map_error(fn(reason) { model.ReadFailed(read:, argument:, reason:) })
}

/// The post the context names.
pub fn post_of(context: Manifest, sources: Sources) -> Result(Post, Failure) {
  case context.refs {
    [ref, ..] if ref.kind == "post" -> {
      use text <- result.try(sources.resolve(ref))
      decoded(domain.post_codec(), text, "post", ref.id)
    }
    _ -> Error(model.NotRecorded(read: "post", argument: ""))
  }
}

/// The classifier's reader. The same function serves the model, the
/// card (`decisions/view.context`) and a replay, so all three receive the
/// same value.
pub fn reader() -> model.Reader(PostContext) {
  fn(context: Manifest, sources: Sources) {
    use post <- result.try(post_of(context, sources))
    use history <- result.try(sources.read(wiring.author_history, post.author))
    use author <- result.try(decoded(
      domain.author_codec(),
      history.body,
      wiring.author_history,
      post.author,
    ))
    use found <- result.try(sources.read(wiring.thread_read, post.thread))
    use thread <- result.try(decoded(
      domain.thread_codec(),
      found.body,
      wiring.thread_read,
      post.thread,
    ))
    Ok(PostContext(post:, author:, thread:))
  }
}

/// What the rule model answers for a text, with the rule that fired, or
/// `None` when no rule applies.
pub fn rule_answer(text: String) -> Option(#(Action, domain.Category, String)) {
  case
    string.contains(text, "http://cheap-pills."),
    string.starts_with(text, "thanks!") && string.length(text) <= 20
  {
    True, _ -> Some(#(Hide(Spam), Breaks(Spam), "known-spam-domain"))
    False, True -> Some(#(Publish, Clean, "short-thanks"))
    False, False -> None
  }
}

/// The rule model. It reads nothing beyond the post and declines when no
/// rule applies, which makes a cascade ask the next stage.
pub fn rules() -> Model(Action) {
  model.new(fn(context, sources) {
    use post <- result.try(post_of(context, sources))
    case rule_answer(post.text) {
      Some(#(action, category, rule)) ->
        Ok(
          Recommendation(
            output: action,
            by: Rules(name: "moderation-rules", version: "1"),
            explanation: RuleFired(rule),
            signals: [
              fact.set(point.stage(), "rules"),
              fact.set(point.category(), domain.category_name(category)),
              fact.set(point.confidence(), 1.0),
            ],
            reads: [],
          ),
        )
      None -> Error(model.Declined("no rule applies"))
    }
  })
}

/// The scripted classifier of `version`, suffering `fault`, taking
/// `latency_ms` when healthy. Its reads are observed: every read the
/// reader made is on the recommendation.
pub fn classifier(
  version: String,
  fault: Fault,
  latency_ms: Int,
) -> Model(Action) {
  model.over(reader(), fn(context: PostContext) {
    case fault {
      scripted.Hangs -> process.sleep_forever()
      scripted.Raises -> panic as "the classifier crashed"
      scripted.Slow(ms) -> process.sleep(ms)
      scripted.Healthy -> process.sleep(latency_ms)
    }
    let answer =
      scripted.classify(version, context.post, context.author, context.thread)
    Ok(
      Recommendation(
        output: answer.action,
        by: Classifier(name: "moderation-classifier", version:),
        explanation: RuleFired(
          "scripted:" <> domain.category_name(answer.category),
        ),
        signals: [
          fact.set(point.stage(), "classifier"),
          fact.set(point.confidence(), answer.confidence),
          fact.set(point.category(), domain.category_name(answer.category)),
          fact.set(point.new_author(), domain.is_new(context.author)),
        ],
        reads: [],
      ),
    )
  })
}

/// The production cascade: each model in a process of its own with its
/// deadline.
pub fn cascade(version: String, fault: Fault, timing: Timing) -> Model(Action) {
  model.cascade([
    model.stage(isolated.model(rules(), within: timing.rules_within)),
    model.stage(isolated.model(
      classifier(version, fault, timing.classifier_ms),
      within: timing.classifier_within,
    )),
  ])
}

/// The cascade as a pure candidate for a replay: no process, no deadline,
/// no latency.
pub fn candidate(version: String) -> Model(Action) {
  model.cascade([
    model.stage(rules()),
    model.stage(classifier(version, scripted.Healthy, 0)),
  ])
}

/// What a model may read in production. A post resolves to its revision;
/// a read is captured as evidence before the model sees it, so the card
/// and a replay get the same content later.
pub fn sources(s: Store) -> Sources {
  Sources(resolve: wiring.content(s), read: fn(name, argument) {
    let handle = store.handle(s)
    model.capture(
      store.evidence(),
      handle,
      source: name,
      request: argument,
      fetch: fn() {
        wiring.read_body(handle, name, argument)
        |> result.replace_error("nothing to read")
      },
    )
    |> result.map_error(fn(reason) {
      model.ReadFailed(read: name, argument:, reason:)
    })
  })
}

// -- The worker ------------------------------------------------------------------------

/// Everything a worker needs.
pub type Env {
  Env(
    store: Store,
    desk: Desk(Action, Tx),
    /// Who the application is, as its telemetry events say.
    source: String,
    timing: Timing,
    /// The fault the classifier suffers for a post on an attempt.
    faults: fn(Post, Int) -> Fault,
  )
}

/// The payload of a trigger: the post's id and revision.
pub fn payload(post: Post) -> String {
  wiring.key(post)
}

/// How a trigger becomes a recommendation, for `decisions_otp/runtime`.
/// A key already recommended is done without running a model. A failed
/// model is on the record and is the application's failure, so the
/// runtime counts the attempt, retries after a backoff, and sets the
/// trigger aside when it keeps failing.
pub fn work(env: Env) -> fn(Submitted) -> Result(Nil, HandlerFailure) {
  fn(submitted: Submitted) {
    let handle = store.handle(env.store)
    case decisions.read(env.desk, handle, occurrence: submitted.key) {
      Ok(_) -> Ok(Nil)
      Error(decisions.NotRecommended(attempts:)) ->
        attempt(env, submitted, list.length(attempts) + 1)
      Error(decisions.UnknownOccurrence) -> attempt(env, submitted, 1)
      Error(refusal) -> Error(decisions.DeskRefused(refusal))
    }
  }
}

fn attempt(
  env: Env,
  submitted: Submitted,
  number: Int,
) -> Result(Nil, HandlerFailure) {
  let handle = store.handle(env.store)
  use post <- result.try(
    post_in(handle, submitted.payload)
    |> result.map_error(decisions.ApplicationFailed),
  )
  let request =
    isolated.Request(
      source: env.source,
      key: submitted.key,
      trigger: Trigger(kind: "post", id: submitted.key),
      about: wiring.subject(post.id),
      context: Manifest(
        refs: [wiring.post_ref(post)],
        renderer: wiring.renderer,
      ),
      sources: sources(env.store),
    )
  let model =
    cascade(
      wiring.classifier_version(handle),
      env.faults(post, number),
      env.timing,
    )
  case
    isolated.recommend_when(
      env.desk,
      in: store.transaction(env.store, _),
      request:,
      model:,
      holds: still_latest(_, post),
    )
  {
    Ok(isolated.Recommended(occurrence:)) -> {
      report(env.source, occurrence)
      Ok(Nil)
    }
    // An edit came after this trigger; the edit's own trigger decides.
    Ok(isolated.Skipped(_)) -> Ok(Nil)
    Ok(isolated.Failed(failure:, ..)) ->
      Error(decisions.ApplicationFailed(model.describe(failure)))
    Error(refusal) -> Error(decisions.DeskRefused(refusal))
  }
}

/// Inside the recommending transaction: the post's row still names this
/// revision. The post's lock serialises this check with an edit, which
/// takes the same lock to name a newer revision.
fn still_latest(tx: Tx, post: Post) -> Result(Nil, String) {
  use Nil <- result.try(
    wiring.lock_post(tx, post.id) |> result.map_error(port.describe),
  )
  case wiring.post(tx, post.id) {
    Ok(current) if current.revision == post.revision -> Ok(Nil)
    Ok(_) -> Error("an edit replaced revision " <> int.to_string(post.revision))
    Error(Nil) -> Error("the post is gone")
  }
}

fn post_in(tx: Tx, payload: String) -> Result(Post, String) {
  case string.split_once(payload, "@") {
    Ok(#(prefixed, revision)) -> {
      let id = string.replace(prefixed, point.name <> ":", "")
      wiring.revision(tx, id, revision)
      |> result.replace_error("no revision " <> payload)
    }
    Error(Nil) -> Error("a trigger payload names no revision: " <> payload)
  }
}

/// Emit what the policy said about a fresh recommendation.
fn report(source: String, occurrence: Occurrence(Action)) -> Nil {
  let signals = occurrence.recommendation.signals
  sinal.emit(
    telemetry.post_recommended(),
    telemetry.Count(1),
    telemetry.Recommended(
      source:,
      occurrence: occurrence.id,
      stage: fact.get(signals, point.stage()) |> result.unwrap("unknown"),
      outcome: case occurrence.status {
        occurrence.Awaiting(_) | occurrence.Recommended(_) -> telemetry.Waiting
        _ -> telemetry.Proceeded
      },
      sampled: occurrence.sampled,
    ),
  )
}
