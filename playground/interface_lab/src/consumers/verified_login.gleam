// THROWAWAY: Does one owner consume the callback before issuing verified identity?
import consumers/request_scoped_tools
import lab/fabric
import lab/relay
import lab/value
import lab/warden
import lab/warden_transaction as login

pub fn probe() -> Nil {
  let expected_issuer = must(login.issuer("https://login.example"))
  let expected_client_id = must(login.client_id("client-sentinel"))
  let expected_redirect =
    must(login.redirect_uri("https://app.example/return-sentinel"))
  let configured_client =
    login.client(expected_issuer, expected_client_id, expected_redirect)
  let expected_state = must(login.state("state-sentinel"))
  let expected_nonce = must(login.nonce("nonce-sentinel"))
  let expected_verifier = must(login.pkce_verifier("verifier-sentinel"))
  let material =
    login.LoginMaterial(
      expected_state,
      expected_nonce,
      expected_verifier,
      must(login.pkce_challenge("challenge-sentinel")),
    )
  let transaction_id = must(login.transaction_id("transaction-sentinel"))
  let initial_revision = revision("checked-revision")
  let assert Ok(#(_, transaction)) =
    login.plan_login(
      configured_client,
      transaction_id,
      material,
      timestamp(10),
      timestamp(100),
    )
  let pending = login.trusted_rehydrate_pending(transaction, initial_revision)
  let callback =
    login.Callback(
      expected_issuer,
      expected_state,
      login.AuthorizationCodeReceived("authorization-code-sentinel"),
    )
  let assert Ok(checked) = login.check_callback(pending, callback)

  let backend =
    login.trust_adapter(
      configured_client,
      test_declaration("scripted-success"),
      fn(request) {
        let assert login.ExchangeParameters(
          "https://login.example",
          "client-sentinel",
          "https://app.example/return-sentinel",
          "authorization-code-sentinel",
          "nonce-sentinel",
          "verifier-sentinel",
          login.VerificationProfile(
            True,
            True,
            login.ExactSingletonClient,
            True,
          ),
        ) = login.exchange_parameters(request)
        Ok(
          successful_attestation(login.BackendAttestation(
            expected_issuer,
            [expected_client_id],
            login.NoAuthorizedParty,
            "subject-sentinel",
          )),
        )
      },
    )
  let success_store =
    consuming_store(
      transaction,
      transaction_id,
      initial_revision,
      timestamp(99),
    )
  let assert Ok(login.LoginCompleted(session)) =
    warden.complete_login(success_store, backend, fixture_owner(), checked)
  let verified = warden.identity(session)
  let assert "subject-sentinel" = warden.subject(verified)
  let assert #(actual_issuer, "subject-sentinel") =
    warden.identity_key(verified)
  let assert True = actual_issuer == expected_issuer

  // Both request-scoped protocol tools capture the verified identity and run
  // their ordinary handler with the same tenant authorization policy.
  let context =
    request_scoped_tools.RequestContext(
      request_scoped_tools.tenant_id("tenant-sentinel"),
      verified,
    )
  let registries = request_scoped_tools.registries(context, allow_request)
  let assert request_scoped_tools.ToolRegistries([relay_tool], [fabric_tool]) =
    registries
  let request =
    value.Object([
      #("order_id", value.Text("order-sentinel")),
      #("tenant_id", value.Text("tenant-sentinel")),
    ])
  let assert Ok(value.Object([#("summary", value.Text(summary))])) =
    relay.invoke(relay_tool, request)
  let assert "tenant=tenant-sentinel; order=order-sentinel; requester=subject-sentinel" =
    summary
  let assert Ok(value.Object([#("summary", value.Text(fabric_summary))])) =
    fabric.invoke(fabric_tool, request)
  let assert True = summary == fabric_summary

  // Full client equality, including redirect URI, is checked before storage.
  let wrong_redirect_client =
    login.client(
      expected_issuer,
      expected_client_id,
      must(login.redirect_uri("https://app.example/wrong-return")),
    )
  let wrong_backend =
    login.trust_adapter(
      wrong_redirect_client,
      test_declaration("wrong-client"),
      panic_exchange,
    )
  let assert Error(login.BackendConfigurationMismatch) =
    complete_session(panic_store(), wrong_backend, checked)
  let wrong_client_id_config =
    login.client(
      expected_issuer,
      must(login.client_id("wrong-client-sentinel")),
      expected_redirect,
    )
  let wrong_client_id_backend =
    login.trust_adapter(
      wrong_client_id_config,
      test_declaration("wrong-client-id"),
      panic_exchange,
    )
  let assert Error(login.BackendConfigurationMismatch) =
    complete_session(panic_store(), wrong_client_id_backend, checked)

  // Correctly bound denial is terminal and never invokes the backend.
  let denied_outcome =
    checked_outcome(
      pending,
      login.Callback(
        expected_issuer,
        expected_state,
        login.CallbackRejected("access_denied"),
      ),
    )
  let denial_backend =
    login.trust_adapter(
      configured_client,
      test_declaration("denial-backend-must-not-run"),
      panic_exchange,
    )
  let assert Error(login.ProviderRejection(login.AccessDenied)) =
    complete_session(
      consuming_store(
        transaction,
        transaction_id,
        initial_revision,
        timestamp(99),
      ),
      denial_backend,
      denied_outcome,
    )
  let assert Error(login.BackendConfigurationMismatch) =
    complete_session(panic_store(), wrong_client_id_backend, denied_outcome)

  // Storage failures and callback preflight errors also prevent exchange.
  expect_store_failure(
    configured_client,
    checked,
    login.Missing,
    login.TransactionMissing,
  )
  expect_store_failure(
    configured_client,
    checked,
    login.Unavailable(login.StoreUnavailableCode),
    login.StoreUnavailable(login.StoreUnavailableCode),
  )
  expect_store_failure(
    configured_client,
    checked,
    login.CommitUnknown,
    login.CommitOutcomeUnknown,
  )
  expect_store_failure(
    configured_client,
    checked,
    login.Decided(login.ExpiredDuringConsume),
    login.TransactionExpired,
  )
  expect_store_failure(
    configured_client,
    checked,
    login.Decided(login.AlreadyConsumed),
    login.CallbackAlreadyConsumed,
  )
  expect_store_failure(
    configured_client,
    checked,
    login.Decided(login.ChangedSinceCheck),
    login.TransactionChanged,
  )

  // The binding policy accepts only the exact issuer, singleton audience,
  // matching optional authorized party, and a nonempty subject.
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      must(login.issuer("https://wrong-issuer.example")),
      [expected_client_id],
      login.NoAuthorizedParty,
      "subject",
    ),
    login.AttestedIssuerMismatch,
  )
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      expected_issuer,
      [],
      login.NoAuthorizedParty,
      "subject",
    ),
    login.AttestedAudienceMismatch,
  )
  let other_client_id = must(login.client_id("other-client"))
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      expected_issuer,
      [expected_client_id, other_client_id],
      login.NoAuthorizedParty,
      "subject",
    ),
    login.AttestedAudienceMismatch,
  )
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      expected_issuer,
      [expected_client_id, expected_client_id],
      login.NoAuthorizedParty,
      "subject",
    ),
    login.AttestedAudienceMismatch,
  )
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      expected_issuer,
      [expected_client_id],
      login.AuthorizedParty(other_client_id),
      "subject",
    ),
    login.AuthorizedPartyMismatch,
  )
  expect_attestation_error(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendAttestation(
      expected_issuer,
      [expected_client_id],
      login.NoAuthorizedParty,
      "",
    ),
    login.SubjectMissing,
  )

  let matching_azp_backend =
    login.trust_adapter(
      configured_client,
      test_declaration("matching-azp"),
      fn(_request) {
        Ok(
          successful_attestation(login.BackendAttestation(
            expected_issuer,
            [expected_client_id],
            login.AuthorizedParty(expected_client_id),
            "subject-with-azp",
          )),
        )
      },
    )
  let assert Ok(matching_azp_session) =
    complete_session(
      consuming_store(
        transaction,
        transaction_id,
        initial_revision,
        timestamp(99),
      ),
      matching_azp_backend,
      checked,
    )
  let assert "subject-with-azp" =
    warden.subject(warden.identity(matching_azp_session))

  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.ExchangeRejected,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.ExchangeOutcomeUnknown,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.MissingIdToken,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.InvalidSignature,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.InvalidNonce,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.InvalidTokenTime,
  )
  expect_backend_failure(
    configured_client,
    transaction,
    transaction_id,
    initial_revision,
    checked,
    login.BackendUnmapped,
  )

  // Derive the terminal row from the same pure transition. The fixture does
  // not persist it or mutate captured copies of the pending row.
  let assert #(terminal_after_consume, login.WasConsumed) =
    login.decide_consume(pending, login.consume_command(checked), timestamp(99))
  let assert login.ConsumedStatus = login.stored_status(terminal_after_consume)
  let terminal_store = replay_store(terminal_after_consume)
  let assert Error(login.ConsumptionFailed(login.CallbackAlreadyConsumed)) =
    complete_session(terminal_store, denial_backend, checked)
  Nil
}

