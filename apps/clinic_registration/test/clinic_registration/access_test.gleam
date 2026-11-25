//// Who the application believes: desk requests act as the validator the
//// staff table names for the subject of a verified sign-in, and the
//// webhook admits only a body signed with the channel's secret.

import clinic_registration/access
import clinic_registration/app
import clinic_registration/domain
import clinic_registration/scripted
import gleam/bit_array
import gleam/dict
import gleam/http
import gleam/option.{None}
import gleam/string
import hellhound/testing as identity
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

/// A member of staff signs in through the clinic's OpenID provider, and the
/// desk then acts as the validator the staff table names for their verified
/// subject. A header the client writes changes nothing.
pub fn a_signed_in_member_of_staff_uses_the_desk_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Ok(cookie) =
    scripted.sign_in(env.services, app.base_url(env.app), "felipe")
  let answer =
    support.send(
      env,
      http.Get,
      "/queue",
      [#("cookie", cookie), #("x-clinic-validator", "marta; manager")],
      "",
    )
  assert answer.status == 200
  assert answer.body == "{\"validator\":\"felipe\",\"cards\":[]}"
}

/// A person the provider verifies but the staff table does not name gets
/// no desk session: the callback answers 403 and sets no cookie.
pub fn a_verified_sign_in_that_is_not_staff_gets_no_session_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Error(reason) =
    scripted.sign_in(env.services, app.base_url(env.app), "mallory")
  assert string.contains(reason, "/auth/callback")
  assert string.contains(reason, "answered 403")
  let requests = identity.requests(scripted.identity_provider(env.services))
  assert requests.active_refresh_tokens == 3
}

/// Signing out ends the session at Hellhound: the same cookie, sent again,
/// opens nothing.
pub fn signing_out_ends_the_session_test() {
  use env <- support.with_app(fn(config) { config })
  assert support.call(env, http.Get, "/queue", support.bia, "").status == 200
  assert support.call(env, http.Post, "/logout", support.bia, "").status == 204
  assert support.call(env, http.Get, "/queue", support.bia, "").status == 401
  assert support.call(env, http.Get, "/queue", support.felipe, "").status == 200
}

/// A request from another site that carries the desk cookie is refused,
/// and one with no origin at all is served without its cookie.
pub fn a_cross_site_request_cannot_use_the_desk_cookie_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Ok(cookie) = dict.get(env.sessions, support.marta)
  let from = fn(origin) {
    support.send(env, http.Post, "/logout", [#("cookie", cookie), ..origin], "")
  }
  assert from([#("origin", "https://elsewhere.example")]).status == 400
  // Without an origin the cookie is dropped, so this signs nobody out.
  assert from([]).status == 204
  assert support.call(env, http.Get, "/queue", support.marta, "").status == 200
}

/// An application configured with no sign-in and no channel secret, which
/// is the default, refuses every desk request and every delivery.
pub fn nothing_configured_refuses_everything_test() {
  use env <- support.with_app(fn(config) {
    app.Config(..config, sign_in: None, channel: None)
  })
  assert support.call(env, http.Get, "/login", "", "").status == 503
  assert support.call(env, http.Get, "/queue", support.felipe, "").status == 401
  let id = support.tag("wamid-")
  assert support.deliver(env, webhook(id, support.phone())).status == 401
  assert support.status_of(env, id) == "absent"
}

/// A short channel secret, or a staff table naming one subject twice, is
/// refused when it is built.
pub fn bad_configuration_is_refused_test() {
  let assert Error(_) = access.channel_secret("short")
  let somebody = domain.validator("somebody", [domain.reception])
  let member =
    access.Member(issuer: "https://idp.test", subject: "s", acts_as: somebody)
  let assert Error(_) = access.staff([member, member])
  let assert Ok(_) = access.staff([member])
}
