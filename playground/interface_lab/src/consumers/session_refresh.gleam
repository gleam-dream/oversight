// THROWAWAY: Can one custody owner serialize typed refresh generations?
// Scripted callbacks test public transitions; they do not prove durable atomicity,
// process concurrency, provider behavior, cryptography, or secret isolation.
import lab/warden_transaction as w

type LoginFixture {
  LoginFixture(
    issuer: w.Issuer,
    client_id: w.ClientId,
    client: w.Client,
    nonce: w.Nonce,
    transaction_id: w.TransactionId,
    checked: w.CheckedOutcome,
    store: w.TransactionStore,
  )
}

type LedgerContext {
  LedgerContext(
    owner: w.CustodyOwnerId,
    reference: w.CustodyReference,
    revision: w.CustodyRevision,
    provider: w.ProviderBinding,
    installation: w.CustodyInstallationId,
    identity: w.VerifiedIdentity,
    tokens: w.TokenMaterial,
    authentication: w.AuthenticationEvidence,
  )
}

type ReservationPhase {
  Ready
  InFlight(w.RefreshReservationRequest, w.RefreshDispatch)
  Quarantined(w.RefreshReservationRequest, w.RefreshDispatch)
}

type RecordedValue {
  NoSendRecorded
  EndpointRejectedRecorded
  ProviderUnknownRecorded
  InvalidResponseRecorded(w.RefreshValidationError)
  PublishedRecorded(
    command: w.RefreshPublicationCommand,
    reference: w.CustodyReference,
    revision: w.CustodyRevision,
  )
}

type LedgerRecord {
  LedgerRecord(request: w.RefreshReservationRequest, value: RecordedValue)
}

type RecordLookup {
  RecordMissing
  RecordPresent(LedgerRecord)
}

type ProviderTokenLedger {
  ProviderTokenRotated(previous: w.RefreshToken, current: w.RefreshToken)
}

type RefreshLedger {
  RefreshLedger(
    context: LedgerContext,
    phase: ReservationPhase,
    records: List(LedgerRecord),
  )
}