fn checked_outcome(
  pending: login.StoredTransaction,
  callback: login.Callback,
) -> login.CheckedOutcome {
  let assert Ok(checked) = login.check_callback(pending, callback)
  checked
}

fn complete_session(
  store: login.TransactionStore,
  backend: login.VerificationBackend,
  checked: login.CheckedOutcome,
) -> Result(login.Session, login.CompleteLoginError) {
  case login.complete_login(store, backend, fixture_owner(), checked) {
    Ok(login.LoginCompleted(session)) -> Ok(session)
    Ok(login.LoginRecoveryRequired(_)) ->
      panic as "the scripted custody port must confirm installation"
    Error(error) -> Error(error)
  }
}

fn fixture_owner() -> login.CustodyOwner {
  login.custody_owner(
    must(login.custody_owner_id("custody-owner-sentinel")),
    fn(command) {
      login.custody_installed(
        command,
        must(login.custody_reference("session-reference-sentinel")),
        must(login.custody_revision("session-revision-sentinel")),
      )
    },
    fn(recovery) {
      login.custody_installed(
        login.recovery_custody_command(recovery),
        must(login.custody_reference("session-reference-sentinel")),
        must(login.custody_revision("session-revision-sentinel")),
      )
    },
  )
}

fn successful_attestation(
  identity: login.BackendAttestation,
) -> login.LoginAttestation {
  let tokens =
    login.token_material(
      must(login.access_token("access-token-sentinel")),
      login.RefreshTokenPresent(
        must(login.refresh_token("refresh-token-sentinel")),
      ),
      login.LogoutIdTokenPresent(
        must(login.logout_id_token("logout-id-token-sentinel")),
      ),
      must(login.token_expiry_unix_seconds(200)),
      [
        must(login.scope("openid")),
        must(login.scope("profile")),
        must(login.scope("openid")),
      ],
    )
  login.LoginAttestation(
    identity,
    tokens,
    login.authentication_evidence(
      must(login.nonce("nonce-sentinel")),
      login.NoAuthenticationTime,
    ),
  )
}

