//// The Fabric agent: two read-only tools over http_gun (`search`, `read`),
//// one policy, and the llm_wire model on the app's LLM client.

import fabric/agent.{type Agent}
import fabric/llm
import fabric/policy
import fabric/tool
import gleam/http
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/uri
import http_gun
import json/blueprint/codec
import llm_wire
import llm_wire/openai
import research_agent/domain.{
  type Answer, type Page, type PageRequest, type SearchQuery, type SearchResults,
  Page,
}
import research_agent/remote
import sinal/correlation.{type Correlation}

/// The live context of every run. Fabric never stores it: `start`, `open` and
/// `recover` each take it again. It holds no run's identity: each tool call
/// joins its run by `tool.Call.correlation`.
pub type Context {
  Context(http: http_gun.Client)
}

/// The tools' HTTP client for one correlation, the run's.
fn client(context: Context, correlation: Correlation) -> http_gun.Client {
  http_gun.with_correlation(context.http, correlation)
}

/// Where the tools and the provider live.
pub type Endpoints {
  Endpoints(search: String, pages: String, llm: String)
}

pub fn search_definition() -> tool.Definition(SearchQuery, SearchResults) {
  tool.define(
    "search",
    "Search the research library.",
    domain.search_query_codec(),
    domain.search_results_codec(),
  )
}

pub fn read_definition() -> tool.Definition(PageRequest, Page) {
  tool.define(
    "read",
    "Read one page from the research library.",
    domain.page_request_codec(),
    domain.page_codec(),
  )
}

pub fn search(
  endpoints: Endpoints,
  http: http_gun.Client,
  query: SearchQuery,
) -> Result(SearchResults, remote.Failure) {
  let url = endpoints.search <> "?q=" <> uri.percent_encode(query.query)
  use body <- result.try(
    remote.call(http, http.Get, url, [], "")
    |> remote.expect([200]),
  )
  codec.decode_json(domain.search_results_codec(), body)
  |> result.map_error(fn(e) {
    remote.Status(200, codec.describe_decode_error(e))
  })
}

pub fn read(
  http: http_gun.Client,
  request: PageRequest,
) -> Result(Page, remote.Failure) {
  remote.call(http, http.Get, request.url, [], "")
  |> remote.expect([200])
  |> result.map(fn(text) { Page(request.url, text) })
}

/// Both tools only read, so every failure is definite: the model sees it
/// and may try again. Nothing is ever `Uncertain` from these handlers.
fn explain(failure: remote.Failure) -> tool.Failure {
  tool.Explain(case failure {
    remote.Status(503, _) -> "the search service is unavailable (HTTP 503)"
    other -> remote.describe(other)
  })
}

/// Reads may only go to the research library.
pub fn gate(endpoints: Endpoints) -> policy.Policy(Context) {
  fn(_context: Context, action: policy.Action) {
    use page <- result.try(tool.input(read_definition(), action))
    case page {
      Some(page) ->
        case string.starts_with(page.url, endpoints.pages) {
          True -> Ok(policy.Allow)
          False -> Ok(policy.Deny("only the research library may be read"))
        }
      _ -> Ok(policy.Allow)
    }
  }
}

pub fn build(
  llm_client: http_gun.Client,
  endpoints: Endpoints,
) -> Result(Agent(Context, Answer), List(agent.ConfigError)) {
  let settings =
    openai.new("sk-scripted")
    |> openai.config
    |> llm_wire.with_endpoint(endpoints.llm)
  let model = llm.model(llm_client, settings, "gpt-scripted")
  let tools =
    [
      tool.bind(
        search_definition(),
        fn(context, call, query) {
          search(endpoints, client(context, call.correlation), query)
        },
        explain,
      ),
      tool.bind(
        read_definition(),
        fn(context, call, page) {
          read(client(context, call.correlation), page)
        },
        explain,
      ),
    ]
    // Both tools only read, so a crash may start them again instead of
    // suspending the run on an uncertain effect.
    |> list.map(tool.with_replay(_, 3))
  agent.new("researcher", model, tools, gate(endpoints))
  |> agent.with_system_prompt(domain.system_prompt())
  |> agent.with_answer(domain.answer_codec())
  |> agent.with_max_turns(8)
  |> agent.with_model_retry_delay(duration.milliseconds(50))
  |> agent.build
}
