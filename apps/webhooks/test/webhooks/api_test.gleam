//// The tenant API's caller identity: an API key resolves the tenant, and
//// every route acts for that tenant only. Needs DATABASE_URL
//// (../scripts/with-postgres.sh gleam test).

import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import webhooks/receiver
import webhooks/support

fn url_body(url: String) -> String {
  json.object([#("url", json.string(url))]) |> json.to_string
}

pub fn every_route_requires_a_tenant_key_test() {
  use svc <- support.with_service(support.options())
  let routes = [
    #(http.Post, "/subscriptions", url_body("https://hooks.acme.example/h")),
    #(http.Get, "/subscriptions/sub_x", ""),
    #(http.Post, "/events", "{\"type\":\"ping\",\"data\":null}"),
    #(http.Get, "/deliveries/evt_x:sub_x", ""),
  ]
  let unauthenticated = [
    None,
    Some("Bearer whk_not_a_tenant_key"),
    Some("Bearer "),
    // A scheme other than Bearer, carrying a real key.
    Some("Basic " <> support.key("acme")),
    Some(support.key("acme")),
  ]
  list.each(routes, fn(route) {
    list.each(unauthenticated, fn(authorization) {
      let #(status, _) =
        support.call(svc, route.0, route.1, authorization, route.2)
      assert status == 401
    })
  })
}

pub fn body_cannot_name_a_tenant_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()
  // acme's key with a body naming the internal tenant is refused outright,
  // not quietly registered under either tenant.
  let body =
    json.object([
      #("tenant", json.string("ops")),
      #("url", json.string(receiver.url(rx, "/ok"))),
    ])
    |> json.to_string
  let #(status, _) =
    support.call(svc, http.Post, "/subscriptions", support.bearer("acme"), body)
  assert status == 400
  let #(status, _) =
    support.call(
      svc,
      http.Post,
      "/events",
      support.bearer("acme"),
      "{\"tenant\":\"ops\",\"type\":\"ping\",\"data\":null}",
    )
  assert status == 400
}

pub fn a_key_acts_only_for_its_own_tenant_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()
  // acme is a public tenant: its key cannot reach the internal tier's
  // loopback receiver, which ops's key can.
  let assert Error(#(422, _)) =
    support.subscribe(svc, "acme", receiver.url(rx, "/ok"))
  let assert Ok(#(ops_sub, _)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/ok"))
  let assert Ok(#(acme_sub, _)) =
    support.subscribe(svc, "acme", "https://hooks.acme.example/hook")

  // The key decides the subscription's tenant, and reads are scoped to it.
  let tenant_of = fn(caller, id) {
    case
      support.call(
        svc,
        http.Get,
        "/subscriptions/" <> id,
        support.bearer(caller),
        "",
      )
    {
      #(200, body) -> json.parse(body, decode.at(["tenant"], decode.string))
      _ -> Error(json.UnexpectedEndOfInput)
    }
  }
  assert tenant_of("acme", acme_sub) == Ok("acme")
  assert tenant_of("ops", ops_sub) == Ok("ops")
  let #(status, _) =
    support.call(
      svc,
      http.Get,
      "/subscriptions/" <> acme_sub,
      support.bearer("globex"),
      "",
    )
  assert status == 404

  // An event fans out to the caller's subscriptions only.
  let event = "{\"type\":\"ping\",\"id\":\"evt_scope\",\"data\":null}"
  assert support.publish(svc, "globex", event) == []
  let assert [#(acme_delivery, _)] = support.publish(svc, "acme", event)
  assert acme_delivery == "evt_scope:" <> acme_sub
  let assert [#(ops_delivery, _)] = support.publish(svc, "ops", event)
  assert ops_delivery == "evt_scope:" <> ops_sub

  // Delivery reads are scoped the same way.
  let delivery_status = fn(caller, id) {
    support.call(
      svc,
      http.Get,
      "/deliveries/" <> id,
      support.bearer(caller),
      "",
    ).0
  }
  assert delivery_status("acme", acme_delivery) == 200
  assert delivery_status("globex", acme_delivery) == 404
  assert delivery_status("ops", acme_delivery) == 404
}

pub fn event_id_must_match_the_grammar_test() {
  use svc <- support.with_service(support.options())
  let assert Ok(#(sub, _)) =
    support.subscribe(svc, "acme", "https://hooks.acme.example/hook")
  let publish = fn(id: json.Json) {
    json.object([
      #("type", json.string("ping")),
      #("id", id),
      #("data", json.null()),
    ])
    |> json.to_string
    |> support.call(svc, http.Post, "/events", support.bearer("acme"), _)
  }
  list.each(
    [
      "",
      "evt:1",
      "evt 1",
      "evt\n1",
      "évt",
      "evt/1",
      "evt.1",
      string.repeat("e", 65),
    ],
    fn(id) {
      let #(status, _) = publish(json.string(id))
      assert status == 400
    },
  )
  let #(status, _) = publish(json.int(7))
  assert status == 400
  // The longest accepted id, and the full alphabet.
  let longest = string.repeat("e", 64)
  let #(status, body) = publish(json.string(longest))
  assert status == 202
  assert support.deliveries(body) |> list.map(fn(d) { d.0 })
    == [longest <> ":" <> sub]
  let #(status, _) = publish(json.string("Evt_09-az"))
  assert status == 202
  // Without an id the server generates one and returns it.
  let #(status, body) =
    support.call(
      svc,
      http.Post,
      "/events",
      support.bearer("acme"),
      "{\"type\":\"ping\",\"data\":null}",
    )
  assert status == 202
  let assert Ok(generated) =
    json.parse(body, decode.at(["event_id"], decode.string))
  assert string.starts_with(generated, "evt_")
}
