// THROWAWAY: Does a verified login publish a session only after exact custody confirmation?
import lab/hellhound_transaction as login

type Fixture {
  Fixture(
    issuer: login.Issuer,
    client_id: login.ClientId,
    client: login.Client,
    nonce: login.Nonce,
    transaction_id: login.TransactionId,
    revision: login.StoredRevision,
    transaction: login.Transaction,
    pending: login.StoredTransaction,
    checked: login.CheckedOutcome,
    store: login.TransactionStore,
  )
}

type CustodyLedger {
  EmptyLedger
  LedgerInstalled(
    installation_id: login.CustodyInstallationId,
    accepted_command: login.CustodyCommand,
    reference: login.CustodyReference,
    revision: login.CustodyRevision,
  )
}

pub fn probe() -> Nil {
  // Token wrappers reject empty secrets. Scope tokens follow the RFC 6749
  // visible-ASCII token grammar and are deduplicated without changing order.
  let assert Error(login.ValueMustNotBeEmpty) = login.access_token("")
  let assert Error(login.ValueMustNotBeEmpty) = login.refresh_token("")
  let assert Error(login.ValueMustNotBeEmpty) = login.logout_id_token("")
  let assert Error(login.ScopeTokenInvalid) = login.scope("")
  let assert Error(login.ScopeTokenInvalid) = login.scope("read write")
  let assert Error(login.ScopeTokenInvalid) = login.scope("bad\"scope")
  let assert Error(login.ScopeTokenInvalid) = login.scope("bad\\scope")
  let assert Error(login.ScopeTokenInvalid) = login.scope("café")
  let assert Error(login.ScopeTokenInvalid) = login.scope("\t")
  let assert Error(login.ScopeTokenInvalid) = login.scope("\n")
  let assert Ok(_) = login.scope("!#[]~")
  let case_sensitive_material =
    login.token_material(
      must(login.access_token("case-sensitive-access")),
      login.NoRefreshToken,
      login.NoLogoutIdToken,
      must(login.token_expiry_unix_seconds(50)),
      [must(login.scope("read")), must(login.scope("READ"))],
    )
  let assert login.TokenMaterialMetadata(False, False, 50, ["read", "READ"]) =
    login.token_material_metadata(case_sensitive_material)
  let assert Error(login.TimestampMustNotBeNegative) =
    login.token_expiry_unix_seconds(-1)
  let install_fixture = fixture("transaction-install")
  let Fixture(
    issuer,
    client_id,
    client,
    nonce,
    transaction_id,
    _,
    _,
    _,
    checked,
    store,
  ) = install_fixture
  let install_tokens = tokens("access-install", login.NoRefreshToken)
  let declaration = test_declaration("custody-adapter")
  let backend =
    make_backend(
      client,
      issuer,
      client_id,
      nonce,
      declaration,
      "verified-subject",
      install_tokens,
    )
  let provider = login.provider_binding(client, declaration)
  let owner_id = must(login.custody_owner_id("account-owner-a"))
  let owner =
    login.custody_owner(
      owner_id,
      fn(command) {
        let login.CustodyCommandMetadata(
          actual_owner,
          installation_id,
          actual_provider,
          actual_transaction,
          actual_identity,
        ) = login.custody_command_metadata(command)
        let assert True = actual_owner == owner_id
        let assert True = actual_provider == provider
        let assert True = actual_transaction == transaction_id
        let assert "verified-subject" = login.verified_subject(actual_identity)
        let assert True =
          installation_id
          == login.custody_installation_id(owner_id, provider, transaction_id)
        let login.CustodyCommandContents(_, _, _, _, _, _, _, exact_tokens) =
          login.custody_command_contents(command)
        let login.TrustedTokenMaterialView(access_token, _, _, _, _) =
          login.trusted_token_material_view(exact_tokens)
        let authorization = "Bearer " <> access_token
        let assert "Bearer access-install" = authorization
        login.custody_installed(
          command,
          must(login.custody_reference("session-reference-install")),
          must(login.custody_revision("session-revision-install")),
        )
      },
      fn(recovery) {
        login.custody_installed(
          login.recovery_custody_command(recovery),
          must(login.custody_reference("session-reference-install")),
          must(login.custody_revision("session-revision-install")),
        )
      },
    )
  let assert Ok(login.LoginCompleted(session)) =
    login.complete_login(store, backend, owner, checked)
  let assert "verified-subject" =
    login.verified_subject(login.session_identity(session))
  let assert True =
    login.session_custody_reference(session)
    == must(login.custody_reference("session-reference-install"))
  let assert True =
    login.session_custody_revision(session)
    == must(login.custody_revision("session-revision-install"))
  let assert True = login.session_provider_binding(session) == provider

  let install_metadata = login.token_material_metadata(install_tokens)
  let assert login.TokenMaterialMetadata(
    False,
    True,
    1_800_000_000,
    ["openid", "profile"],
  ) = install_metadata
  // The immutable ledger models a durable write whose acknowledgement was
  // lost. Recovery later reads that retained record and returns its receipt.
  let lost_ack_fixture = fixture("transaction-lost-ack")
  let Fixture(
    lost_issuer,
    lost_client_id,
    lost_client,
    lost_nonce,
    lost_transaction_id,
    _,
    _,
    _,
    lost_checked,
    lost_store,
  ) = lost_ack_fixture
  let lost_declaration = test_declaration("custody-adapter")
  let lost_provider = login.provider_binding(lost_client, lost_declaration)
  let lost_owner_id = must(login.custody_owner_id("account-owner-lost-ack"))
  let lost_tokens =
    tokens(
      "access-lost-ack",
      login.RefreshTokenPresent(must(login.refresh_token("refresh-lost-ack"))),
    )
  let assert login.TokenMaterialMetadata(
    True,
    True,
    1_800_000_000,
    ["openid", "profile"],
  ) = login.token_material_metadata(lost_tokens)
  let lost_backend =
    make_backend(
      lost_client,
      lost_issuer,
      lost_client_id,
      lost_nonce,
      lost_declaration,
      "lost-ack-subject",
      lost_tokens,
    )
  let lost_owner =
    login.custody_owner(
      lost_owner_id,
      fn(command) {
        let login.CustodyCommandMetadata(
          actual_owner,
          installation_id,
          actual_provider,
          actual_transaction,
          _,
        ) = login.custody_command_metadata(command)
        let assert True = actual_owner == lost_owner_id
        let assert True = actual_provider == lost_provider
        let assert True = actual_transaction == lost_transaction_id
        let assert True =
          installation_id
          == login.custody_installation_id(
            lost_owner_id,
            lost_provider,
            lost_transaction_id,
          )
        login.custody_outcome_unknown()
      },
      fn(_recovery) { login.custody_outcome_unknown() },
    )
  let assert Ok(login.LoginRecoveryRequired(recovery)) =
    login.complete_login(lost_store, lost_backend, lost_owner, lost_checked)
  let original_command = login.recovery_custody_command(recovery)
  let #(installed_ledger, lost_reply, ledger_reference, ledger_revision) =
    ledger_install(original_command, EmptyLedger, True)
  let assert login.CustodyOutcomeUnknown = lost_reply
  let assert LedgerInstalled(_, retained_command, _, _) = installed_ledger
  let assert True = retained_command == original_command
  let login.CustodyCommandMetadata(_, lost_installation, _, _, _) =
    login.custody_command_metadata(original_command)
  let assert True =
    lost_installation
    == login.custody_installation_id(
      lost_owner_id,
      lost_provider,
      lost_transaction_id,
    )
  let ledger_owner =
    login.custody_owner(
      lost_owner_id,
      fn(_command) { login.custody_outcome_unknown() },
      fn(recovery) { ledger_recover(recovery, installed_ledger) },
    )
  let absent_owner =
    login.custody_owner(
      lost_owner_id,
      fn(_command) { login.custody_outcome_unknown() },
      fn(recovery) { ledger_recover(recovery, EmptyLedger) },
    )
  let assert Ok(login.CustodyStillUncertain(absent_recovery)) =
    login.recover_custody(absent_owner, recovery)
  let assert True = absent_recovery == recovery
  let unavailable_owner =
    login.custody_owner(
      lost_owner_id,
      fn(_command) { login.custody_outcome_unknown() },
      fn(_recovery) { login.custody_port_unavailable() },
    )
  let assert Ok(login.CustodyStillUncertain(unavailable_recovery)) =
    login.recover_custody(unavailable_owner, recovery)
  let assert True = unavailable_recovery == recovery
  let assert Ok(login.CustodyRecovered(recovered_session)) =
    login.recover_custody(ledger_owner, recovery)
  let assert True =
    login.session_installation_id(recovered_session) == lost_installation
  let assert True =
    login.session_custody_reference(recovered_session) == ledger_reference
  let assert True =
    login.session_custody_revision(recovered_session) == ledger_revision
  let assert Ok(login.CustodyRecovered(replayed_session)) =
    login.recover_custody(ledger_owner, recovery)
  let assert True =
    login.session_custody_reference(replayed_session) == ledger_reference
  let assert True =
    login.session_custody_revision(replayed_session) == ledger_revision
  let #(same_ledger, same_command_reply, replay_reference, replay_revision) =
    ledger_install(original_command, installed_ledger, False)
  let assert True = same_ledger == installed_ledger
  let assert True = replay_reference == ledger_reference
  let assert True = replay_revision == ledger_revision
  let assert login.CustodyInstalled(_) = same_command_reply

  // Recovery is owner-bound and rejects a foreign owner before invoking its
  // port callback. A changed token payload cannot satisfy the original receipt
  // even when its stable owner/provider/transaction id is unchanged.
  let foreign_owner = panic_owner("account-owner-foreign")
  let assert Error(login.RecoveryOwnerMismatch) =
    login.recover_custody(foreign_owner, recovery)

  let contradictory_fixture = fixture("transaction-contradictory")
  let Fixture(
    other_issuer,
    other_client_id,
    other_client,
    other_nonce,
    other_transaction_id,
    _,
    _,
    _,
    other_checked,
    other_store,
  ) = contradictory_fixture
  let same_owner_id = must(login.custody_owner_id("account-owner-same"))
  let same_declaration = test_declaration("same-provider")
  let same_provider = login.provider_binding(other_client, same_declaration)
  let changed_backend =
    make_backend(
      other_client,
      other_issuer,
      other_client_id,
      other_nonce,
      same_declaration,
      "same-subject",
      tokens("access-changed", login.NoRefreshToken),
    )
  let unknown_owner =
    login.custody_owner(
      same_owner_id,
      fn(_command) { login.custody_outcome_unknown() },
      fn(_recovery) { login.custody_outcome_unknown() },
    )
  let assert Ok(login.LoginRecoveryRequired(changed_recovery)) =
    login.complete_login(
      other_store,
      changed_backend,
      unknown_owner,
      other_checked,
    )
  let changed_command = login.recovery_custody_command(changed_recovery)
  let changed_metadata = login.custody_command_metadata(changed_command)
  let login.CustodyCommandMetadata(_, changed_installation_id, _, _, _) =
    changed_metadata
  let assert True =
    changed_installation_id
    == login.custody_installation_id(
      same_owner_id,
      same_provider,
      other_transaction_id,
    )

  let original_backend =
    make_backend(
      other_client,
      other_issuer,
      other_client_id,
      other_nonce,
      same_declaration,
      "same-subject",
      tokens("access-original", login.NoRefreshToken),
    )
  let contradictory_owner =
    login.custody_owner(
      same_owner_id,
      fn(_command) {
        login.custody_installed(
          changed_command,
          must(login.custody_reference("ledger-session-changed")),
          must(login.custody_revision("ledger-revision-changed")),
        )
      },
      fn(_recovery) {
        login.custody_installed(
          changed_command,
          must(login.custody_reference("ledger-session-changed")),
          must(login.custody_revision("ledger-revision-changed")),
        )
      },
    )
  let assert Ok(login.LoginRecoveryRequired(original_recovery)) =
    login.complete_login(
      other_store,
      original_backend,
      contradictory_owner,
      other_checked,
    )
  let original_command = login.recovery_custody_command(original_recovery)
  let login.CustodyCommandMetadata(_, original_installation_id, _, _, _) =
    login.custody_command_metadata(original_command)
  let assert True = original_installation_id == changed_installation_id
  let assert False = original_command == changed_command
  let #(
    material_ledger,
    first_write_reply,
    original_ledger_reference,
    original_ledger_revision,
  ) = ledger_install(original_command, EmptyLedger, True)
  let assert login.CustodyOutcomeUnknown = first_write_reply
  let #(material_ledger_after_conflict, conflict_reply, _, _) =
    ledger_install(changed_command, material_ledger, False)
  let assert login.CustodyRejected(login.CustodyPortRejected) = conflict_reply
  let assert True = material_ledger_after_conflict == material_ledger
  let assert LedgerInstalled(_, retained_material_command, _, _) =
    material_ledger
  let assert True = retained_material_command == original_command
  let assert Ok(login.CustodyStillUncertain(still_uncertain)) =
    login.recover_custody(contradictory_owner, original_recovery)
  let assert True =
    login.recovery_custody_command(still_uncertain) == original_command
  let exact_material_owner =
    login.custody_owner(
      same_owner_id,
      fn(_command) { login.custody_outcome_unknown() },
      fn(recovery) { ledger_recover(recovery, material_ledger) },
    )
  let assert Ok(login.CustodyRecovered(material_recovered_session)) =
    login.recover_custody(exact_material_owner, original_recovery)
  let assert True =
    login.session_custody_reference(material_recovered_session)
    == original_ledger_reference
  let assert True =
    login.session_custody_revision(material_recovered_session)
    == original_ledger_revision

  // Invalid identity evidence and provider denial reach neither token custody
  // callback. The recovery surface has no backend or authorization-code input.
  let invalid_backend =
    make_backend(
      other_client,
      must(login.issuer("https://wrong-issuer.example")),
      other_client_id,
      other_nonce,
      same_declaration,
      "wrong-subject",
      tokens("access-invalid", login.NoRefreshToken),
    )
  let assert Error(login.AttestedIssuerMismatch) =
    login.complete_login(
      other_store,
      invalid_backend,
      panic_owner("account-owner-invalid"),
      other_checked,
    )

  let Fixture(_, _, denial_client, _, _, _, _, pending, _, denial_store) =
    fixture("transaction-denied")
  let denial_callback =
    login.Callback(
      must(login.issuer("https://login.example")),
      must(login.state("state-transaction-denied")),
      login.CallbackRejected("access_denied"),
    )
  let assert Ok(denial) = login.check_callback(pending, denial_callback)
  let denial_backend =
    login.trust_adapter(
      denial_client,
      test_declaration("denial-must-not-exchange"),
      panic_exchange,
    )
  let assert Error(login.ProviderRejection(login.AccessDenied)) =
    login.complete_login(
      denial_store,
      denial_backend,
      panic_owner("account-owner-denied"),
      denial,
    )
  Nil
}

