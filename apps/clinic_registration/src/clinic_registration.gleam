//// `gleam run` (with DATABASE_URL set, e.g. through
//// ../scripts/with-postgres.sh): one registration from Ana's message to
//// her confirmation. The model and the messaging provider are scripted on
//// loopback; the desk is the application's own HTTP API.

import clinic_registration/app.{type App}
import clinic_registration/domain
import clinic_registration/jobs
import clinic_registration/scripted
import clinic_registration/store
import clinic_registration/telemetry
import decisions
import decisions/entry
import decisions/occurrence
import decisions/policy
import decisions/vocabulary.{Performed}
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/config
import http_gun/destination
import json/blueprint/codec
import wisp

pub fn main() -> Nil {
  case envoy.get("DATABASE_URL") {
    Error(Nil) ->
      io.println(
        "DATABASE_URL is not set. Run: ../scripts/with-postgres.sh gleam run",
      )
    Ok(url) ->
      case run(url) {
        Ok(Nil) -> Nil
        Error(reason) -> io.println("clinic_registration failed: " <> reason)
      }
  }
}

const ana_phone = "+5511987654321"

const ana_says =
  "Oi! Queria marcar uma consulta com a Dra. Paula. Sou Ana Souza, nasci em 12/04/1990, tenho Unimed Flex. Pode me cadastrar."

const felipe = "felipe; reception"

pub fn run(url: String) -> Result(Nil, String) {
  wisp.set_logger_level(wisp.ErrorLevel)
  use services <- result.try(scripted.start())
  use clinic <- result.try(
    app.start(app.default_config(
      database_url: url,
      llm_base: scripted.llm_base(services),
      messaging_base: scripted.messaging_base(services),
      provider_ports: scripted.ports(services),
    )),
  )
  let assert Ok(client) =
    http_gun.start(
      config.default() |> config.with_destination(destination.loopback_only()),
    )
  list.each(["Bradesco Saúde", "SulAmérica", "Unimed"], fn(name) {
    let _ = store.accept_insurer(clinic.db, name)
  })
  // The model reads "12/04" as the 4th of December, a little unsure.
  scripted.script(services, ana_phone, [
    scripted.Answer(scripted.extraction(
      name: "Ana Souza",
      birth_date: Some("1990-12-04"),
      phone: ana_phone,
      insurer: Some("Unimed"),
      plan: Some("Unimed Flex"),
      confidence: 0.81,
    )),
  ])
  let outcome = narrate(clinic, client, services)
  http_gun.stop(client)
  app.stop(clinic)
  scripted.stop(services)
  outcome
}

