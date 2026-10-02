//// The research domain: what a caller asks for, what the agent finds, and
//// what gets published. Codecs live next to the types so that one value has
//// one wire shape everywhere it is stored or sent.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
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
  codec.field("query", codec.string() |> codec.describe("Search terms"))
  |> codec.imap(SearchQuery, fn(q) { q.query })
}

pub fn hit_codec() -> codec.Codec(Hit) {
  let assert Ok(hit) =
    codec.record2(
      codec.required("title", codec.string()),
      codec.required("url", codec.string()),
      Hit,
      fn(hit) { hit.title },
      fn(hit) { hit.url },
    )
  hit
}

/// Also decodes the search API's response body: one codec for the HTTP
/// payload and the tool output the model reads.
pub fn search_results_codec() -> codec.Codec(SearchResults) {
  codec.field("results", codec.list(hit_codec()))
  |> codec.imap(SearchResults, fn(r) { r.hits })
}

pub fn page_request_codec() -> codec.Codec(PageRequest) {
  codec.field("url", codec.string() |> codec.describe("A URL from search"))
  |> codec.imap(PageRequest, fn(p) { p.url })
}

pub fn page_codec() -> codec.Codec(Page) {
  let assert Ok(page) =
    codec.record2(
      codec.required("url", codec.string()),
      codec.required("text", codec.string()),
      Page,
      fn(page) { page.url },
      fn(page) { page.text },
    )
  page
}

// Grind codecs (gleam_json + decode) -------------------------------------

pub fn research_json(research: Research) -> json.Json {
  json.object([
    #("id", json.string(research.id)),
    #("topic", json.string(research.topic)),
  ])
}

pub fn research_decoder() -> decode.Decoder(Research) {
  use id <- decode.field("id", decode.string)
  use topic <- decode.field("topic", decode.string)
  decode.success(Research(id:, topic:))
}

pub fn published_json(published: Published) -> json.Json {
  json.object([
    #("draft_id", json.string(published.draft_id)),
    #("url", json.string(published.url)),
  ])
}

pub fn published_decoder() -> decode.Decoder(Published) {
  use draft_id <- decode.field("draft_id", decode.string)
  use url <- decode.field("url", decode.string)
  decode.success(Published(draft_id:, url:))
}

pub fn article_json(article: Article) -> json.Json {
  json.object([
    #("research_id", json.string(article.research_id)),
    #("title", json.string(article.title)),
    #("body", json.string(article.body)),
  ])
}

pub fn article_decoder() -> decode.Decoder(Article) {
  use research_id <- decode.field("research_id", decode.string)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  decode.success(Article(research_id:, title:, body:))
}

// The agent's answer ------------------------------------------------------

/// Fabric ends a run with `Completed(text: String)`, so the article's shape
/// is a convention the system prompt asks for: `TITLE: ...` on the first
/// line, the body after it, and `NO SOURCES` when research failed.
pub type Answer {
  Written(title: String, body: String)
  NoSources(reason: String)
}

pub fn parse_answer(text: String) -> Result(Answer, String) {
  let text = string.trim(text)
  case string.split_once(text, "\n") {
    _ if text == "" -> Error("empty answer")
    _ ->
      case string.starts_with(text, "NO SOURCES") {
        True -> Ok(NoSources(string.drop_start(text, 10) |> string.trim))
        False -> {
          let #(first, rest) =
            string.split_once(text, "\n") |> result.unwrap(#(text, ""))
          case string.starts_with(first, "TITLE:") {
            True ->
              Ok(Written(
                string.drop_start(first, 6) |> string.trim,
                string.trim(rest),
              ))
            False -> Error("answer does not start with TITLE:")
          }
        }
      }
  }
}

pub fn system_prompt() -> String {
  [
    "You research a topic with the search and read tools, then write a short article.",
    "Answer with 'TITLE: <title>' on the first line and the article below it.",
    "If no source can be read, answer 'NO SOURCES <reason>'.",
  ]
  |> list.fold("", fn(acc, line) { acc <> line <> "\n" })
}

/// The prompt carries a marker the scripted provider uses to pick a script.
pub fn prompt(research: Research) -> String {
  "Research [[topic:" <> research.topic <> "]] and write an article."
}