pub fn probe() -> Nil {
  // The only session in the probe is created by verified login and confirmed
  // custody. Refresh does not introduce a second identity-bearing handle.
  let fixture = login_fixture("session-refresh")
  let LoginFixture(
    issuer,
    client_id,
    client,
    nonce,
    transaction_id,
    checked,
    store,
  ) = fixture
  let owner_id = must_owner_id("refresh-owner")
  let provider_declaration = declaration("refresh-provider")
  let provider = w.provider_binding(client, provider_declaration)
  let authentication =
    w.authentication_evidence(
      nonce,
      w.AuthenticationTimePresent(must_timestamp(25)),
    )
  let initial_tokens =
    token_material(
      "access-original",
      w.RefreshTokenPresent(must_refresh_token("refresh-original")),
      w.LogoutIdTokenPresent(must_logout_id_token("logout-original")),
    )
  let login_owner =
    w.custody_owner(
      owner_id,
      fn(command) {
        let w.CustodyCommandMetadata(
          actual_owner,
          installation,
          actual_provider,
          actual_transaction,
          identity,
        ) = w.custody_command_metadata(command)
        let assert True = actual_owner == owner_id
        let assert True = actual_provider == provider
        let assert True = actual_transaction == transaction_id
        let assert "refresh-subject" = w.verified_subject(identity)
        let assert True =
          installation
          == w.custody_installation_id(owner_id, provider, transaction_id)
        w.custody_installed(
          command,
          must_reference("session-reference-0"),
          must_revision("session-revision-0"),
        )
      },
      fn(recovery) {
        w.custody_installed(
          w.recovery_custody_command(recovery),
          must_reference("session-reference-0"),
          must_revision("session-revision-0"),
        )
      },
    )
  let login_backend =
    w.trust_adapter(client, provider_declaration, fn(request) {
      let assert w.ExchangeParameters(_, _, _, _, "refresh-nonce", _, _) =
        w.exchange_parameters(request)
      Ok(w.LoginAttestation(
        w.BackendAttestation(
          issuer,
          [client_id],
          w.NoAuthorizedParty,
          "refresh-subject",
        ),
        initial_tokens,
        authentication,
      ))
    })
  let assert Ok(w.LoginCompleted(session)) =
    w.complete_login(store, login_backend, login_owner, checked)
  let context =
    LedgerContext(
      owner_id,
      w.session_custody_reference(session),
      w.session_custody_revision(session),
      w.session_provider_binding(session),
      w.session_installation_id(session),
      w.session_identity(session),
      initial_tokens,
      authentication,
    )
  let ledger = RefreshLedger(context, Ready, [])

  // Local owner/provider checks and missing token rejection happen before the
  // provider callback. An empty token material is not a claimable generation.
  let foreign_owner =
    owner_with_port(must_owner_id("foreign-owner"), panic_port())
  let assert Error(w.RefreshSessionOwnerMismatch) =
    w.refresh_session(
      foreign_owner,
      w.refresh_backend(provider, panic_backend),
      session,
      must_refresh_id("foreign-session"),
    )
  let other_provider =
    w.provider_binding(client, declaration("different-refresh-provider"))
  let assert Error(w.RefreshBackendConfigurationMismatch) =
    w.refresh_session(
      owner_with_port(owner_id, panic_port()),
      w.refresh_backend(other_provider, panic_backend),
      session,
      must_refresh_id("wrong-provider-binding"),
    )
  let no_token_context =
    LedgerContext(
      context.owner,
      context.reference,
      context.revision,
      context.provider,
      context.installation,
      context.identity,
      token_material("access-only", w.NoRefreshToken, w.NoLogoutIdToken),
      context.authentication,
    )
  let no_token_ledger = RefreshLedger(no_token_context, Ready, [])
  let assert Error(w.RefreshReservationRejected(w.RefreshMaterialMissing)) =
    w.refresh_session(
      owner_for(no_token_ledger),
      w.refresh_backend(provider, panic_backend),
      session,
      must_refresh_id("no-refresh-token"),
    )

  // A competing command gets a busy recovery handle and cannot run the backend.
  let command_a = must_refresh_id("scheduled-refresh")
  let command_b = must_refresh_id("user-refresh")
  let request_a = reveal_request(owner_id, provider, session, command_a)
  let request_b = reveal_request(owner_id, provider, session, command_b)
  let #(reserved_ledger, reserve_reply) = ledger_reserve(ledger, request_a)
  let assert w.RefreshDispatchIssued(_) = reserve_reply
  let assert Ok(w.RefreshReservationUnresolved(_)) =
    w.refresh_session(
      owner_for(reserved_ledger),
      w.refresh_backend(provider, panic_backend),
      session,
      command_b,
    )
  let assert True = case ledger_phase(reserved_ledger) {
    InFlight(reserved_request, _) -> reserved_request == request_a
    _ -> False
  }
  let _ = request_b

  // A provider-proven no-send is settled as a typed outcome. A different command
  // can retry; the original command is replayed from its exact recorded result.
  let no_send_id = must_refresh_id("known-no-send")
  let no_send_request = reveal_request(owner_id, provider, session, no_send_id)
  let no_send_result =
    w.refresh_session(
      owner_for(ledger),
      w.refresh_backend(provider, fn(_) { w.ProvenNotSent }),
      session,
      no_send_id,
    )
  let assert Ok(w.RefreshReservationUnresolved(no_send_recovery)) =
    no_send_result
  let #(no_send_reserved, no_send_reply) =
    ledger_reserve(ledger, no_send_request)
  let assert w.RefreshDispatchIssued(no_send_dispatch) = no_send_reply
  let w.RefreshReservationRecoveryContents(_, _, no_send_evidence) =
    w.refresh_reservation_recovery_contents(no_send_recovery)
  let assert w.SubmittedRefreshSettlement(no_send_command) = no_send_evidence
  let assert True = case w.refresh_settlement_contents(no_send_command) {
    w.RefreshSettlementContents(actual_dispatch, w.RefreshNoSend) ->
      actual_dispatch == no_send_dispatch
    _ -> False
  }
  let #(no_send_recorded_ledger, no_send_settle_reply) =
    ledger_settle(no_send_reserved, no_send_command)
  let assert w.RefreshSettlementUnknown = no_send_settle_reply
  let assert Ok(w.RefreshDidNotSend) =
    w.recover_refresh_reservation(
      owner_for(no_send_recorded_ledger),
      no_send_recovery,
    )
  let assert Ok(w.RefreshDidNotSend) =
    w.refresh_session(
      owner_for(no_send_recorded_ledger),
      w.refresh_backend(provider, panic_backend),
      session,
      no_send_id,
    )
  let endpoint_id = must_refresh_id("endpoint-rejected")
  let endpoint_request =
    reveal_request(owner_id, provider, session, endpoint_id)
  let assert Ok(w.RefreshReservationUnresolved(endpoint_recovery)) =
    w.refresh_session(
      owner_for(no_send_recorded_ledger),
      w.refresh_backend(provider, fn(_) { w.EndpointRejected }),
      session,
      endpoint_id,
    )
  let #(endpoint_reserved, _) =
    ledger_reserve(no_send_recorded_ledger, endpoint_request)
  let w.RefreshReservationRecoveryContents(_, _, endpoint_evidence) =
    w.refresh_reservation_recovery_contents(endpoint_recovery)
  let assert w.SubmittedRefreshSettlement(endpoint_command) = endpoint_evidence
  let #(endpoint_recorded, _) =
    ledger_settle(endpoint_reserved, endpoint_command)
  let assert Ok(w.RefreshRejectedByEndpoint) =
    w.recover_refresh_reservation(
      owner_for(endpoint_recorded),
      endpoint_recovery,
    )

  // A response without an ID token preserves identity/authentication. The
  // publication write is retained by the ledger despite a lost acknowledgement.
  let retained_id = must_refresh_id("refresh-retained")
  let retained_request =
    reveal_request(owner_id, provider, session, retained_id)
  let retained_next_revision = must_revision("session-revision-1")
  let retained_result =
    w.refresh_session(
      owner_for(ledger),
      w.refresh_backend(provider, fn(dispatch) {
        let w.TrustedRefreshDispatchView(
          actual_owner,
          actual_command,
          reference,
          revision,
          actual_provider,
          identity,
          raw_refresh,
          original_nonce,
          auth_time,
          scopes,
        ) = w.trusted_refresh_dispatch_view(dispatch)
        let assert True = actual_owner == owner_id
        let assert True = actual_command == retained_id
        let assert True = reference == context.reference
        let assert True = revision == context.revision
        let assert True = actual_provider == provider
        let assert True = identity == context.identity
        let assert "refresh-original" = raw_refresh
        let assert True = original_nonce == nonce
        let expected_auth_time = w.AuthenticationTimePresent(must_timestamp(25))
        let assert True = expected_auth_time == auth_time
        let assert ["openid", "profile"] = scopes
        w.RefreshAttested(w.RefreshAttestation(
          must_access_token("access-retained"),
          must_expiry(1_900_000_010),
          w.RetainRefreshToken,
          w.RefreshScopesReturned([
            must_scope("profile"),
            must_scope("openid"),
            must_scope("openid"),
          ]),
          w.RefreshIdTokenAbsent,
        ))
      }),
      session,
      retained_id,
    )
  let assert Ok(w.RefreshPublicationUnresolved(publication_recovery)) =
    retained_result
  let w.RefreshPublicationRecoveryContents(recovery_owner, publication_command) =
    w.refresh_publication_recovery_contents(publication_recovery)
  let assert True = recovery_owner == owner_id
  let #(retained_reserved, retained_reserve_reply) =
    ledger_reserve(ledger, retained_request)
  let assert w.RefreshDispatchIssued(_) = retained_reserve_reply
  let #(retained_written, lost_publication_reply) =
    ledger_publish(
      retained_reserved,
      publication_command,
      retained_next_revision,
    )
  let assert w.RefreshPublicationUnknown = lost_publication_reply
  let assert Ok(w.RefreshCompleted(retained_session)) =
    w.recover_refresh_publication(
      owner_for(retained_written),
      publication_recovery,
    )
  let assert True = w.session_identity(retained_session) == context.identity
  let assert True =
    w.session_custody_reference(retained_session) == context.reference
  let assert True =
    w.session_custody_revision(retained_session) == retained_next_revision
  let assert w.TokenMaterialMetadata(
    True,
    True,
    1_900_000_010,
    ["openid", "profile"],
  ) = w.token_material_metadata(ledger_tokens(retained_written))
  let w.TrustedTokenMaterialView(_, retained_refresh, retained_logout, _, _) =
    w.trusted_token_material_view(ledger_tokens(retained_written))
  let assert w.TrustedTokenValue("refresh-original") = retained_refresh
  let assert w.TrustedTokenValue("logout-original") = retained_logout
  let assert Ok(w.RefreshCompleted(replayed_retained_session)) =
    w.refresh_session(
      owner_for(retained_written),
      w.refresh_backend(provider, panic_backend),
      session,
      retained_id,
    )
  let assert True = replayed_retained_session == retained_session
  let assert Error(w.RefreshReservationRejected(w.RefreshSessionStale)) =
    w.refresh_session(
      owner_for(retained_written),
      w.refresh_backend(provider, panic_backend),
      session,
      must_refresh_id("stale-original-session"),
    )

  // A matching returned ID token and replacement refresh token publish in one
  // revision-bound command.
  let rotated_id = must_refresh_id("refresh-rotated")
  let rotated_request =
    reveal_request(owner_id, provider, retained_session, rotated_id)
  let rotated_revision = must_revision("session-revision-2")
  let assert Ok(w.RefreshPublicationUnresolved(rotated_recovery)) =
    w.refresh_session(
      owner_for(retained_written),
      w.refresh_backend(provider, fn(dispatch) {
        let w.TrustedRefreshDispatchView(
          _,
          actual_command,
          _,
          _,
          _,
          _,
          raw_refresh,
          _,
          _,
          _,
        ) = w.trusted_refresh_dispatch_view(dispatch)
        let assert True = actual_command == rotated_id
        let assert "refresh-original" = raw_refresh
        w.RefreshAttested(w.RefreshAttestation(
          must_access_token("access-rotated"),
          must_expiry(1_900_000_020),
          w.ReplaceRefreshToken(must_refresh_token("refresh-rotated")),
          w.RefreshScopesOmitted,
          w.RefreshIdTokenPresent(
            w.BackendAttestation(
              issuer,
              [client_id],
              w.AuthorizedParty(client_id),
              "refresh-subject",
            ),
            w.RefreshNonceReturned(nonce),
            w.AuthenticationTimePresent(must_timestamp(25)),
            must_logout_id_token("logout-rotated"),
          ),
        ))
      }),
      retained_session,
      rotated_id,
    )
  let w.RefreshPublicationRecoveryContents(_, rotated_command) =
    w.refresh_publication_recovery_contents(rotated_recovery)
  let #(rotated_reserved, _) = ledger_reserve(retained_written, rotated_request)
  let #(rotated_written, _) =
    ledger_publish(rotated_reserved, rotated_command, rotated_revision)
  let assert Ok(w.RefreshCompleted(rotated_session)) =
    w.recover_refresh_publication(owner_for(rotated_written), rotated_recovery)
  let assert True = w.session_identity(rotated_session) == context.identity
  let w.TrustedTokenMaterialView(_, rotated_refresh, rotated_logout, _, _) =
    w.trusted_token_material_view(ledger_tokens(rotated_written))
  let assert w.TrustedTokenValue("refresh-rotated") = rotated_refresh
  let assert w.TrustedTokenValue("logout-rotated") = rotated_logout

  // Recovery accepts only the exact original publication command, reference,
  // and advanced revision. Every contradiction retains the same recovery.
  assert_publication_recovery_stays_unresolved(
    owner_id,
    publication_recovery,
    rotated_command,
    context.reference,
    rotated_revision,
  )
  assert_publication_recovery_stays_unresolved(
    owner_id,
    publication_recovery,
    publication_command,
    context.reference,
    context.revision,
  )
  assert_publication_recovery_stays_unresolved(
    owner_id,
    publication_recovery,
    publication_command,
    must_reference("contradictory-publication-reference"),
    retained_next_revision,
  )

  // Scope values compare as case-sensitive sets. A changed grant is quarantined.
  let changed_scope =
    w.RefreshAttestation(
      must_access_token("access-changed-scope"),
      must_expiry(1_900_000_021),
      w.RetainRefreshToken,
      w.RefreshScopesReturned([
        must_scope("openid"),
        must_scope("OPENID"),
        must_scope("profile"),
      ]),
      w.RefreshIdTokenAbsent,
    )
  let #(scope_quarantined, scope_recovery) =
    settle_invalid_response(
      rotated_written,
      rotated_session,
      provider,
      "changed-scope",
      changed_scope,
    )
  let assert Ok(w.RefreshResponseQuarantined(
    w.RefreshedScopeChangeUnsupported,
    _,
  )) =
    w.recover_refresh_reservation(owner_for(scope_quarantined), scope_recovery)

  let changed_auth_time =
    w.RefreshAttestation(
      must_access_token("access-changed-auth-time"),
      must_expiry(1_900_000_022),
      w.RetainRefreshToken,
      w.RefreshScopesOmitted,
      w.RefreshIdTokenPresent(
        w.BackendAttestation(
          issuer,
          [client_id],
          w.NoAuthorizedParty,
          "refresh-subject",
        ),
        w.RefreshNonceReturned(nonce),
        w.AuthenticationTimePresent(must_timestamp(26)),
        must_logout_id_token("logout-changed-auth-time"),
      ),
    )
  let #(auth_quarantined, auth_recovery) =
    settle_invalid_response(
      rotated_written,
      rotated_session,
      provider,
      "changed-auth-time",
      changed_auth_time,
    )
  let assert Ok(w.RefreshResponseQuarantined(
    w.RefreshedAuthenticationTimeMismatch,
    _,
  )) = w.recover_refresh_reservation(owner_for(auth_quarantined), auth_recovery)

  let changed_nonce =
    w.RefreshAttestation(
      must_access_token("access-changed-nonce"),
      must_expiry(1_900_000_023),
      w.RetainRefreshToken,
      w.RefreshScopesOmitted,
      w.RefreshIdTokenPresent(
        w.BackendAttestation(
          issuer,
          [client_id],
          w.NoAuthorizedParty,
          "refresh-subject",
        ),
        w.RefreshNonceReturned(must_nonce("different-refresh-nonce")),
        w.AuthenticationTimePresent(must_timestamp(25)),
        must_logout_id_token("logout-changed-nonce"),
      ),
    )
  let #(nonce_quarantined, nonce_recovery) =
    settle_invalid_response(
      rotated_written,
      rotated_session,
      provider,
      "changed-nonce",
      changed_nonce,
    )
  let assert Ok(w.RefreshResponseQuarantined(w.RefreshedNonceMismatch, _)) =
    w.recover_refresh_reservation(owner_for(nonce_quarantined), nonce_recovery)

  // A mismatched subject is also quarantined before publication.
  let bad_refresh =
    w.RefreshAttestation(
      must_access_token("access-bad-subject"),
      must_expiry(1_900_000_020),
      w.RetainRefreshToken,
      w.RefreshScopesOmitted,
      w.RefreshIdTokenPresent(
        w.BackendAttestation(
          issuer,
          [client_id],
          w.NoAuthorizedParty,
          "other-subject",
        ),
        w.RefreshNonceReturned(nonce),
        w.AuthenticationTimePresent(must_timestamp(25)),
        must_logout_id_token("logout-bad"),
      ),
    )
  let #(bad_quarantined, bad_recovery) =
    settle_invalid_response(
      rotated_written,
      rotated_session,
      provider,
      "mismatched-subject",
      bad_refresh,
    )
  let assert Ok(w.RefreshResponseQuarantined(w.RefreshedSubjectMismatch, _)) =
    w.recover_refresh_reservation(owner_for(bad_quarantined), bad_recovery)
  let assert Error(w.RefreshReservationRejected(w.RefreshGenerationQuarantined)) =
    w.refresh_session(
      owner_for(bad_quarantined),
      w.refresh_backend(provider, panic_backend),
      rotated_session,
      must_refresh_id("retry-after-bad-id-token"),
    )

  // A scripted provider rotation followed by a lost response is unknown, not a
  // retryable endpoint rejection. Its generation stays quarantined.
  let provider_tokens =
    ProviderTokenRotated(
      must_refresh_token("refresh-rotated"),
      must_refresh_token("refresh-rotated-again"),
    )
  let unknown_id = must_refresh_id("provider-unknown")
  let unknown_request =
    reveal_request(owner_id, provider, rotated_session, unknown_id)
  let unknown_result =
    w.refresh_session(
      owner_for(rotated_written),
      w.refresh_backend(provider, fn(dispatch) {
        let w.TrustedRefreshDispatchView(_, _, _, _, _, _, raw_refresh, _, _, _) =
          w.trusted_refresh_dispatch_view(dispatch)
        let ProviderTokenRotated(previous, current) = provider_tokens
        let assert "refresh-rotated-again" =
          w.trusted_refresh_token_value(current)
        let assert True = w.trusted_refresh_token_value(previous) == raw_refresh
        w.ProviderOutcomeUnknown
      }),
      rotated_session,
      unknown_id,
    )
  let assert Ok(w.RefreshReservationUnresolved(unknown_recovery)) =
    unknown_result
  let #(unknown_reserved, unknown_reply) =
    ledger_reserve(rotated_written, unknown_request)
  let assert w.RefreshDispatchIssued(unknown_dispatch) = unknown_reply
  let w.RefreshReservationRecoveryContents(_, _, unknown_evidence) =
    w.refresh_reservation_recovery_contents(unknown_recovery)
  let assert w.SubmittedRefreshSettlement(unknown_command) = unknown_evidence
  let let_dispatch_matches = case
    w.refresh_settlement_contents(unknown_command)
  {
    w.RefreshSettlementContents(actual_dispatch, w.RefreshProviderUnknown) ->
      actual_dispatch == unknown_dispatch
    _ -> False
  }
  let assert True = let_dispatch_matches
  let #(unknown_quarantined, _) =
    ledger_settle(unknown_reserved, unknown_command)
  let assert Ok(w.RefreshProviderQuarantined(_)) =
    w.recover_refresh_reservation(
      owner_for(unknown_quarantined),
      unknown_recovery,
    )
  let assert Error(w.RefreshReservationRejected(w.RefreshGenerationQuarantined)) =
    w.refresh_session(
      owner_for(unknown_quarantined),
      w.refresh_backend(provider, panic_backend),
      rotated_session,
      must_refresh_id("retry-after-provider-unknown"),
    )

  // Reservation recovery remains a distinct read-only phase. A port that cannot
  // report a state keeps its command; neither recovery path replays the provider.
  let pending_id = must_refresh_id("reserve-lost-reply")
  let pending_request =
    reveal_request(owner_id, provider, rotated_session, pending_id)
  let #(pending_ledger, pending_reply) =
    ledger_reserve(rotated_written, pending_request)
  let assert w.RefreshDispatchIssued(_) = pending_reply
  let pending_result =
    w.refresh_session(
      owner_with_port(
        owner_id,
        pending_unknown_port(rotated_written, pending_ledger),
      ),
      w.refresh_backend(provider, panic_backend),
      rotated_session,
      pending_id,
    )
  let assert Ok(w.RefreshReservationUnresolved(pending_recovery)) =
    pending_result
  let assert Ok(w.RefreshReservationUnresolved(pending_again)) =
    w.recover_refresh_reservation(owner_for(pending_ledger), pending_recovery)
  let assert True = pending_again == pending_recovery

  // Exact request correlation blocks a dispatch or recorded result from another
  // command before the panic backend can run.
  let foreign_request =
    reveal_request(
      owner_id,
      provider,
      rotated_session,
      must_refresh_id("foreign-command"),
    )
  let unrelated_dispatch =
    dispatch_for(
      foreign_request,
      ledger_tokens(rotated_written),
      context.authentication,
    )
  let dispatch_reply_owner =
    owner_with_port(
      owner_id,
      w.refresh_port(
        fn(_) { w.RefreshDispatchIssued(unrelated_dispatch) },
        panic_settlement,
        panic_publication,
        fn(_) { w.RefreshReservationStatusUnknown },
        fn(_) { w.RefreshPublicationUnknown },
      ),
    )
  let assert Ok(w.RefreshReservationUnresolved(_)) =
    w.refresh_session(
      dispatch_reply_owner,
      w.refresh_backend(provider, panic_backend),
      rotated_session,
      must_refresh_id("dispatch-correlation"),
    )
  let foreign_record =
    w.RefreshRecordedOutcome(foreign_request, w.RefreshNoSendRecorded)
  let record_reply_owner =
    owner_with_port(
      owner_id,
      w.refresh_port(
        fn(_) { w.RefreshCommandRecorded(foreign_record) },
        panic_settlement,
        panic_publication,
        fn(_) { w.RefreshReservationStatusUnknown },
        fn(_) { w.RefreshPublicationUnknown },
      ),
    )
  let assert Ok(w.RefreshReservationUnresolved(_)) =
    w.refresh_session(
      record_reply_owner,
      w.refresh_backend(provider, panic_backend),
      rotated_session,
      must_refresh_id("record-correlation"),
    )
  Nil
}

