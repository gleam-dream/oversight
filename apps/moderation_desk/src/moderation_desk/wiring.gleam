//// The store wiring: how the platform's own state and the decision
//// point's record share one `decisions_otp/store`, so that a release, a
//// visibility change and an author's strike commit or roll back together.
////
//// The platform's state is rows of its own tables in the same store:
////
//// | Table | Key | Value |
//// | --- | --- | --- |
//// | `posts` | post id | the current revision |
//// | `revisions` | `id@revision` | that revision, never changed |
//// | `visibility` | post id | whether readers see it |
//// | `authors` | author id | the author's history |
//// | `threads` | thread id | the thread |
//// | `intake` | occurrence key | a delivery already admitted |
//// | `released` | release key | the action the gated tool applied |
//// | `outbox` | ordered | a notification to an author |
//// | `safety` | post id | a case handed to the safety team |
//// | `claims` | occurrence id | which moderator holds the card |
//// | `policy` | `current` | the published policy version |
//// | `models` | `classifier` | the classifier version in use |

import decisions.{type Desk, Gated}
import decisions/model.{type Failure}
import decisions/policy.{type Fault, type Policy}
import decisions/store as port
import decisions/vocabulary.{type Ref, type Subject, Ref, Subject}
import decisions_otp/store.{type Store, type Tx}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import moderation_desk/domain.{
  type Action, type Author, type Post, type Thread, type Visibility,
}
import moderation_desk/point

pub const posts = "posts"

pub const revisions = "revisions"

pub const visibility_table = "visibility"

pub const authors = "authors"

pub const threads = "threads"

pub const intake = "intake"

pub const released = "released"

pub const outbox = "outbox"

pub const safety = "safety"

pub const claims = "claims"

/// The renderer version of every card and prompt about a post.
pub const renderer = "moderation-card-1"

/// The desk of the point over the store. It holds no state: build it
/// wherever it is needed.
pub fn desk() -> Desk(Action, Tx) {
  desk_over(store.port())
}

/// The desk of the point over `port`: the store's own port, or one a test
/// wraps to make a write fail.
pub fn desk_over(port: port.Port(Tx)) -> Desk(Action, Tx) {
  decisions.desk(
    point.declaration(),
    drives: fn(_) { gated() },
    under: current_policy,
    over: port,
  )
}

/// The gated tool. Its guard refuses a post that no longer exists; its
/// executor records the applied action under the release's key, which is
/// what the invariant checker counts as the tool's effects. Making the
/// post visible or hidden is what follows the settlement
/// (`moderation_desk/followers`).
pub fn gated() -> decisions.Gated(Action, Tx) {
  Gated(
    name: "moderation.apply",
    guard: fn(tx, subject: Subject) {
      case post(tx, subject.id) {
        Ok(found) -> Ok([post_ref(found)])
        // A judgement about the release: there is nothing to apply it to.
        Error(Nil) ->
          Error(decisions.Refuse(
            "the post " <> subject.id <> " no longer exists",
          ))
      }
    },
    execute: fn(tx, release) {
      store.put(
        tx,
        released,
        decisions.key(release),
        domain.to_text(domain.action_codec(), decisions.output(release)),
      )
      Ok(Nil)
    },
  )
}

// -- Policy and model versions ---------------------------------------------------

/// The policy as published, read in the caller's transaction.
pub fn current_policy(tx: Tx) -> Result(Policy, String) {
  use text <- result.try(
    store.get(tx, "policy", "current")
    |> result.replace_error("no policy is published"),
  )
  json.parse(text, policy.decoder())
  |> result.map_error(fn(error) { string.inspect(error) })
}

/// Publish a policy version and the classifier version that goes with it,
/// in the caller's transaction. Refused when the policy reads a fact the
/// point does not declare.
pub fn publish(
  tx: Tx,
  policy: Policy,
  classifier: String,
) -> Result(Nil, List(Fault)) {
  use Nil <- result.map(decisions.publishable(point.declaration(), policy))
  store.put(tx, "policy", "current", json.to_string(policy.to_json(policy)))
  store.put(tx, "models", "classifier", classifier)
}

/// The classifier version in use; `"1"` until another is published.
pub fn classifier_version(tx: Tx) -> String {
  store.get(tx, "models", "classifier") |> result.unwrap("1")
}

// -- Posts, authors and threads ---------------------------------------------------

/// Who an occurrence about a post is about.
pub fn subject(post_id: String) -> Subject {
  Subject(kind: "post", id: post_id)
}

/// The key of the occurrence about one revision of a post. Keys are one
/// namespace across a store's points, so the point's name prefixes it.
pub fn key(post: Post) -> String {
  point.name <> ":" <> post.id <> "@" <> int.to_string(post.revision)
}

/// The context reference to one revision of a post.
pub fn post_ref(post: Post) -> Ref {
  Ref(kind: "post", id: post.id, revision: int.to_string(post.revision))
}

fn revision_key(id: String, revision: String) -> String {
  id <> "@" <> revision
}

/// Lock a post's visibility until the transaction ends, so that a
/// settlement, an edit and an appeal change it one at a time.
pub fn lock_visibility(tx: Tx, id: String) -> Result(Nil, port.StoreError) {
  store.lock(tx, "visibility:" <> id)
}

/// The current revision of a post.
pub fn post(tx: Tx, id: String) -> Result(Post, Nil) {
  store.get(tx, posts, id) |> result.try(decode(domain.post_codec(), _))
}

