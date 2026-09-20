// THROWAWAY: Can two OIDC login tabs retain issuer-bound callback transactions?
import lab/warden_transaction as login

pub fn probe() -> Nil {
  let now = timestamp(100)
  let expiry = timestamp(150)
  let issuer_a = must(login.issuer("https://issuer-a.example"))
  let issuer_b = must(login.issuer("https://issuer-b.example"))
  let client_a =
    login.client(
      issuer_a,
      must(login.client_id("client-a")),
      must(login.redirect_uri("https://app.example/callback")),
    )
  let client_b =
    login.client(
      issuer_b,
      must(login.client_id("client-b")),
      must(login.redirect_uri("https://app.example/callback")),
    )
  let state_a = must(login.state("state-tab-a"))
  let state_b = must(login.state("state-tab-b"))
  let material_a =
    material("state-tab-a", "nonce-a", "verifier-a", "challenge-a")
  let material_b =
    material("state-tab-b", "nonce-b", "verifier-b", "challenge-b")
  let assert Ok(#(request_a, transaction_a)) =
    login.plan_login(
      client_a,
      must(login.transaction_id("tx-a")),
      material_a,
      now,
      expiry,
    )
  let assert Ok(#(request_b, transaction_b)) =
    login.plan_login(
      client_b,
      must(login.transaction_id("tx-b")),
      material_b,
      now,
      expiry,
    )

  let login.AuthorizationRequest(
    request_issuer,
    _,
    _,
    request_state,
    request_nonce,
    request_pkce,
  ) = request_a
  let issuer_matches = request_issuer == issuer_a
  let state_matches = request_state == state_a
  let nonce_matches = request_nonce == must(login.nonce("nonce-a"))
  let pkce_is_injected =
    request_pkce == must(login.pkce_challenge("challenge-a"))
  let assert True = issuer_matches
  let assert True = state_matches
  let assert True = nonce_matches
  let assert True = pkce_is_injected

  let login.AuthorizationRequest(request_issuer_b, _, _, request_state_b, _, _) =
    request_b
  let callback_b =
    login.Callback(
      request_issuer_b,
      request_state_b,
      login.AuthorizationCodeReceived("code-b"),
    )
  let assert Error(login.StateMismatch) =
    login.check_callback(transaction_a, callback_b, now)
  let callback_wrong_issuer =
    login.Callback(issuer_b, state_a, login.AuthorizationCodeReceived("code-a"))
  let assert Error(login.IssuerMismatch) =
    login.check_callback(transaction_a, callback_wrong_issuer, now)

  let callback_a =
    login.Callback(issuer_a, state_a, login.AuthorizationCodeReceived("code-a"))
  let assert Error(login.StateMismatch) =
    login.check_callback(transaction_b, callback_a, now)
  let assert Error(login.TransactionExpired) =
    login.check_callback(transaction_a, callback_a, timestamp(150))
  let missing_code =
    login.Callback(issuer_a, state_a, login.CallbackWithoutCode)
  let assert Error(login.AuthorizationCodeMissing) =
    login.check_callback(transaction_a, missing_code, now)
  let assert Error(login.ExpirationMustBeInTheFuture) =
    login.plan_login(
      client_a,
      must(login.transaction_id("expired")),
      material_a,
      now,
      now,
    )

  let assert Ok(_) = login.check_callback(transaction_b, callback_b, now)
  let assert Error(login.AuthorizationCodeEmpty) =
    login.check_callback(
      transaction_a,
      login.Callback(issuer_a, state_a, login.AuthorizationCodeReceived("")),
      now,
    )
  let assert Error(login.ProviderRejected("access_denied")) =
    login.check_callback(
      transaction_a,
      login.Callback(issuer_a, state_a, login.CallbackRejected("access_denied")),
      now,
    )
  // A checked transaction is copyable: atomic consumption is a separate gate.
  let assert Ok(_) = login.check_callback(transaction_a, callback_a, now)
  let assert Ok(_) = login.check_callback(transaction_a, callback_a, now)

  // This is only the checked input to a future token-exchange boundary.
  let assert Ok(_checked) =
    checked_exchange_input(transaction_a, callback_a, now)
  Nil
}

pub fn checked_exchange_input(
  transaction: login.Transaction,
  callback: login.Callback,
  now: login.Timestamp,
) -> Result(login.CheckedCallback, login.CallbackCheckError) {
  login.check_callback(transaction, callback, now)
}

fn material(
  state: String,
  nonce: String,
  verifier: String,
  challenge: String,
) -> login.LoginMaterial {
  login.LoginMaterial(
    must(login.state(state)),
    must(login.nonce(nonce)),
    must(login.pkce_verifier(verifier)),
    must(login.pkce_challenge(challenge)),
  )
}

fn timestamp(value: Int) -> login.Timestamp {
  must(login.timestamp(value))
}

fn must(value: Result(a, login.InputError)) -> a {
  let assert Ok(checked) = value
  checked
}