fn ledger_reserve(
  ledger: RefreshLedger,
  request: w.RefreshReservationRequest,
) -> #(RefreshLedger, w.RefreshReserveReply) {
  let w.RefreshReservationMetadata(owner, command_id, _, _) =
    w.refresh_reservation_metadata(request)
  case find_record(ledger_records(ledger), command_id) {
    RecordPresent(record) -> {
      let LedgerRecord(recorded_request, _) = record
      case recorded_request == request {
        True -> #(ledger, w.RefreshCommandRecorded(public_record(record)))
        False -> #(ledger, w.RefreshCommandRejected(w.RefreshCommandConflict))
      }
    }
    RecordMissing ->
      case ledger_phase(ledger) {
        Ready -> {
          let context = ledger_context(ledger)
          case request_matches_context(request, owner, context) {
            False -> #(ledger, w.RefreshCommandRejected(w.RefreshSessionStale))
            True ->
              case
                w.refresh_dispatch_issued(
                  request,
                  context.tokens,
                  context.authentication,
                )
              {
                w.RefreshDispatchIssued(dispatch) -> #(
                  set_phase(ledger, InFlight(request, dispatch)),
                  w.RefreshDispatchIssued(dispatch),
                )
                w.RefreshCommandRejected(rejection) -> #(
                  ledger,
                  w.RefreshCommandRejected(rejection),
                )
                _ -> #(ledger, w.refresh_command_unknown(request))
              }
          }
        }
        InFlight(active_request, dispatch) -> {
          let w.RefreshReservationMetadata(_, active_id, _, _) =
            w.refresh_reservation_metadata(active_request)
          case active_request == request {
            True -> #(
              ledger,
              w.refresh_command_pending_from_dispatch(request, dispatch),
            )
            False ->
              case active_id == command_id {
                True -> #(
                  ledger,
                  w.RefreshCommandRejected(w.RefreshCommandConflict),
                )
                False -> #(
                  ledger,
                  w.refresh_command_busy_from_dispatch(request, dispatch),
                )
              }
          }
        }
        Quarantined(_, _) -> #(
          ledger,
          w.RefreshCommandRejected(w.RefreshGenerationQuarantined),
        )
      }
  }
}