fn consuming_store(
  transaction: login.Transaction,
  transaction_id: login.TransactionId,
  revision: login.StoredRevision,
  now: login.Timestamp,
) -> login.TransactionStore {
  // This callback computes and asserts a transition from a captured row; it
  // does not persist shared state or mutate the captured pending copy.
  let current = login.trusted_rehydrate_pending(transaction, revision)
  login.transaction_store(login.clock(fn() { now }), fn(command, locked_clock) {
    let login.ConsumeCommandMetadata(command_id, command_revision) =
      login.consume_command_metadata(command)
    let assert True = command_id == transaction_id
    let assert True = command_revision == revision
    let #(next, decision) =
      login.decide_consume(
        current,
        command,
        login.sample_locked_clock(locked_clock),
      )
    let assert login.ConsumedStatus = login.stored_status(next)
    login.Decided(decision)
  })
}

fn replay_store(terminal: login.StoredTransaction) -> login.TransactionStore {
  login.transaction_store(
    login.clock(fn() { timestamp(99) }),
    fn(command, locked_clock) {
      let #(next, decision) =
        login.decide_consume(
          terminal,
          command,
          login.sample_locked_clock(locked_clock),
        )
      let assert login.ConsumedStatus = login.stored_status(next)
      login.Decided(decision)
    },
  )
}