/// One revision of a post, as it was.
pub fn revision(tx: Tx, id: String, revision: String) -> Result(Post, Nil) {
  store.get(tx, revisions, revision_key(id, revision))
  |> result.try(decode(domain.post_codec(), _))
}

/// Store a post as its current revision, and that revision for good.
pub fn put_post(tx: Tx, post: Post) -> Nil {
  let text = domain.to_text(domain.post_codec(), post)
  store.put(tx, posts, post.id, text)
  store.put(
    tx,
    revisions,
    revision_key(post.id, int.to_string(post.revision)),
    text,
  )
}

pub fn author(tx: Tx, id: String) -> Result(Author, Nil) {
  store.get(tx, authors, id) |> result.try(decode(domain.author_codec(), _))
}

pub fn put_author(tx: Tx, author: Author) -> Nil {
  store.put(
    tx,
    authors,
    author.id,
    domain.to_text(domain.author_codec(), author),
  )
}

pub fn thread(tx: Tx, id: String) -> Result(Thread, Nil) {
  store.get(tx, threads, id) |> result.try(decode(domain.thread_codec(), _))
}

pub fn put_thread(tx: Tx, thread: Thread) -> Nil {
  store.put(
    tx,
    threads,
    thread.id,
    domain.to_text(domain.thread_codec(), thread),
  )
}

pub fn visibility(tx: Tx, id: String) -> Result(Visibility, Nil) {
  store.get(tx, visibility_table, id)
  |> result.try(decode(domain.visibility_codec(), _))
}

pub fn set_visibility(tx: Tx, id: String, visibility: Visibility) -> Nil {
  store.put(
    tx,
    visibility_table,
    id,
    domain.to_text(domain.visibility_codec(), visibility),
  )
}

fn decode(codec: Codec(a), text: String) -> Result(a, Nil) {
  domain.from_text(codec, text) |> result.replace_error(Nil)
}

// -- What a model reads, and what a card resolves ------------------------------------

/// The name of the read of an author's history.
pub const author_history = "author_history"

/// The name of the read of a thread.
pub const thread_read = "thread"

/// The body a read returns now: an author's history or a thread, as JSON
/// text. Its digest is the revision a capture records.
pub fn read_body(
  tx: Tx,
  name: String,
  argument: String,
) -> Result(String, Nil) {
  case name {
    _ if name == author_history ->
      author(tx, argument)
      |> result.map(domain.to_text(domain.author_codec(), _))
    _ if name == thread_read ->
      thread(tx, argument)
      |> result.map(domain.to_text(domain.thread_codec(), _))
    _ -> Error(Nil)
  }
}

/// The revision of an input as it is now, for `decisions.open`: a post's
/// current revision, or the digest of what a read would return now. A
/// card whose model read an older revision shows the input as changed.
pub fn latest(tx: Tx) -> fn(Ref) -> String {
  fn(ref: Ref) {
    case ref.kind {
      "post" ->
        post(tx, ref.id)
        |> result.map(fn(p) { int.to_string(p.revision) })
        |> result.unwrap(ref.revision)
      kind ->
        read_body(tx, kind, ref.id)
        |> result.map(model.digest)
        |> result.unwrap(ref.revision)
    }
  }
}

/// The content a reference names, as it was read: a post's revision, or
/// the evidence a capture stored. Cards, examples and replays resolve
/// through it, never through the world as it is now.
pub fn content(s: Store) -> fn(Ref) -> Result(String, Failure) {
  fn(ref: Ref) {
    let tx = store.handle(s)
    case ref.kind {
      "post" ->
        store.get(tx, revisions, revision_key(ref.id, ref.revision))
        |> result.replace_error(model.NotRecorded(
          read: "post",
          argument: ref.id,
        ))
      kind ->
        store.evidence().get(tx, ref)
        |> result.replace_error(model.NotRecorded(read: kind, argument: ref.id))
    }
  }
}

/// Every notification in the outbox, as `#(post, occurrence,
/// notification)`, in the order they were added.
pub fn notifications(tx: Tx) -> List(#(String, String, domain.Notification)) {
  store.rows(tx, outbox)
  |> list.filter_map(fn(row) {
    json.parse(row.1, {
      use post <- decode_field("post")
      use occurrence <- decode_field("occurrence")
      use notification <- decode_field("notification")
      decode_success(#(post, occurrence, notification))
    })
    |> result.replace_error(Nil)
    |> result.try(fn(triple) {
      let #(post, occurrence, text) = triple
      domain.from_text(domain.notification_codec(), text)
      |> result.replace_error(Nil)
      |> result.map(fn(n) { #(post, occurrence, n) })
    })
  })
}

/// Add a notification to the outbox, in the caller's transaction.
pub fn notify(
  tx: Tx,
  post: String,
  occurrence: String,
  notification: domain.Notification,
) -> Nil {
  store.add(
    tx,
    outbox,
    json.to_string(
      json.object([
        #("post", json.string(post)),
        #("occurrence", json.string(occurrence)),
        #(
          "notification",
          json.string(domain.to_text(domain.notification_codec(), notification)),
        ),
      ]),
    ),
  )
}

fn decode_field(
  name: String,
  next: fn(String) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.field(name, decode.string, next)
}

fn decode_success(value: a) -> decode.Decoder(a) {
  decode.success(value)
}