fn ledger_settle(
  ledger: RefreshLedger,
  command: w.RefreshSettlementCommand,
) -> #(RefreshLedger, w.RefreshSettlementReply) {
  let w.RefreshSettlementContents(dispatch, value) =
    w.refresh_settlement_contents(command)
  let request = w.refresh_dispatch_reservation(dispatch)
  case ledger_phase(ledger) {
    InFlight(active_request, active_dispatch) ->
      case request == active_request && dispatch == active_dispatch {
        False -> #(ledger, w.refresh_settlement_unknown())
        True -> {
          let record = LedgerRecord(request, recorded_settlement(value))
          let next_records = [record, ..ledger_records(ledger)]
          let next_phase = case value {
            w.RefreshNoSend | w.RefreshEndpointRejected -> Ready
            w.RefreshProviderUnknown | w.RefreshAttestationInvalid(_) ->
              Quarantined(request, dispatch)
          }
          #(
            set_state(ledger, next_phase, next_records),
            w.refresh_settlement_unknown(),
          )
        }
      }
    Ready | Quarantined(_, _) -> #(ledger, w.refresh_settlement_unknown())
  }
}

fn ledger_publish(
  ledger: RefreshLedger,
  command: w.RefreshPublicationCommand,
  revision: w.CustodyRevision,
) -> #(RefreshLedger, w.RefreshPublicationReply) {
  let w.RefreshPublicationContents(request, dispatch, updated_tokens) =
    w.refresh_publication_contents(command)
  case ledger_phase(ledger) {
    InFlight(active_request, active_dispatch) ->
      case request == active_request && dispatch == active_dispatch {
        False -> #(ledger, w.refresh_publication_rejected())
        True -> {
          let context = ledger_context(ledger)
          let record =
            LedgerRecord(
              request,
              PublishedRecorded(command, context.reference, revision),
            )
          let updated_context =
            LedgerContext(
              context.owner,
              context.reference,
              revision,
              context.provider,
              context.installation,
              context.identity,
              updated_tokens,
              context.authentication,
            )
          let updated_ledger =
            RefreshLedger(updated_context, Ready, [
              record,
              ..ledger_records(ledger)
            ])
          #(updated_ledger, w.refresh_publication_unknown())
        }
      }
    Ready | Quarantined(_, _) -> #(ledger, w.refresh_publication_rejected())
  }
}

