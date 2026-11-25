//// Who the application believes: desk requests act as the validator their
//// bearer token resolves to in the application's own table, and the
//// webhook admits only a body signed with the channel's secret.

import clinic_registration/access
import clinic_registration/app
import clinic_registration/domain
import gleam/bit_array
import gleam/http
import gleam/option.{None}
import support

fn webhook(id: String, phone: String) -> String {
  "{\"id\":\""
  <> id
  <> "\",\"from\":\""
  <> phone
  <> "\",\"profile_name\":\"Ana\",\"text\":\"Oi\"}"
}

/// A header the client writes names nobody: neither the validator nor the
/// decision sets they hold come from the request.
pub fn a_client_written_header_names_no_validator_test() {
  use env <- support.with_app(fn(config) { config })
  let answer =
    support.send(
      env,
      http.Get,
      "/queue",
      [#("x-clinic-validator", "mallory; reception,manager")],
      "",
    )
  assert answer.status == 401
}

/// A webhook body without the channel's signature admits nothing.
pub fn an_unsigned_webhook_admits_nothing_test() {
  use env <- support.with_app(fn(config) { config })
  let id = support.tag("wamid-")
  let answer =
    support.send(env, http.Post, "/inbound", [], webhook(id, support.phone()))
  assert answer.status == 401
  assert support.status_of(env, id) == "absent"
}

/// A body signed with another secret, or changed after it was signed,
/// admits nothing; the same body with the channel's signature is admitted.
pub fn only_the_channels_signature_admits_a_message_test() {
  use env <- support.with_app(fn(config) { config })
  let id = support.tag("wamid-")
  let body = webhook(id, support.phone())
  let assert Ok(other) =
    access.channel_secret("another-channel-secret-000000000000")
  let signed_by = fn(secret, signed_body) {
    [
      #(
        access.signature_header,
        access.sign(secret, bit_array.from_string(signed_body)),
      ),
    ]
  }
  assert support.send(env, http.Post, "/inbound", signed_by(other, body), body).status
    == 401
  assert support.send(
      env,
      http.Post,
      "/inbound",
      signed_by(support.channel(), body <> " "),
      body,
    ).status
    == 401
  assert support.status_of(env, id) == "absent"
  assert support.deliver(env, body).status == 202
}

/// The validator and the sets they hold come from the staff table: the
/// same request is refused for a token the table does not know, and a
/// receptionist's token does not read as the manager's.
pub fn the_staff_table_decides_who_a_token_is_test() {
  use env <- support.with_app(fn(config) { config })
  assert support.call(env, http.Get, "/queue", support.felipe, "").status == 200
  assert support.call(env, http.Get, "/queue", support.felipe <> "x", "").status
    == 401
  let answer =
    support.send(
      env,
      http.Get,
      "/queue",
      [
        #("authorization", "Bearer " <> support.felipe),
        #("x-clinic-validator", "marta; manager"),
      ],
      "",
    )
  assert answer.body == "{\"validator\":\"felipe\",\"cards\":[]}"
}

/// An application configured with no staff and no channel secret, which
/// is the default, refuses every desk request and every delivery.
pub fn nothing_configured_refuses_everything_test() {
  use env <- support.with_app(fn(config) {
    app.Config(..config, staff: access.nobody(), channel: None)
  })
  assert support.call(env, http.Get, "/queue", support.felipe, "").status == 401
  let id = support.tag("wamid-")
  assert support.deliver(env, webhook(id, support.phone())).status == 401
  assert support.status_of(env, id) == "absent"
}

/// Short secrets are refused when the table or the secret is built.
pub fn short_secrets_are_refused_test() {
  let assert Error(_) = access.channel_secret("short")
  let somebody = domain.validator("somebody", [domain.reception])
  let assert Error(_) = access.staff([#("short", somebody)])
  let token = "a-token-of-at-least-thirty-two-bytes"
  let assert Error(_) = access.staff([#(token, somebody), #(token, somebody)])
  let assert Ok(_) = access.staff([#(token, somebody)])
}
