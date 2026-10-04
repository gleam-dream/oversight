//// The research domain: what a caller asks for, what the agent finds, and
//// what gets published. Codecs live next to the types so that one value has
//// one wire shape everywhere it is stored or sent.

import gleam/list
import json/blueprint/codec

/// One research request. `id` is the application's key: the job input, the
/// row in `research`, the saga execution id and the telemetry correlation.
pub type Research {
  Research(id: String, topic: String)
}

/// A search hit the agent may read.
pub type Hit {
  Hit(title: String, url: String)
}

/// The finished article the agent wrote, parsed from its final answer.
pub type Article {
  Article(research_id: String, title: String, body: String)
}

/// Where the article ended up.
pub type Published {
  Published(draft_id: String, url: String)
}

// Tool payloads (json_blueprint: the model sees their schema) ------------

pub type SearchQuery {
  SearchQuery(query: String)
}

pub type SearchResults {
  SearchResults(hits: List(Hit))
}

pub type PageRequest {
  PageRequest(url: String)
}

pub type Page {
  Page(url: String, text: String)
}

pub fn search_query_codec() -> codec.Codec(SearchQuery) {
  use query <- codec.field(
    "query",
    codec.string() |> codec.describe("Search terms"),
    get: fn(q) { q.query },
  )
  codec.success(SearchQuery(query:))
}

pub fn hit_codec() -> codec.Codec(Hit) {
  use title <- codec.field("title", codec.string(), get: fn(hit) { hit.title })
  use url <- codec.field("url", codec.string(), get: fn(hit) { hit.url })
  codec.success(Hit(title:, url:))
}

/// Also decodes the search API's response body: one codec for the HTTP
/// payload and the tool output the model reads.
pub fn search_results_codec() -> codec.Codec(SearchResults) {
  use hits <- codec.field("results", codec.list(hit_codec()), get: fn(r) {
    r.hits
  })
  codec.success(SearchResults(hits:))
}

pub fn page_request_codec() -> codec.Codec(PageRequest) {
  use url <- codec.field(
    "url",
    codec.string() |> codec.describe("A URL from search"),
    get: fn(p) { p.url },
  )
  codec.success(PageRequest(url:))
}

pub fn page_codec() -> codec.Codec(Page) {
  use url <- codec.field("url", codec.string(), get: fn(page) { page.url })
  use text <- codec.field("text", codec.string(), get: fn(page) { page.text })
  codec.success(Page(url:, text:))
}

// Job and saga payloads ---------------------------------------------------
//
// One Blueprint codec per value. `research_agent/wire` adapts it to Grind's
// and Saga's codec types.

pub fn research_codec() -> codec.Codec(Research) {
  use id <- codec.field("id", codec.string(), get: fn(r) { r.id })
  use topic <- codec.field("topic", codec.string(), get: fn(r) { r.topic })
  codec.success(Research(id:, topic:))
}

pub fn published_codec() -> codec.Codec(Published) {
  use draft_id <- codec.field("draft_id", codec.string(), get: fn(p) {
    p.draft_id
  })
  use url <- codec.field("url", codec.string(), get: fn(p) { p.url })
  codec.success(Published(draft_id:, url:))
}

pub fn article_codec() -> codec.Codec(Article) {
  use research_id <- codec.field("research_id", codec.string(), get: fn(a) {
    a.research_id
  })
  use title <- codec.field("title", codec.string(), get: fn(a) { a.title })
  use body <- codec.field("body", codec.string(), get: fn(a) { a.body })
  codec.success(Article(research_id:, title:, body:))
}

// The agent's answer ------------------------------------------------------

/// What the agent concludes: an article, or the reason it found nothing to
/// write about. Fabric asks the model for `answer_codec`'s schema and
/// decodes the final text with it, so the shape is no prompt convention.
pub type Answer {
  Written(title: String, body: String)
  NoSources(reason: String)
}

/// A tagged union: `{"tag": "written", "value": {"title": .., "body": ..}}`
/// or `{"tag": "no_sources", "value": "<reason>"}`. `fabric/llm` wraps a
/// non-object root as `{"answer": ..}` for the provider and unwraps the
/// reply, so the codec stays the natural sum type.
pub fn answer_codec() -> codec.Codec(Answer) {
  let written = {
    use title <- codec.field(
      "title",
      codec.string() |> codec.describe("The article's title"),
      get: fn(pair: #(String, String)) { pair.0 },
    )
    use body <- codec.field(
      "body",
      codec.string() |> codec.describe("The article's body"),
      get: fn(pair: #(String, String)) { pair.1 },
    )
    codec.success(#(title, body))
  }
  codec.union({
    use written <- codec.variant("written", written, fn(pair) {
      Written(pair.0, pair.1)
    })
    use no_sources <- codec.variant(
      "no_sources",
      codec.string() |> codec.describe("Why no source could be read"),
      NoSources,
    )
    codec.match(fn(answer) {
      case answer {
        Written(title, body) -> written(#(title, body))
        NoSources(reason) -> no_sources(reason)
      }
    })
  })
}

pub fn system_prompt() -> String {
  [
    "You research a topic with the search and read tools, then write a short article.",
    "Answer with the title and the article's body.",
    "If no source can be read, say so and give the reason.",
  ]
  |> list.fold("", fn(acc, line) { acc <> line <> "\n" })
}

/// The prompt carries a marker the scripted provider uses to pick a script.
pub fn prompt(research: Research) -> String {
  "Research [[topic:" <> research.topic <> "]] and write an article."
}
