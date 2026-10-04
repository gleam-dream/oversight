//// The scripted outside world, on one loopback mist server:
////
//// - `GET /search?q=` — a search API that can be taken down;
//// - `GET /pages/<id>` — the pages search results point at;
//// - `POST /drafts`, `PUT /drafts/<id>/body`, `POST /drafts/<id>/publish`,
////   `DELETE /drafts/<id>` — a publishing API whose publish step can fail;
//// - `POST /openai/v1/responses` — an OpenAI Responses SSE provider that
////   follows a per-topic script. A script step is chosen by the number of
////   tool results already in the conversation, so a resumed run continues
////   where it stopped and a restarted one would begin again.
////
//// A `Stall` step holds the SSE stream open with keep-alive comments until
//// the client goes away, and reports both moments, so tests can see that
//// cancelling or killing an agent closes the LLM stream.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import llm_wire/message
import llm_wire/testing
import mist

pub type Step {
  CallSearch(query: String)
  CallRead(url: String)
  Answer(text: String)
  /// Hold the stream open until the client disconnects.
  Stall
  /// Stall the first time this step is reached, then behave as `then`.
  StallOnce(then: Step)
  /// Answer with text the answer codec refuses the first time this step is
  /// reached, then behave as `then`: the corrective turn gets `then`.
  GarbledOnce(then: Step)
}

/// What the world reports to whoever listens (tests, the narrative).
pub type Notice {
  LlmStalled(topic: String, step: Int)
  LlmStreamClosed(topic: String, step: Int)
  PageStalled(id: String)
}

pub type Services {
  Services(port: Int, world: Subject(Message))
}

pub type Counts {
  Counts(
    search_calls: Int,
    page_calls: Int,
    llm_calls: Int,
    drafts_created: Int,
    drafts_deleted: Int,
    published: Int,
  )
}

pub type DraftState {
  Draft
  BodyUploaded
  Live
  Deleted
}