fn ledger_reservation_status(
  ledger: RefreshLedger,
  recovery: w.RefreshReservationRecovery,
) -> w.RefreshReservationStatus {
  let w.RefreshReservationRecoveryContents(_, request, _) =
    w.refresh_reservation_recovery_contents(recovery)
  let w.RefreshReservationMetadata(_, command_id, _, _) =
    w.refresh_reservation_metadata(request)
  case find_record(ledger_records(ledger), command_id) {
    RecordPresent(record) -> {
      let LedgerRecord(recorded_request, _) = record
      case recorded_request == request {
        True -> w.RefreshReservationRecorded(public_record(record))
        False -> w.RefreshReservationStatusUnknown
      }
    }
    RecordMissing ->
      case ledger_phase(ledger) {
        InFlight(active_request, _) ->
          case active_request == request {
            True -> w.RefreshReservationStillPending
            False -> w.RefreshReservationStatusUnknown
          }
        Quarantined(active_request, _) ->
          case active_request == request {
            True -> w.RefreshReservationStillQuarantined
            False -> w.RefreshReservationStatusUnknown
          }
        Ready -> w.RefreshReservationStatusUnknown
      }
  }
}

fn ledger_publication_status(
  ledger: RefreshLedger,
  recovery: w.RefreshPublicationRecovery,
) -> w.RefreshPublicationReply {
  let w.RefreshPublicationRecoveryContents(_, command) =
    w.refresh_publication_recovery_contents(recovery)
  let w.RefreshPublicationContents(request, _, _) =
    w.refresh_publication_contents(command)
  let w.RefreshReservationMetadata(_, command_id, _, _) =
    w.refresh_reservation_metadata(request)
  case find_record(ledger_records(ledger), command_id) {
    RecordPresent(record) -> {
      let LedgerRecord(recorded_request, value) = record
      case recorded_request == request {
        False -> w.refresh_publication_unknown()
        True ->
          case value {
            PublishedRecorded(accepted_command, reference, revision) ->
              case accepted_command == command {
                True ->
                  w.refresh_publication_accepted(
                    accepted_command,
                    reference,
                    revision,
                  )
                False -> w.refresh_publication_unknown()
              }
            _ -> w.refresh_publication_unknown()
          }
      }
    }
    RecordMissing -> w.refresh_publication_unknown()
  }
}