fn narrate(
  clinic: App,
  client: http_gun.Client,
  services: scripted.Services,
) -> Result(Nil, String) {
  let message_id = "wamid." <> wisp.random_string(12)
  let key = domain.key(message_id)
  io.println("Ana writes to Clínica X on the messaging channel:")
  io.println("  \"" <> ana_says <> "\"")
  let webhook =
    json.object([
      #("id", json.string(message_id)),
      #("from", json.string(ana_phone)),
      #("profile_name", json.string("Ana")),
      #("text", json.string(ana_says)),
    ])
    |> json.to_string
  use #(status, _) <- result.try(call(
    clinic,
    client,
    http.Post,
    "/inbound",
    "",
    webhook,
  ))
  io.println("POST /inbound -> " <> int.to_string(status))
  use #(status, _) <- result.try(call(
    clinic,
    client,
    http.Post,
    "/inbound",
    "",
    webhook,
  ))
  io.println(
    "POST /inbound again (the channel delivers at least once) -> "
    <> int.to_string(status)
    <> ", nothing admitted",
  )

  use waiting <- result.try(
    await(clinic, key, fn(known) {
      occurrence.status_name(known.status) == "awaiting"
    }),
  )
  io.println(
    "\nThe model recommended a registration; policy v"
    <> int.to_string(option.unwrap(waiting.policy_version, 0))
    <> " asks reception.",
  )
  use #(_, queue) <- result.try(call(
    clinic,
    client,
    http.Get,
    "/queue",
    felipe,
    "",
  ))
  let cards =
    json.parse(
      queue,
      decode.at(
        ["cards"],
        decode.list(decode.at(["occurrence"], decode.string)),
      ),
    )
    |> result.unwrap([])
  io.println(
    "GET /queue as Felipe -> "
    <> int.to_string(list.length(cards))
    <> " card(s)",
  )

  use #(_, card) <- result.try(call(
    clinic,
    client,
    http.Post,
    "/cards/" <> waiting.id <> "/open",
    felipe,
    "",
  ))
  io.println(
    "\nPOST /cards/" <> waiting.id <> "/open: the card as Felipe sees it",
  )
  io.println(render_card(card))
  let seen =
    json.parse(card, decode.at(["card", "seen"], decode.int))
    |> result.unwrap(0)

  io.println(
    "\nFelipe sees that Ana wrote 12/04, the 12th of April, and corrects the birth date.",
  )
  let verdict =
    json.object([
      #("seen", json.int(seen)),
      #(
        "verdict",
        json.object([
          #("t", json.string("correct")),
          #(
            "reason",
            json.object([
              #("category", json.string("wrong_field")),
              #("note", json.string("the patient writes dd/mm")),
            ]),
          ),
          #(
            "output",
            domain.registration_codec()
              |> encode(domain.Registration(
                name: "Ana Souza",
                birth_date: Some("1990-04-12"),
                phone: ana_phone,
                coverage: Some(domain.Coverage("Unimed", "Unimed Flex")),
                consent: True,
              )),
          ),
        ]),
      ),
    ])
    |> json.to_string
  use #(status, body) <- result.try(call(
    clinic,
    client,
    http.Post,
    "/cards/" <> waiting.id <> "/verdict",
    felipe,
    verdict,
  ))
  io.println(
    "POST /cards/"
    <> waiting.id
    <> "/verdict -> "
    <> int.to_string(status)
    <> " "
    <> body,
  )

  case store.patients_with_phone(clinic.db, ana_phone) {
    Ok([patient]) ->
      io.println(
        "Patient row, written in Felipe's verdict's transaction: "
        <> patient.name
        <> ", born "
        <> patient.birth_date
        <> ", registered by "
        <> patient.registered_by,
      )
    _ -> io.println("No patient row (unexpected).")
  }

  use done <- result.try(
    await(clinic, key, fn(known) {
      case occurrence.effect(known) {
        Some(Performed(_)) -> True
        _ -> False
      }
    }),
  )
  case list.find(scripted.sent(services), fn(sent) { sent.to == ana_phone }) {
    Ok(sent) ->
      io.println(
        "\nAna receives ("
        <> sent.id
        <> ", idempotency key "
        <> sent.key
        <> "):\n  \""
        <> sent.text
        <> "\"",
      )
    Error(Nil) -> io.println("\nNothing was sent (unexpected).")
  }

  io.println(
    "\nWhat happened: "
    <> describe_account(occurrence.account(done))
    <> ", decided by "
    <> case occurrence.decided_by(done) {
      Some(occurrence.APerson(subject:)) -> subject
      Some(occurrence.ThePolicy(version:)) ->
        "policy v" <> int.to_string(version)
      None -> "nobody"
    },
  )
  io.println("\nThe record of " <> done.id <> ":")
  list.each(done.entries, fn(e) {
    io.println(
      "  "
      <> int.to_string(e.seq)
      <> ". "
      <> entry.kind(e.event)
      <> describe_entry(e.event),
    )
  })
  io.println("\nTelemetry:")
  process.sleep(100)
  list.each(telemetry.lines(clinic.collector), fn(line) {
    io.println("  " <> line)
  })
  Ok(Nil)
}

fn call(
  clinic: App,
  client: http_gun.Client,
  method: http.Method,
  path: String,
  validator: String,
  body: String,
) -> Result(#(Int, String), String) {
  let assert Ok(req) = request.to(app.base_url(clinic) <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  let req = case validator {
    "" -> req
    validator -> request.set_header(req, "x-clinic-validator", validator)
  }
  http_gun.send(client, req)
  |> result.map(fn(reply) {
    #(
      reply.response.status,
      bit_array.to_string(reply.response.body) |> result.unwrap(""),
    )
  })
  |> result.map_error(string.inspect)
}