pub opaque type Message {
  SetScript(topic: String, steps: List(Step))
  LlmTurn(topic: String, step: Int, reply: Subject(Step))
  Search(reply: Subject(Result(Nil, Int)))
  SetSearchFailures(count: Int)
  SetSearchDown(down: Bool)
  PageRead(id: String, reply: Subject(Bool))
  StallPage(id: String)
  CreateDraft(key: String, reply: Subject(String))
  FindDraft(key: String, reply: Subject(Option(String)))
  UploadBody(id: String, reply: Subject(Bool))
  PublishDraft(id: String, reply: Subject(Result(Nil, Nil)))
  DeleteDraft(id: String, reply: Subject(Bool))
  SetPublishFails(fails: Bool)
  Watch(Subject(Notice))
  Notify(Notice)
  GetCounts(reply: Subject(Counts))
  LlmBody(topic: String, body: String)
  GetLlmBodies(topic: String, reply: Subject(List(String)))
  GetDrafts(reply: Subject(List(#(String, DraftState))))
}

type World {
  World(
    scripts: Dict(String, List(Step)),
    llm_bodies: Dict(String, List(String)),
    hits: Dict(#(String, Int), Int),
    search_failures: Int,
    search_down: Bool,
    stalled_pages: List(String),
    drafts: Dict(String, DraftState),
    draft_keys: Dict(String, String),
    publish_fails: Bool,
    watchers: List(Subject(Notice)),
    counts: Counts,
  )
}

pub fn start() -> Result(Services, String) {
  use world <- result.try(
    actor.new(World(
      scripts: dict.new(),
      llm_bodies: dict.new(),
      hits: dict.new(),
      search_failures: 0,
      search_down: False,
      stalled_pages: [],
      drafts: dict.new(),
      draft_keys: dict.new(),
      publish_fails: False,
      watchers: [],
      counts: Counts(0, 0, 0, 0, 0, 0),
    ))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error("could not start the scripted world"),
  )
  let ports = process.new_subject()
  use _ <- result.try(
    mist.new(fn(req) { route(world, req) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    |> result.replace_error("could not start the loopback server"),
  )
  use port <- result.try(
    process.receive(ports, 2000)
    |> result.replace_error("the loopback server did not report its port"),
  )
  Ok(Services(port:, world:))
}

pub fn base_url(services: Services) -> String {
  "http://127.0.0.1:" <> int.to_string(services.port)
}

pub fn page_url(services: Services, id: String) -> String {
  base_url(services) <> "/pages/" <> id
}

pub fn llm_endpoint(services: Services) -> String {
  base_url(services) <> "/openai/v1/responses"
}

pub fn script(services: Services, topic: String, steps: List(Step)) -> Nil {
  process.send(services.world, SetScript(topic, steps))
}

/// A final answer that found an article, in the shape the agent's answer
/// codec reads. The provider replies with the schema's wrapper, `{"answer":
/// ..}`, which `fabric/llm` unwraps.
pub fn article(title: String, body: String) -> Step {
  answer_json(
    json.object([
      #("tag", json.string("written")),
      #(
        "value",
        json.object([
          #("title", json.string(title)),
          #("body", json.string(body)),
        ]),
      ),
    ]),
  )
}

/// A final answer that found nothing to write about.
pub fn no_sources(reason: String) -> Step {
  answer_json(
    json.object([
      #("tag", json.string("no_sources")),
      #("value", json.string(reason)),
    ]),
  )
}

fn answer_json(answer: json.Json) -> Step {
  Answer(json.to_string(json.object([#("answer", answer)])))
}

/// The ordinary script: search, read the first hit, answer.
pub fn happy_script(services: Services, topic: String) -> List(Step) {
  [
    CallSearch(topic),
    CallRead(page_url(services, topic <> "-1")),
    article(
      "All about " <> topic,
      topic <> " is well documented; this article summarises one source.",
    ),
  ]
}

/// The next `count` searches answer 503.
pub fn fail_searches(services: Services, count: Int) -> Nil {
  process.send(services.world, SetSearchFailures(count))
}

pub fn set_search_down(services: Services, down: Bool) -> Nil {
  process.send(services.world, SetSearchDown(down))
}

/// The next read of page `id` never answers.
pub fn stall_page(services: Services, id: String) -> Nil {
  process.send(services.world, StallPage(id))
}

pub fn set_publish_fails(services: Services, fails: Bool) -> Nil {
  process.send(services.world, SetPublishFails(fails))
}

pub fn watch(services: Services, watcher: Subject(Notice)) -> Nil {
  process.send(services.world, Watch(watcher))
}

pub fn counts(services: Services) -> Counts {
  process.call(services.world, 1000, GetCounts)
}

/// The request bodies the scripted provider received for `topic`, oldest
/// first.
pub fn llm_requests(services: Services, topic: String) -> List(String) {
  process.call(services.world, 1000, GetLlmBodies(topic, _))
}

pub fn drafts(services: Services) -> List(#(String, DraftState)) {
  process.call(services.world, 1000, GetDrafts)
}

// The world's state -------------------------------------------------------

fn handle(world: World, message: Message) -> actor.Next(World, Message) {
  let counts = world.counts
  case message {
    SetScript(topic, steps) ->
      actor.continue(
        World(..world, scripts: dict.insert(world.scripts, topic, steps)),
      )
    LlmTurn(topic, step, reply) -> {
      let seen = dict.get(world.hits, #(topic, step)) |> result.unwrap(0)
      let chosen =
        dict.get(world.scripts, topic)
        |> result.unwrap([])
        |> list.drop(step)
        |> list.first
        |> result.unwrap(no_sources("no script for " <> topic))
      let chosen = case chosen {
        StallOnce(_) if seen == 0 -> Stall
        StallOnce(then) -> then
        GarbledOnce(_) if seen == 0 -> Answer("I could not format this.")
        GarbledOnce(then) -> then
        other -> other
      }
      process.send(reply, chosen)
      actor.continue(
        World(
          ..world,
          hits: dict.insert(world.hits, #(topic, step), seen + 1),
          counts: Counts(..counts, llm_calls: counts.llm_calls + 1),
        ),
      )
    }
    Search(reply) -> {
      let counts = Counts(..counts, search_calls: counts.search_calls + 1)
      case world.search_down, world.search_failures {
        True, _ -> {
          process.send(reply, Error(503))
          actor.continue(World(..world, counts:))
        }
        False, failures if failures > 0 -> {
          process.send(reply, Error(503))
          actor.continue(World(..world, counts:, search_failures: failures - 1))
        }
        False, _ -> {
          process.send(reply, Ok(Nil))
          actor.continue(World(..world, counts:))
        }
      }
    }
    SetSearchFailures(count) ->
      actor.continue(World(..world, search_failures: count))
    SetSearchDown(down) -> actor.continue(World(..world, search_down: down))
    PageRead(id, reply) -> {
      let counts = Counts(..counts, page_calls: counts.page_calls + 1)
      let stall = list.contains(world.stalled_pages, id)
      process.send(reply, stall)
      case stall {
        True -> notify(world.watchers, PageStalled(id))
        False -> Nil
      }
      actor.continue(
        World(
          ..world,
          counts:,
          stalled_pages: list.filter(world.stalled_pages, fn(p) { p != id }),
        ),
      )
    }
    StallPage(id) ->
      actor.continue(World(..world, stalled_pages: [id, ..world.stalled_pages]))
    CreateDraft(key, reply) ->
      case dict.get(world.draft_keys, key) {
        Ok(id) -> {
          process.send(reply, id)
          actor.continue(world)
        }
        Error(Nil) -> {
          let id = "draft-" <> int.to_string(dict.size(world.drafts) + 1)
          process.send(reply, id)
          actor.continue(
            World(
              ..world,
              drafts: dict.insert(world.drafts, id, Draft),
              draft_keys: dict.insert(world.draft_keys, key, id),
              counts: Counts(
                ..counts,
                drafts_created: counts.drafts_created + 1,
              ),
            ),
          )
        }
      }
    FindDraft(key, reply) -> {
      process.send(reply, dict.get(world.draft_keys, key) |> option.from_result)
      actor.continue(world)
    }
    UploadBody(id, reply) ->
      case dict.get(world.drafts, id) {
        Ok(Draft) | Ok(BodyUploaded) -> {
          process.send(reply, True)
          actor.continue(
            World(..world, drafts: dict.insert(world.drafts, id, BodyUploaded)),
          )
        }
        _ -> {
          process.send(reply, False)
          actor.continue(world)
        }
      }
    PublishDraft(id, reply) ->
      case world.publish_fails, dict.get(world.drafts, id) {
        True, _ -> {
          process.send(reply, Error(Nil))
          actor.continue(world)
        }
        False, Ok(BodyUploaded) | False, Ok(Live) -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            World(
              ..world,
              drafts: dict.insert(world.drafts, id, Live),
              counts: Counts(..counts, published: counts.published + 1),
            ),
          )
        }
        False, _ -> {
          process.send(reply, Error(Nil))
          actor.continue(world)
        }
      }
    DeleteDraft(id, reply) ->
      case dict.get(world.drafts, id) {
        Ok(Deleted) -> {
          process.send(reply, True)
          actor.continue(world)
        }
        Ok(_) -> {
          process.send(reply, True)
          actor.continue(
            World(
              ..world,
              drafts: dict.insert(world.drafts, id, Deleted),
              counts: Counts(
                ..counts,
                drafts_deleted: counts.drafts_deleted + 1,
              ),
            ),
          )
        }
        Error(Nil) -> {
          process.send(reply, False)
          actor.continue(world)
        }
      }
    SetPublishFails(fails) ->
      actor.continue(World(..world, publish_fails: fails))
    Watch(watcher) ->
      actor.continue(World(..world, watchers: [watcher, ..world.watchers]))
    Notify(notice) -> {
      notify(world.watchers, notice)
      actor.continue(world)
    }
    LlmBody(topic, body) ->
      actor.continue(
        World(
          ..world,
          llm_bodies: dict.upsert(world.llm_bodies, topic, fn(bodies) {
            [body, ..option.unwrap(bodies, [])]
          }),
        ),
      )
    GetLlmBodies(topic, reply) -> {
      process.send(
        reply,
        dict.get(world.llm_bodies, topic) |> result.unwrap([]) |> list.reverse,
      )
      actor.continue(world)
    }
    GetCounts(reply) -> {
      process.send(reply, counts)
      actor.continue(world)
    }
    GetDrafts(reply) -> {
      process.send(reply, dict.to_list(world.drafts))
      actor.continue(world)
    }
  }
}

fn notify(watchers: List(Subject(Notice)), notice: Notice) -> Nil {
  list.each(watchers, process.send(_, notice))
}

// HTTP routing --------------------------------------------------------------

fn route(
  world: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, ["search"] -> search(world, req)
    http.Get, ["pages", id] -> page(world, id)
    http.Post, ["drafts"] -> create_draft(world, req)
    http.Get, ["drafts"] -> find_draft(world, req)
    http.Put, ["drafts", id, "body"] ->
      case process.call(world, 1000, UploadBody(id, _)) {
        True -> text(204, "")
        False -> text(409, "no such draft")
      }
    http.Post, ["drafts", id, "publish"] ->
      case process.call(world, 1000, PublishDraft(id, _)) {
        Ok(Nil) ->
          json_response(
            200,
            json.object([
              #("url", json.string("https://blog.example/" <> id)),
            ]),
          )
        Error(Nil) -> text(500, "publisher unavailable")
      }
    http.Delete, ["drafts", id] ->
      case process.call(world, 1000, DeleteDraft(id, _)) {
        True -> text(204, "")
        False -> text(404, "no such draft")
      }
    http.Post, ["openai", "v1", "responses"] -> llm(world, req)
    _, _ -> text(404, "not found")
  }
}

fn query_param(req: Request(a), name: String) -> String {
  request.get_query(req)
  |> result.unwrap([])
  |> list.key_find(name)
  |> result.unwrap("")
}

fn search(
  world: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let query = query_param(req, "q")
  case process.call(world, 1000, Search) {
    Error(status) -> text(status, "search is down")
    Ok(Nil) -> {
      let base = "http://" <> req.host <> ":" <> port_of(req)
      json_response(
        200,
        json.object([
          #(
            "results",
            json.preprocessed_array([
              json.object([
                #("title", json.string("Notes on " <> query)),
                #("url", json.string(base <> "/pages/" <> query <> "-1")),
              ]),
            ]),
          ),
        ]),
      )
    }
  }
}

fn port_of(req: Request(a)) -> String {
  option.map(req.port, int.to_string) |> option.unwrap("80")
}

fn page(world: Subject(Message), id: String) -> Response(mist.ResponseData) {
  case process.call(world, 1000, PageRead(id, _)) {
    True -> {
      // A page that never answers: the reader is stuck until it is killed.
      process.sleep(30_000)
      text(504, "too late")
    }
    False -> text(200, "Page " <> id <> ": facts worth summarising.")
  }
}

fn create_draft(
  world: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let key = request.get_header(req, "idempotency-key") |> result.unwrap("")
  let id = process.call(world, 1000, CreateDraft(key, _))
  json_response(201, json.object([#("id", json.string(id))]))
}

fn find_draft(
  world: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case process.call(world, 1000, FindDraft(query_param(req, "key"), _)) {
    Some(id) -> json_response(200, json.object([#("id", json.string(id))]))
    None -> text(404, "no draft for key")
  }
}

// The scripted provider -------------------------------------------------

fn llm(
  world: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let body = case mist.read_body(req, 4_194_304) {
    Ok(req) -> bit_array.to_string(req.body) |> result.unwrap("")
    Error(_) -> ""
  }
  let topic = marker(body)
  let step = count(body, "function_call_output")
  process.send(world, LlmBody(topic, body))
  case process.call(world, 1000, LlmTurn(topic, step, _)) {
    CallSearch(query) ->
      sse([
        tool_call(step, "search", json.object([#("query", json.string(query))])),
      ])
    CallRead(url) ->
      sse([tool_call(step, "read", json.object([#("url", json.string(url))]))])
    Answer(text) -> sse([answer(text)])
    Stall -> stall(world, req, topic, step)
    // The world resolves these to the step to play before it replies.
    StallOnce(_) | GarbledOnce(_) -> stall(world, req, topic, step)
  }
}

fn marker(body: String) -> String {
  case string.split_once(body, "[[topic:") {
    Ok(#(_, rest)) ->
      string.split_once(rest, "]]")
      |> result.map(fn(pair) { pair.0 })
      |> result.unwrap("")
    Error(Nil) -> ""
  }
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

/// One scripted reply on the OpenAI Responses wire, with the usage the
/// scripted provider always reports.
fn reply(scripted: testing.Reply) -> String {
  testing.http_response(
    message.OpenAI,
    scripted |> testing.with_usage(message.Usage(120, 40, 160)),
  ).body
}

fn tool_call(step: Int, name: String, arguments: json.Json) -> String {
  reply(
    testing.tool_calls("", [
      testing.ScriptedCall(
        id: "call_" <> int.to_string(step),
        name:,
        arguments_json: json.to_string(arguments),
      ),
    ]),
  )
}

fn answer(text: String) -> String {
  reply(testing.text(text))
}

fn sse(events: List(String)) -> Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(string.concat(events))),
  )
}

type Tick {
  Tick
}

/// Starts an SSE response and keeps it open with comments every 50 ms until
/// a write fails: the client closed the stream.
fn stall(
  world: Subject(Message),
  req: Request(mist.Connection),
  topic: String,
  step: Int,
) -> Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200)
      |> response.set_header("content-type", "text/event-stream"),
    fn(subject) {
      process.send(subject, Tick)
      process.send(world, Notify(LlmStalled(topic, step)))
      subject
    },
    fn(subject, _tick: Tick, connection) {
      case mist.send_chunk(connection, <<": keep-alive\n\n">>) {
        Ok(Nil) -> {
          process.send_after(subject, 50, Tick)
          mist.chunk_continue(subject)
        }
        Error(Nil) -> {
          process.send(world, Notify(LlmStreamClosed(topic, step)))
          mist.chunk_stop()
        }
      }
    },
  )
}

fn text(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_response(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}