fn public_record(record: LedgerRecord) -> w.RefreshRecordedOutcome {
  let LedgerRecord(request, value) = record
  let recorded_value = case value {
    NoSendRecorded -> w.RefreshNoSendRecorded
    EndpointRejectedRecorded -> w.RefreshEndpointRejectionRecorded
    ProviderUnknownRecorded -> w.RefreshProviderQuarantinedRecorded
    InvalidResponseRecorded(error) -> w.RefreshInvalidResponseQuarantined(error)
    PublishedRecorded(command, reference, revision) -> {
      let receipt = case
        w.refresh_publication_accepted(command, reference, revision)
      {
        w.RefreshPublicationAccepted(receipt) -> receipt
        _ -> panic as "the helper must construct an accepted receipt"
      }
      w.RefreshPublicationRecorded(receipt)
    }
  }
  w.RefreshRecordedOutcome(request, recorded_value)
}

fn recorded_settlement(value: w.RefreshSettlementValue) -> RecordedValue {
  case value {
    w.RefreshNoSend -> NoSendRecorded
    w.RefreshEndpointRejected -> EndpointRejectedRecorded
    w.RefreshProviderUnknown -> ProviderUnknownRecorded
    w.RefreshAttestationInvalid(error) -> InvalidResponseRecorded(error)
  }
}

fn find_record(
  records: List(LedgerRecord),
  command_id: w.RefreshCommandId,
) -> RecordLookup {
  case records {
    [] -> RecordMissing
    [record, ..rest] -> {
      let LedgerRecord(request, _) = record
      let w.RefreshReservationMetadata(_, actual_id, _, _) =
        w.refresh_reservation_metadata(request)
      case actual_id == command_id {
        True -> RecordPresent(record)
        False -> find_record(rest, command_id)
      }
    }
  }
}