fn expect_store_failure(
  client: login.Client,
  checked: login.CheckedOutcome,
  reply: login.StoreReply,
  expected: login.ConsumeError,
) -> Nil {
  let backend =
    login.trust_adapter(
      client,
      test_declaration("store-failure-must-not-exchange"),
      panic_exchange,
    )
  let store = reply_store(reply)
  let assert Error(login.ConsumptionFailed(actual)) =
    complete_session(store, backend, checked)
  let assert True = actual == expected
  Nil
}

fn expect_attestation_error(
  client: login.Client,
  transaction: login.Transaction,
  transaction_id: login.TransactionId,
  revision: login.StoredRevision,
  checked: login.CheckedOutcome,
  attestation: login.BackendAttestation,
  expected: login.CompleteLoginError,
) -> Nil {
  let backend =
    login.trust_adapter(
      client,
      test_declaration("invalid-attestation"),
      fn(_request) { Ok(successful_attestation(attestation)) },
    )
  let actual =
    complete_session(
      consuming_store(transaction, transaction_id, revision, timestamp(99)),
      backend,
      checked,
    )
  let assert Error(error) = actual
  let assert True = error == expected
  Nil
}

fn expect_backend_failure(
  client: login.Client,
  transaction: login.Transaction,
  transaction_id: login.TransactionId,
  revision: login.StoredRevision,
  checked: login.CheckedOutcome,
  expected: login.BackendError,
) -> Nil {
  let backend =
    login.trust_adapter(
      client,
      test_declaration("closed-backend-failure"),
      fn(_request) { Error(expected) },
    )
  let actual =
    complete_session(
      consuming_store(transaction, transaction_id, revision, timestamp(99)),
      backend,
      checked,
    )
  let assert Error(login.BackendFailed(error)) = actual
  let assert True = error == expected
  Nil
}

fn reply_store(reply: login.StoreReply) -> login.TransactionStore {
  login.transaction_store(
    login.clock(fn() { timestamp(99) }),
    fn(_command, _clock) { reply },
  )
}

fn panic_store() -> login.TransactionStore {
  login.transaction_store(
    login.clock(fn() { timestamp(99) }),
    fn(_command, _clock) { panic as "client mismatch must fail before storage" },
  )
}

fn panic_exchange(
  _request: login.ExchangeRequest,
) -> Result(login.LoginAttestation, login.BackendError) {
  panic as "this branch must not invoke the token exchange callback"
}

fn allow_request(
  _context: request_scoped_tools.RequestContext,
  _input: request_scoped_tools.OrderLookup,
) -> Result(Nil, request_scoped_tools.AppError) {
  Ok(Nil)
}

fn test_declaration(name: String) -> login.AdapterDeclaration {
  login.AdapterDeclaration(name, "fixture-v1", login.TestOnlyAdapter)
}

fn revision(value: String) -> login.StoredRevision {
  let assert Ok(checked) = login.stored_revision(value)
  checked
}

fn timestamp(value: Int) -> login.Timestamp {
  let assert Ok(checked) = login.timestamp(value)
  checked
}

fn must(value: Result(a, login.InputError)) -> a {
  let assert Ok(checked) = value
  checked
}