/// Wait until the occurrence under `key` satisfies `ready`.
fn await(
  clinic: App,
  key: String,
  ready: fn(occurrence.Occurrence(domain.Registration)) -> Bool,
) -> Result(occurrence.Occurrence(domain.Registration), String) {
  await_loop(clinic, key, ready, 200)
}

fn await_loop(
  clinic: App,
  key: String,
  ready: fn(occurrence.Occurrence(domain.Registration)) -> Bool,
  tries: Int,
) -> Result(occurrence.Occurrence(domain.Registration), String) {
  case decisions.read(clinic.desk, clinic.db, occurrence: key) {
    Ok(known) ->
      case ready(known) {
        True -> Ok(known)
        False -> retry(clinic, key, ready, tries)
      }
    Error(_) -> retry(clinic, key, ready, tries)
  }
}

fn retry(
  clinic: App,
  key: String,
  ready: fn(occurrence.Occurrence(domain.Registration)) -> Bool,
  tries: Int,
) -> Result(occurrence.Occurrence(domain.Registration), String) {
  case tries {
    0 -> Error("the registration did not get there in time")
    _ -> {
      process.sleep(50)
      await_loop(clinic, key, ready, tries - 1)
    }
  }
}

fn encode(codec: codec.Codec(a), value: a) -> json.Json {
  codec.to_json(codec, value) |> result.unwrap(json.null())
}

/// The card document as a page a receptionist reads.
pub fn render_card(card: String) -> String {
  let lines =
    texts(
      card,
      ["context", "conversation", "lines"],
      decode.at(["text"], decode.string),
    )
  let similar =
    texts(
      card,
      ["context", "similar_patients"],
      decode.at(["name"], decode.string),
    )
  let insurers = texts(card, ["context", "accepted_insurers"], decode.string)
  let signals =
    texts(card, ["card", "recommendation", "signals"], {
      use name <- decode.field("name", decode.string)
      use value <- decode.subfield(
        ["fact", "v"],
        decode.one_of(decode.map(decode.float, float.to_string), [
          decode.map(decode.bool, fn(flag) {
            case flag {
              True -> "yes"
              False -> "no"
            }
          }),
          decode.map(decode.int, int.to_string),
        ]),
      )
      decode.success(name <> " " <> value)
    })
  let standing = fn(field) {
    optional_text(card, ["card", "standing_output", field])
  }
  let coverage = case
    at(
      card,
      ["card", "standing_output", "coverage"],
      decode.optional({
        use insurer <- decode.field("insurer", decode.string)
        use plan <- decode.field("plan", decode.string)
        decode.success(insurer <> ", " <> plan)
      }),
      None,
    )
  {
    Some(coverage) -> coverage
    None -> "pays privately"
  }
  let by = texts(card, ["card", "approvals", "by"], decode.string)
  // One line per way the occurrence can be accepted: its decision sets,
  // and how many of the approvals it needs it has.
  let alternatives =
    texts(card, ["card", "approvals", "alternatives"], {
      use sets <- decode.field("sets", decode.list(decode.string))
      use have <- decode.field("have", decode.int)
      use need <- decode.field("need", decode.int)
      decode.success(
        string.join(sets, " or ")
        <> " "
        <> int.to_string(have)
        <> " of "
        <> int.to_string(need),
      )
    })
  [
    "  ┌ Registration " <> text(card, ["card", "occurrence"]),
    "  │ status "
      <> text(card, ["card", "status"])
      <> ", waiting for "
      <> string.join(
      texts(card, ["card", "waiting_for"], decode.string),
      " or ",
    ),
    "  │ Conversation with "
      <> text(card, ["context", "conversation", "profile_name"])
      <> " ("
      <> text(card, ["context", "conversation", "contact"])
      <> "):",
    ..list.map(lines, fn(line) { "  │   " <> line })
  ]
  |> list.append([
    "  │ Patients with a similar name or phone: "
      <> case similar {
      [] -> "none"
      names -> string.join(names, ", ")
    },
    "  │ Insurers the clinic accepts: " <> string.join(insurers, ", "),
    "  │ The model recommends ("
      <> text(card, ["card", "recommendation", "by", "name"])
      <> " v"
      <> text(card, ["card", "recommendation", "by", "version"])
      <> "):",
    "  │   name        " <> standing("name"),
    "  │   birth date  " <> standing("birth_date"),
    "  │   phone       " <> standing("phone"),
    "  │   coverage    " <> coverage,
    "  │   consent     "
      <> case
      at(card, ["card", "standing_output", "consent"], decode.bool, False)
    {
      True -> "given"
      False -> "not given"
    },
    "  │ Signals: " <> string.join(signals, "; "),
    "  │ Approved by: "
      <> case by {
      [] -> "nobody yet"
      names -> string.join(names, ", ")
    }
      <> " ("
      <> string.join(alternatives, "; ")
      <> ")",
    "  │ Verdicts: "
      <> string.join(texts(card, ["card", "verdicts"], decode.string), ", "),
    "  └ ticket: occurrence "
      <> text(card, ["card", "occurrence"])
      <> ", seen "
      <> int.to_string(at(card, ["card", "seen"], decode.int, 0)),
  ])
  |> string.join("\n")
}