fn request_matches_context(
  request: w.RefreshReservationRequest,
  owner: w.CustodyOwnerId,
  context: LedgerContext,
) -> Bool {
  let w.RefreshReservationMetadata(actual_owner, _, session, provider) =
    w.refresh_reservation_metadata(request)
  actual_owner == owner
  && actual_owner == context.owner
  && provider == context.provider
  && w.session_provider_binding(session) == context.provider
  && w.session_custody_reference(session) == context.reference
  && w.session_custody_revision(session) == context.revision
  && w.session_installation_id(session) == context.installation
  && w.session_identity(session) == context.identity
}

fn owner_for(ledger: RefreshLedger) -> w.CustodyOwner {
  let context = ledger_context(ledger)
  owner_with_port(
    context.owner,
    w.refresh_port(
      fn(request) {
        let #(_, reply) = ledger_reserve(ledger, request)
        reply
      },
      fn(_) { w.refresh_settlement_unknown() },
      fn(_) { w.refresh_publication_unknown() },
      fn(recovery) { ledger_reservation_status(ledger, recovery) },
      fn(recovery) { ledger_publication_status(ledger, recovery) },
    ),
  )
}

fn pending_unknown_port(
  reserve_snapshot: RefreshLedger,
  recovery_snapshot: RefreshLedger,
) -> w.RefreshPort {
  w.refresh_port(
    fn(request) {
      let #(_, reply) = ledger_reserve(reserve_snapshot, request)
      case reply {
        w.RefreshDispatchIssued(_) -> w.refresh_command_unknown(request)
        _ -> reply
      }
    },
    fn(_) { w.refresh_settlement_unknown() },
    fn(_) { w.refresh_publication_unknown() },
    fn(recovery) { ledger_reservation_status(recovery_snapshot, recovery) },
    fn(recovery) { ledger_publication_status(recovery_snapshot, recovery) },
  )
}

fn owner_with_port(
  owner_id: w.CustodyOwnerId,
  port: w.RefreshPort,
) -> w.CustodyOwner {
  w.with_refresh(
    w.custody_owner(
      owner_id,
      fn(_) { panic as "refresh cannot reinstall login custody" },
      fn(_) { panic as "refresh cannot use login recovery" },
    ),
    port,
  )
}

fn assert_publication_recovery_stays_unresolved(
  owner_id: w.CustodyOwnerId,
  original_recovery: w.RefreshPublicationRecovery,
  returned_command: w.RefreshPublicationCommand,
  returned_reference: w.CustodyReference,
  returned_revision: w.CustodyRevision,
) -> Nil {
  let owner =
    owner_with_port(
      owner_id,
      w.refresh_port(
        fn(_) { panic as "publication recovery must not reserve" },
        panic_settlement,
        panic_publication,
        fn(_) {
          panic as "publication recovery must not query reservation state"
        },
        fn(_) {
          w.refresh_publication_accepted(
            returned_command,
            returned_reference,
            returned_revision,
          )
        },
      ),
    )
  let assert Ok(w.RefreshPublicationUnresolved(retained_recovery)) =
    w.recover_refresh_publication(owner, original_recovery)
  let assert True = retained_recovery == original_recovery
  Nil
}

fn panic_port() -> w.RefreshPort {
  w.refresh_port(
    fn(_) { panic as "owner or binding failure must precede reservation" },
    panic_settlement,
    panic_publication,
    fn(_) { panic as "owner failure must precede recovery" },
    fn(_) { panic as "owner failure must precede recovery" },
  )
}

fn panic_settlement(
  _command: w.RefreshSettlementCommand,
) -> w.RefreshSettlementReply {
  panic as "unexpected settlement callback"
}

fn panic_publication(
  _command: w.RefreshPublicationCommand,
) -> w.RefreshPublicationReply {
  panic as "invalid response must not publish"
}

fn panic_backend(_dispatch: w.RefreshDispatch) -> w.RefreshProviderOutcome {
  panic as "replay, mismatch, pending, or quarantine must not call provider"
}

fn reveal_request(
  owner_id: w.CustodyOwnerId,
  provider: w.ProviderBinding,
  session: w.Session,
  command_id: w.RefreshCommandId,
) -> w.RefreshReservationRequest {
  let owner =
    owner_with_port(
      owner_id,
      w.refresh_port(
        fn(request) { w.refresh_command_pending(request) },
        panic_settlement,
        panic_publication,
        fn(_) { w.RefreshReservationStatusUnknown },
        fn(_) { w.RefreshPublicationUnknown },
      ),
    )
  let assert Ok(w.RefreshReservationUnresolved(recovery)) =
    w.refresh_session(
      owner,
      w.refresh_backend(provider, panic_backend),
      session,
      command_id,
    )
  let w.RefreshReservationRecoveryContents(_, request, _) =
    w.refresh_reservation_recovery_contents(recovery)
  request
}

fn settle_invalid_response(
  ledger: RefreshLedger,
  session: w.Session,
  provider: w.ProviderBinding,
  command_name: String,
  attestation: w.RefreshAttestation,
) -> #(RefreshLedger, w.RefreshReservationRecovery) {
  let command_id = must_refresh_id(command_name)
  let assert Ok(w.RefreshReservationUnresolved(recovery)) =
    w.refresh_session(
      owner_for(ledger),
      w.refresh_backend(provider, fn(_) { w.RefreshAttested(attestation) }),
      session,
      command_id,
    )
  let w.RefreshReservationRecoveryContents(_, request, evidence) =
    w.refresh_reservation_recovery_contents(recovery)
  let #(reserved, reply) = ledger_reserve(ledger, request)
  let assert w.RefreshDispatchIssued(_) = reply
  let assert w.SubmittedRefreshSettlement(command) = evidence
  let #(quarantined, _) = ledger_settle(reserved, command)
  #(quarantined, recovery)
}

fn dispatch_for(
  request: w.RefreshReservationRequest,
  tokens: w.TokenMaterial,
  authentication: w.AuthenticationEvidence,
) -> w.RefreshDispatch {
  let assert w.RefreshDispatchIssued(dispatch) =
    w.refresh_dispatch_issued(request, tokens, authentication)
  dispatch
}