fn fixture(name: String) -> Fixture {
  let issuer = must(login.issuer("https://login.example"))
  let client_id = must(login.client_id("client-custody"))
  let client =
    login.client(
      issuer,
      client_id,
      must(login.redirect_uri("https://app.example/callback")),
    )
  let nonce = must(login.nonce("nonce-custody"))
  let state = must(login.state("state-" <> name))
  let transaction_id = must(login.transaction_id(name))
  let assert Ok(#(_, transaction)) =
    login.plan_login(
      client,
      transaction_id,
      login.LoginMaterial(
        state,
        nonce,
        must(login.pkce_verifier("verifier-custody")),
        must(login.pkce_challenge("challenge-custody")),
      ),
      timestamp(10),
      timestamp(100),
    )
  let revision = revision("revision-" <> name)
  let pending = login.trusted_rehydrate_pending(transaction, revision)
  let callback =
    login.Callback(
      issuer,
      state,
      login.AuthorizationCodeReceived("code-" <> name),
    )
  let assert Ok(checked) = login.check_callback(pending, callback)
  Fixture(
    issuer,
    client_id,
    client,
    nonce,
    transaction_id,
    revision,
    transaction,
    pending,
    checked,
    store_for(transaction, transaction_id, revision),
  )
}

fn store_for(
  transaction: login.Transaction,
  transaction_id: login.TransactionId,
  revision: login.StoredRevision,
) -> login.TransactionStore {
  let current = login.trusted_rehydrate_pending(transaction, revision)
  login.transaction_store(
    login.clock(fn() { timestamp(99) }),
    fn(command, clock) {
      let login.ConsumeCommandMetadata(command_id, command_revision) =
        login.consume_command_metadata(command)
      let assert True = command_id == transaction_id
      let assert True = command_revision == revision
      let #(next, decision) =
        login.decide_consume(current, command, login.sample_locked_clock(clock))
      let assert login.ConsumedStatus = login.stored_status(next)
      login.Decided(decision)
    },
  )
}

fn ledger_install(
  command: login.CustodyCommand,
  ledger: CustodyLedger,
  lose_ack: Bool,
) -> #(
  CustodyLedger,
  login.CustodyReply,
  login.CustodyReference,
  login.CustodyRevision,
) {
  let login.CustodyCommandMetadata(_, installation_id, _, _, _) =
    login.custody_command_metadata(command)
  case ledger {
    EmptyLedger -> {
      let reference = must(login.custody_reference("ledger-session-stable"))
      let revision = must(login.custody_revision("ledger-revision-stable"))
      let reply = case lose_ack {
        True -> login.custody_outcome_unknown()
        False -> login.custody_installed(command, reference, revision)
      }
      #(
        LedgerInstalled(installation_id, command, reference, revision),
        reply,
        reference,
        revision,
      )
    }
    LedgerInstalled(stored_installation_id, stored_command, reference, revision) ->
      case stored_installation_id == installation_id {
        False -> #(
          ledger,
          login.custody_rejected(login.CustodyPortRejected),
          reference,
          revision,
        )
        True ->
          case stored_command == command {
            True -> #(
              ledger,
              login.custody_installed(stored_command, reference, revision),
              reference,
              revision,
            )
            False -> #(
              ledger,
              login.custody_rejected(login.CustodyPortRejected),
              reference,
              revision,
            )
          }
      }
  }
}