fn at(
  card: String,
  path: List(String),
  decoder: decode.Decoder(a),
  default: a,
) -> a {
  json.parse(card, decode.at(path, decoder)) |> result.unwrap(default)
}

fn text(card: String, path: List(String)) -> String {
  at(card, path, decode.string, "")
}

fn texts(
  card: String,
  path: List(String),
  inner: decode.Decoder(a),
) -> List(a) {
  at(card, path, decode.list(inner), [])
}

fn optional_text(card: String, path: List(String)) -> String {
  case at(card, path, decode.optional(decode.string), None) {
    Some(value) -> value
    None -> "(not found)"
  }
}

fn describe_entry(event: entry.Event(domain.Registration)) -> String {
  case event {
    entry.Recommended(recommendation:, ..) ->
      ": by " <> describe_recommender(recommendation.by)
    entry.PolicyApplied(version:, outcome:, ..) ->
      ": version "
      <> int.to_string(version)
      <> " says "
      <> describe_outcome(outcome)
    entry.Opened(by:, ..) -> ": shown to " <> by
    entry.Decided(by:, verdict:, ..) ->
      ": " <> by <> " " <> describe_verdict(verdict)
    entry.Released(tool:, relied:, ..) ->
      ": to "
      <> tool
      <> ", relying on "
      <> string.join(
        list.map(relied, fn(ref) {
          ref.kind <> "(" <> ref.id <> ")=" <> ref.revision
        }),
        ", ",
      )
    entry.Effected(effect:) -> ": " <> jobs.describe_effect(effect)
    _ -> ""
  }
}

fn describe_account(
  account: occurrence.Account(domain.Registration),
) -> String {
  case account {
    occurrence.Done(final:, effect: Some(effect), ..) ->
      final.name <> " registered; confirmation " <> jobs.describe_effect(effect)
    occurrence.Done(final:, effect: None, ..) ->
      final.name <> " registered; confirmation not known yet"
    occurrence.Undecided -> "not decided yet"
    occurrence.TurnedDown(by:, reason:) ->
      "turned down by " <> by <> " (" <> reason.category <> ")"
    occurrence.Lapsed(..) -> "lapsed"
    occurrence.TakenBack(by:) -> "taken back by " <> by
    occurrence.Blocked(reason:) -> "blocked: " <> reason
  }
}

fn describe_recommender(by: vocabulary.Recommender) -> String {
  case by {
    vocabulary.ModelCall(configuration:, version:) ->
      configuration <> " v" <> version
    _ -> string.inspect(by)
  }
}

fn describe_outcome(outcome: policy.Outcome) -> String {
  case outcome {
    policy.Ask(eligible) -> "ask " <> string.join(policy.sets(eligible), " or ")
    policy.Proceed(..) -> "proceed"
    policy.Consult(point:) -> "consult " <> point
  }
}

fn describe_verdict(
  verdict: vocabulary.Verdict(domain.Registration),
) -> String {
  case verdict {
    vocabulary.Approve -> "approved"
    vocabulary.Reject(reason:) -> "rejected (" <> reason.category <> ")"
    vocabulary.Correct(reason:, ..) -> "corrected (" <> reason.category <> ")"
  }
}
