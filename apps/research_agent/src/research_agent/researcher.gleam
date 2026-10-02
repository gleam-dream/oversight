//// The Fabric agent: two read-only tools over http_gun (`search`, `read`),
//// one policy, and the llm_wire model on the app's LLM client.

import fabric/agent.{type Agent}
import fabric/llm
import fabric/policy
import fabric/run
import fabric/tool
import gleam/http
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/uri
import http_gun
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/types
import research_agent/domain.{
  type Page, type PageRequest, type SearchQuery, type SearchResults, Page,
}
import research_agent/remote
import research_agent/telemetry.{type Telemetry}

/// The live context of one run. Fabric never stores it: `start`, `open` and
/// `recover` each take it again. The HTTP client carries the research id as
/// its telemetry correlation.
pub type Context {
  Context(research: String, http: http_gun.Client)
}

pub fn context(
  http: http_gun.Client,
  telemetry: Option(Telemetry),
  research: String,
) -> Context {
  Context(research:, http: remote.correlated(http, telemetry, research))
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
  context: Context,
  query: SearchQuery,
) -> Result(SearchResults, remote.Failure) {
  let url = endpoints.search <> "?q=" <> uri.percent_encode(query.query)
  use body <- result.try(
    remote.call(context.http, http.Get, url, [], "")
    |> remote.expect([200]),
  )
  codec.decode_json(domain.search_results_codec(), body)
  |> result.map_error(fn(e) {
    remote.Status(200, codec.render_json_decode_error(e))
  })
}

pub fn read(
  context: Context,
  request: PageRequest,
) -> Result(Page, remote.Failure) {
  remote.call(context.http, http.Get, request.url, [], "")
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
) -> Result(Agent(Context), List(agent.ConfigError)) {
  let assert Ok(key) = types.api_key("sk-scripted")
  let assert Ok(model_id) = types.model_id("gpt-scripted")
  let assert Ok(endpoint) = types.endpoint(endpoints.llm)
  let settings =
    config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
  let model = llm.model(llm_client, settings, model_id)
  let tools = [
    tool.bind(
      search_definition(),
      fn(context, query) { search(endpoints, context, query) },
      explain,
    ),
    tool.bind(
      read_definition(),
      fn(context, page) { read(context, page) },
      explain,
    ),
  ]
  agent.new("researcher", model, tools, gate(endpoints))
  |> agent.with_system_prompt(domain.system_prompt())
  |> agent.with_limits(
    agent.Limits(..agent.default_limits(), max_turns: 8, model_retry_delay: 50),
  )
  |> agent.build
}

/// Recovery glue. After a crash, Fabric turns every tool that had started
/// into an uncertain effect and suspends the run until someone reconciles
/// it, even a read-only search. Fabric's agent tools cannot declare "safe to
/// run again" (graph operations can, `operation.with_replay`), so the app
/// finds the action's arguments in the snapshot, runs the read again and
/// reconciles with the encoded output the model would have seen.
pub fn replay_read_only(
  endpoints: Endpoints,
  context: Context,
  snapshot: run.Snapshot,
  uncertain: run.UncertainAction,
) -> Result(String, String) {
  use record <- result.try(
    snapshot.actions
    |> find_action(uncertain.reference.id)
    |> result.replace_error("no action record for the uncertain effect"),
  )
  let arguments = record.call.arguments_json
  let rendered = case uncertain.tool {
    "search" -> {
      use query <- result.try(decode(domain.search_query_codec(), arguments))
      use found <- result.try(
        search(endpoints, context, query) |> result.map_error(remote.describe),
      )
      encode(domain.search_results_codec(), found)
    }
    "read" -> {
      use page <- result.try(decode(domain.page_request_codec(), arguments))
      use page <- result.try(
        read(context, page) |> result.map_error(remote.describe),
      )
      encode(domain.page_codec(), page)
    }
    other -> Error("tool " <> other <> " is not read-only")
  }
  rendered
}

fn find_action(
  actions: List(run.ActionRecord),
  id: run.ActionId,
) -> Result(run.ActionRecord, Nil) {
  case actions {
    [] -> Error(Nil)
    [first, ..] if first.id == id -> Ok(first)
    [_, ..rest] -> find_action(rest, id)
  }
}

fn decode(c: codec.Codec(a), text: String) -> Result(a, String) {
  codec.decode_json(c, text) |> result.map_error(codec.render_json_decode_error)
}

fn encode(c: codec.Codec(a), value: a) -> Result(String, String) {
  codec.encode_json(c, value) |> result.map_error(string.inspect)
}