fn set_phase(ledger: RefreshLedger, phase: ReservationPhase) -> RefreshLedger {
  set_state(ledger, phase, ledger_records(ledger))
}

fn set_state(
  ledger: RefreshLedger,
  phase: ReservationPhase,
  records: List(LedgerRecord),
) -> RefreshLedger {
  RefreshLedger(ledger_context(ledger), phase, records)
}

fn ledger_context(ledger: RefreshLedger) -> LedgerContext {
  let RefreshLedger(context, _, _) = ledger
  context
}

fn ledger_phase(ledger: RefreshLedger) -> ReservationPhase {
  let RefreshLedger(_, phase, _) = ledger
  phase
}

fn ledger_records(ledger: RefreshLedger) -> List(LedgerRecord) {
  let RefreshLedger(_, _, records) = ledger
  records
}

fn ledger_tokens(ledger: RefreshLedger) -> w.TokenMaterial {
  let LedgerContext(_, _, _, _, _, _, tokens, _) = ledger_context(ledger)
  tokens
}

fn login_fixture(name: String) -> LoginFixture {
  let issuer = must_issuer("https://login.example")
  let client_id = must_client_id("refresh-client")
  let client =
    w.client(
      issuer,
      client_id,
      must_redirect_uri("https://app.example/callback"),
    )
  let nonce = must_nonce("refresh-nonce")
  let state = must_state("state-" <> name)
  let transaction_id = must_transaction_id(name)
  let assert Ok(#(_, transaction)) =
    w.plan_login(
      client,
      transaction_id,
      w.LoginMaterial(
        state,
        nonce,
        must_pkce_verifier("refresh-verifier"),
        must_pkce_challenge("refresh-challenge"),
      ),
      must_timestamp(10),
      must_timestamp(100),
    )
  let revision = must_stored_revision("revision-" <> name)
  let pending = w.trusted_rehydrate_pending(transaction, revision)
  let callback =
    w.Callback(issuer, state, w.AuthorizationCodeReceived("code-" <> name))
  let assert Ok(checked) = w.check_callback(pending, callback)
  LoginFixture(
    issuer,
    client_id,
    client,
    nonce,
    transaction_id,
    checked,
    w.transaction_store(
      w.clock(fn() { must_timestamp(99) }),
      fn(command, locked_clock) {
        let w.ConsumeCommandMetadata(actual_id, actual_revision) =
          w.consume_command_metadata(command)
        let assert True = actual_id == transaction_id
        let assert True = actual_revision == revision
        let #(next, decision) =
          w.decide_consume(
            pending,
            command,
            w.sample_locked_clock(locked_clock),
          )
        let assert w.ConsumedStatus = w.stored_status(next)
        w.Decided(decision)
      },
    ),
  )
}

fn token_material(
  access: String,
  refresh: w.RefreshTokenChoice,
  logout: w.LogoutIdTokenChoice,
) -> w.TokenMaterial {
  w.token_material(
    must_access_token(access),
    refresh,
    logout,
    must_expiry(1_900_000_000),
    [must_scope("openid"), must_scope("profile")],
  )
}

fn declaration(name: String) -> w.AdapterDeclaration {
  w.AdapterDeclaration(name, "scripted-v1", w.TestOnlyAdapter)
}

fn must_owner_id(value: String) -> w.CustodyOwnerId {
  let assert Ok(result) = w.custody_owner_id(value)
  result
}

fn must_reference(value: String) -> w.CustodyReference {
  let assert Ok(result) = w.custody_reference(value)
  result
}

fn must_revision(value: String) -> w.CustodyRevision {
  let assert Ok(result) = w.custody_revision(value)
  result
}

fn must_stored_revision(value: String) -> w.StoredRevision {
  let assert Ok(result) = w.stored_revision(value)
  result
}

fn must_refresh_id(value: String) -> w.RefreshCommandId {
  let assert Ok(result) = w.refresh_command_id(value)
  result
}

fn must_issuer(value: String) -> w.Issuer {
  let assert Ok(result) = w.issuer(value)
  result
}

fn must_client_id(value: String) -> w.ClientId {
  let assert Ok(result) = w.client_id(value)
  result
}

fn must_redirect_uri(value: String) -> w.RedirectUri {
  let assert Ok(result) = w.redirect_uri(value)
  result
}

fn must_nonce(value: String) -> w.Nonce {
  let assert Ok(result) = w.nonce(value)
  result
}

fn must_state(value: String) -> w.State {
  let assert Ok(result) = w.state(value)
  result
}

fn must_transaction_id(value: String) -> w.TransactionId {
  let assert Ok(result) = w.transaction_id(value)
  result
}

fn must_pkce_verifier(value: String) -> w.PkceVerifier {
  let assert Ok(result) = w.pkce_verifier(value)
  result
}

fn must_pkce_challenge(value: String) -> w.PkceChallenge {
  let assert Ok(result) = w.pkce_challenge(value)
  result
}

fn must_timestamp(value: Int) -> w.Timestamp {
  let assert Ok(result) = w.timestamp(value)
  result
}

fn must_access_token(value: String) -> w.AccessToken {
  let assert Ok(result) = w.access_token(value)
  result
}

fn must_refresh_token(value: String) -> w.RefreshToken {
  let assert Ok(result) = w.refresh_token(value)
  result
}

fn must_logout_id_token(value: String) -> w.LogoutIdToken {
  let assert Ok(result) = w.logout_id_token(value)
  result
}

fn must_expiry(value: Int) -> w.TokenExpiry {
  let assert Ok(result) = w.token_expiry_unix_seconds(value)
  result
}

fn must_scope(value: String) -> w.Scope {
  let assert Ok(result) = w.scope(value)
  result
}
