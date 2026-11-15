//// The scripted world: a deterministic corpus of posts, authors and
//// threads, the classifier that stands in for a language model, the
//// faults a classifier can suffer, and the judgement of the people at the
//// desk. Everything is a pure function of a post's number or text, so a
//// test and the narrated run see the same world.

import decisions/vocabulary.{type Verdict, Approve, Correct, Reason}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import moderation_desk/domain.{
  type Action, type Author, type Category, type Post, type Thread, Abuse, Author,
  Breaks, Clean, Escalate, Hide, Post, Publish, SelfHarm, Spam, Thread, Violence,
}

/// The kinds of post in the corpus, as people would judge them.
pub type Kind {
  /// A link to a known spam domain: the rule model hides it.
  LinkSpam
  /// A short thanks: the rule model publishes it.
  Thanks
  /// An ordinary post.
  Ordinary
  /// Spam the rules do not know.
  CryptoSpam
  /// An open insult.
  Insult
  /// Abuse phrased politely.
  SubtleAbuse
  /// A post about hurting oneself.
  SelfHarmRisk
  /// A threat.
  Threat
  /// Strong words meant as praise.
  Sarcasm
}

/// What a post is, read from its text.
pub fn kind(text: String) -> Kind {
  let has = string.contains(text, _)
  case
    has("http://cheap-pills."),
    string.starts_with(text, "thanks!"),
    has("crypto giveaway"),
    has("idiot"),
    has("people like you"),
    has("hurt myself"),
    has("I will find you"),
    has("killer")
  {
    True, _, _, _, _, _, _, _ -> LinkSpam
    _, True, _, _, _, _, _, _ -> Thanks
    _, _, True, _, _, _, _, _ -> CryptoSpam
    _, _, _, True, _, _, _, _ -> Insult
    _, _, _, _, True, _, _, _ -> SubtleAbuse
    _, _, _, _, _, True, _, _ -> SelfHarmRisk
    _, _, _, _, _, _, True, _ -> Threat
    _, _, _, _, _, _, _, True -> Sarcasm
    _, _, _, _, _, _, _, _ -> Ordinary
  }
}

/// What a careful person would do with a post of this kind.
pub fn truth(text: String) -> Action {
  case kind(text) {
    LinkSpam | CryptoSpam -> Hide(Spam)
    Thanks | Ordinary | Sarcasm -> Publish
    Insult | SubtleAbuse -> Hide(Abuse)
    SelfHarmRisk -> Escalate("risk of self-harm")
    Threat -> Escalate("threat of violence")
  }
}

/// The verdict a moderator gives on a card whose output that stands is
/// `standing`: approve what is right, correct what is not. A moderator
/// defers to a correction someone else already made (`corrected`).
pub fn judge(
  post: Post,
  standing: Action,
  corrected corrected: Bool,
) -> Verdict(Action) {
  let right = truth(post.text)
  case right == standing || corrected {
    True -> Approve
    False ->
      Correct(
        output: right,
        reason: Reason(category: "wrong_action", note: None),
      )
  }
}

// -- The classifier ----------------------------------------------------------------

/// What a classifier answered.
pub type Classification {
  Classification(action: Action, category: Category, confidence: Float)
}

/// The scripted classifier, by version. `"1"` misses polite abuse and
/// takes strong praise for a threat; `"2"` reads the thread and gets both
/// right, with less confidence; `"eager"` publishes everything with high
/// confidence. Each is less confident about a new author.
pub fn classify(
  version: String,
  post: Post,
  author: Author,
  thread: Thread,
) -> Classification {
  let new = domain.is_new(author)
  let lower = fn(confidence: Float) {
    case new {
      True -> confidence -. 0.1
      False -> confidence
    }
  }
  case version, kind(post.text) {
    "eager", _ -> Classification(Publish, Clean, 0.99)
    _, LinkSpam | _, CryptoSpam ->
      Classification(Hide(Spam), Breaks(Spam), 0.95)
    _, Insult -> Classification(Hide(Abuse), Breaks(Abuse), lower(0.85))
    "1", SubtleAbuse -> Classification(Publish, Clean, 0.6)
    _, SubtleAbuse ->
      Classification(Hide(Abuse), Breaks(Abuse), case thread.heated {
        True -> 0.8
        False -> 0.7
      })
    _, SelfHarmRisk ->
      Classification(Escalate("risk of self-harm"), Breaks(SelfHarm), 0.9)
    _, Threat ->
      Classification(Escalate("threat of violence"), Breaks(Violence), 0.9)
    "1", Sarcasm ->
      Classification(Escalate("threat of violence"), Breaks(Violence), 0.55)
    _, Sarcasm -> Classification(Publish, Clean, 0.8)
    "1", Thanks | "1", Ordinary -> Classification(Publish, Clean, lower(0.95))
    _, Thanks | _, Ordinary -> Classification(Publish, Clean, lower(0.97))
  }
}