fn ledger_recover(
  recovery: login.CustodyRecoveryCommand,
  ledger: CustodyLedger,
) -> login.CustodyReply {
  let command = login.recovery_custody_command(recovery)
  let login.CustodyCommandMetadata(_, installation_id, _, _, _) =
    login.custody_command_metadata(command)
  case ledger {
    EmptyLedger -> login.custody_outcome_unknown()
    LedgerInstalled(stored_installation_id, stored_command, reference, revision) ->
      case
        stored_installation_id == installation_id && stored_command == command
      {
        True -> login.custody_installed(stored_command, reference, revision)
        False -> login.custody_outcome_unknown()
      }
  }
}

fn make_backend(
  client: login.Client,
  issuer: login.Issuer,
  client_id: login.ClientId,
  nonce: login.Nonce,
  declaration: login.AdapterDeclaration,
  subject: String,
  token_material: login.TokenMaterial,
) -> login.VerificationBackend {
  login.trust_adapter(client, declaration, fn(request) {
    let assert login.ExchangeParameters(
      "https://login.example",
      "client-custody",
      "https://app.example/callback",
      _,
      "nonce-custody",
      "verifier-custody",
      login.VerificationProfile(True, True, login.ExactSingletonClient, True),
    ) = login.exchange_parameters(request)
    Ok(login.LoginAttestation(
      login.BackendAttestation(
        issuer,
        [client_id],
        login.NoAuthorizedParty,
        subject,
      ),
      token_material,
      login.authentication_evidence(nonce, login.NoAuthenticationTime),
    ))
  })
}

fn tokens(
  access: String,
  refresh: login.RefreshTokenChoice,
) -> login.TokenMaterial {
  login.token_material(
    must(login.access_token(access)),
    refresh,
    login.LogoutIdTokenPresent(must(login.logout_id_token("logout-hint"))),
    must(login.token_expiry_unix_seconds(1_800_000_000)),
    [
      must(login.scope("openid")),
      must(login.scope("profile")),
      must(login.scope("openid")),
    ],
  )
}

fn panic_owner(name: String) -> login.CustodyOwner {
  login.custody_owner(
    must(login.custody_owner_id(name)),
    fn(_command) { panic as "identity and denial checks must precede custody" },
    fn(_recovery) {
      panic as "foreign recovery must fail before the custody port"
    },
  )
}

fn panic_exchange(
  _request: login.ExchangeRequest,
) -> Result(login.LoginAttestation, login.BackendError) {
  panic as "provider denial must not exchange the authorization code"
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