// -- Faults ---------------------------------------------------------------------------

/// What goes wrong when the classifier runs.
pub type Fault {
  Healthy
  /// It never answers.
  Hangs
  /// It raises.
  Raises
  /// It answers after this many milliseconds.
  Slow(ms: Int)
}

/// The fault a post's text asks for on the given attempt (1 for the
/// first): `[hang]` always hangs, `[hang-once]` hangs on the first attempt
/// only, `[raise]` always raises, `[slow]` answers after 300 ms.
pub fn fault(post: Post, attempt: Int) -> Fault {
  let has = string.contains(post.text, _)
  case has("[hang-once]"), has("[hang]"), has("[raise]"), has("[slow]") {
    True, _, _, _ if attempt == 1 -> Hangs
    True, _, _, _ -> Healthy
    _, True, _, _ -> Hangs
    _, _, True, _ -> Raises
    _, _, _, True -> Slow(300)
    _, _, _, _ -> Healthy
  }
}

// -- The corpus ------------------------------------------------------------------------

/// How many authors and threads the corpus spreads posts over.
pub const author_count = 200

pub const thread_count = 50

/// Every author of the corpus. One in ten joined two days ago.
pub fn authors() -> List(Author) {
  list.map(numbers(0, author_count - 1), fn(n) {
    Author(
      id: "author-" <> int.to_string(n),
      joined_days: case n % 10 {
        0 -> 2
        _ -> 400
      },
      posts: 0,
      strikes: 0,
    )
  })
}

/// Every thread of the corpus. One in five is heated.
pub fn threads() -> List(Thread) {
  list.map(numbers(0, thread_count - 1), fn(n) {
    Thread(id: "thread-" <> int.to_string(n), heated: n % 5 == 0)
  })
}

/// The kind of the `n`th post: a hundred posts hold 30 link spams, 15
/// thanks, 35 ordinary posts, 8 crypto spams, 5 insults, 2 polite abuses,
/// 2 about self-harm, 1 threat and 2 sarcastic ones.
pub fn kind_of(n: Int) -> Kind {
  case n % 100 {
    k if k < 30 -> LinkSpam
    k if k < 45 -> Thanks
    k if k < 80 -> Ordinary
    k if k < 88 -> CryptoSpam
    k if k < 93 -> Insult
    k if k < 95 -> SubtleAbuse
    k if k < 97 -> SelfHarmRisk
    97 -> Threat
    _ -> Sarcasm
  }
}

/// The `n`th post of the corpus, first revision.
pub fn post(n: Int) -> Post {
  let tag = " #" <> int.to_string(n)
  let text = case kind_of(n) {
    LinkSpam -> "cheap meds at http://cheap-pills.example/" <> int.to_string(n)
    Thanks -> "thanks!" <> tag
    Ordinary -> "I tried the new release and the search is faster" <> tag
    CryptoSpam -> "join the crypto giveaway, send 1 coin get 2" <> tag
    Insult -> "only an idiot would write this" <> tag
    SubtleAbuse -> "people like you should not post here" <> tag
    SelfHarmRisk -> "some days I want to hurt myself" <> tag
    Threat -> "I will find you after the match" <> tag
    Sarcasm -> "this patch is killer, well done" <> tag
  }
  Post(
    id: "post-" <> int.to_string(n),
    author: "author-" <> int.to_string(n % author_count),
    thread: "thread-" <> int.to_string(n % thread_count),
    text:,
    revision: 1,
  )
}

/// The posts numbered `from` to `to`.
pub fn posts(from: Int, to: Int) -> List(Post) {
  list.map(numbers(from, to), post)
}

/// The post with a fault marker added to its text.
pub fn faulty(post: Post, marker: String) -> Post {
  Post(..post, text: post.text <> " " <> marker)
}

/// The numbers `from` to `to`, both included.
pub fn numbers(from: Int, to: Int) -> List(Int) {
  count_down(to, from, [])
}

fn count_down(n: Int, from: Int, so_far: List(Int)) -> List(Int) {
  case n < from {
    True -> so_far
    False -> count_down(n - 1, from, [n, ..so_far])
  }
}
