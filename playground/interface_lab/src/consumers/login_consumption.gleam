// THROWAWAY: Can checked OIDC callbacks cross one revision-bound atomic consume port?
import lab/warden_transaction as login

pub fn probe() -> Nil {
  let issuer = must(login.issuer("https://issuer.example"))
  let client =
    login.client(
      issuer,
      must(login.client_id("client")),
      must(login.redirect_uri("https://app.example/callback")),
    )
  let transaction_id = must(login.transaction_id("login-1"))
  let state = must(login.state("state-1"))
  let material =
    login.LoginMaterial(
      state,
      must(login.nonce("nonce-1")),
      must(login.pkce_verifier("verifier-1")),
      must(login.pkce_challenge("challenge-1")),
    )
  let assert Ok(#(_, transaction)) =
    login.plan_login(
      client,
      transaction_id,
      material,
      timestamp(10),
      timestamp(100),
    )
  let initial_revision = revision("pending-r1")
  let pending = login.trusted_rehydrate_pending(transaction, initial_revision)
  let code_callback =
    login.Callback(
      issuer,
      state,
      login.AuthorizationCodeReceived("secret-code"),
    )
  let assert Ok(code_outcome) = login.check_callback(pending, code_callback)
  let assert Ok(login.CodeReady(_)) =
    login.check_callback(pending, code_callback)

  // Repeated pure checks create copyable commands for the same immutable row.
  let command = login.consume_command(code_outcome)
  let login.ConsumeCommandMetadata(command_id, command_revision) =
    login.consume_command_metadata(command)
  let assert True = transaction_id == command_id
  let assert True = initial_revision == command_revision
  let assert login.CodeConsumed = consume_success(code_outcome)
  let assert #(consumed, login.WasConsumed) =
    login.decide_consume(pending, command, timestamp(99))
  let assert login.ConsumedStatus = login.stored_status(consumed)
  let assert #(same_consumed, login.AlreadyConsumed) =
    login.decide_consume(consumed, command, timestamp(99))
  let assert True = consumed == same_consumed

  // A terminal tombstone wins over an old revision; identifier mismatch wins
  // even earlier. The terminal record carries no callback secret material.
  let newer_terminal_revision = revision("terminal-r2")
  let terminal =
    login.trusted_rehydrate_consumed(transaction_id, newer_terminal_revision)
  let assert #(same_terminal, login.AlreadyConsumed) =
    login.decide_consume(terminal, command, timestamp(99))
  let assert True = terminal == same_terminal
  let other_id = must(login.transaction_id("other-login"))
  let other_transaction =
    login.trusted_rehydrate_transaction(
      other_id,
      client,
      state,
      must(login.nonce("nonce-other")),
      must(login.pkce_verifier("verifier-other")),
      timestamp(100),
    )
  let other_pending =
    login.trusted_rehydrate_pending(other_transaction, revision("other-r1"))
  let other_callback =
    login.Callback(issuer, state, login.AuthorizationCodeReceived("other-code"))
  let assert Ok(other_outcome) =
    login.check_callback(other_pending, other_callback)
  let other_command = login.consume_command(other_outcome)
  let assert #(same_terminal_after_wrong_id, login.ChangedSinceCheck) =
    login.decide_consume(terminal, other_command, timestamp(99))
  let assert True = terminal == same_terminal_after_wrong_id
  let expired_tombstone =
    login.trusted_rehydrate_expired(transaction_id, newer_terminal_revision)
  let assert #(same_expired, login.ExpiredDuringConsume) =
    login.decide_consume(expired_tombstone, command, timestamp(99))
  let assert True = expired_tombstone == same_expired

  // A stale pending revision is rejected before the expiry clock is considered.
  let changed_pending =
    login.trusted_rehydrate_pending(transaction, revision("pending-r2"))
  let assert #(same_changed, login.ChangedSinceCheck) =
    login.decide_consume(changed_pending, command, timestamp(100))
  let assert True = changed_pending == same_changed

  // The external port receives a clock capability, not a caller timestamp or
  // current row. This scripted adapter samples at the exact expiry boundary.
  let exact_store =
    login.transaction_store(
      login.clock(fn() { timestamp(100) }),
      fn(received_command, locked_clock) {
        let locked_now = login.sample_locked_clock(locked_clock)
        let #(after, decision) =
          login.decide_consume(pending, received_command, locked_now)
        let assert login.ExpiredStatus = login.stored_status(after)
        let assert login.ExpiredDuringConsume = decision
        login.Decided(decision)
      },
    )
  let assert Error(login.TransactionExpired) =
    login.consume_callback(exact_store, code_outcome)

  // Provider denial is also consumed once. Its raw reason and the checked
  // authorization code never appear in the public result or command metadata.
  let denial_callback =
    login.Callback(issuer, state, login.CallbackRejected("access_denied"))
  let assert Ok(denial_outcome) = login.check_callback(pending, denial_callback)
  let assert login.DenialConsumed(login.AccessDenied) =
    consume_success(denial_outcome)
  let denial_command = login.consume_command(denial_outcome)
  let assert #(denial_tombstone, login.WasConsumed) =
    login.decide_consume(pending, denial_command, timestamp(99))
  let assert login.ConsumedStatus = login.stored_status(denial_tombstone)
  let assert #(same_denial_tombstone, login.AlreadyConsumed) =
    login.decide_consume(denial_tombstone, denial_command, timestamp(99))
  let assert True = denial_tombstone == same_denial_tombstone
  let denial_replay_store = reply_store(login.Decided(login.AlreadyConsumed))
  let assert Error(login.CallbackAlreadyConsumed) =
    login.consume_callback(denial_replay_store, denial_outcome)

  let other_denial =
    login.Callback(issuer, state, login.CallbackRejected("provider_error"))
  let assert Ok(login.ProviderDenied(other_denial_checked)) =
    login.check_callback(pending, other_denial)
  let assert login.OtherDenied =
    login.denial_classification(other_denial_checked)
  let assert login.DenialConsumed(login.OtherDenied) =
    consume_success(login.ProviderDenied(other_denial_checked))

  // Invalid binding/shape checks do not consume the pending row.
  let wrong_state =
    login.Callback(
      issuer,
      must(login.state("wrong-state")),
      login.AuthorizationCodeReceived("code"),
    )
  let assert Error(login.StateMismatch) =
    login.check_callback(pending, wrong_state)
  let wrong_issuer =
    login.Callback(
      must(login.issuer("https://wrong.example")),
      state,
      login.AuthorizationCodeReceived("code"),
    )
  let assert Error(login.IssuerMismatch) =
    login.check_callback(pending, wrong_issuer)
  let assert Error(login.AuthorizationCodeMissing) =
    login.check_callback(
      pending,
      login.Callback(issuer, state, login.CallbackWithoutCode),
    )
  let assert Error(login.AuthorizationCodeEmpty) =
    login.check_callback(
      pending,
      login.Callback(issuer, state, login.AuthorizationCodeReceived("")),
    )
  let assert Error(login.CallbackAlreadyUsed) =
    login.check_callback(terminal, code_callback)
  let expired =
    login.trusted_rehydrate_expired(transaction_id, initial_revision)
  let assert Error(login.CallbackExpired) =
    login.check_callback(expired, code_callback)
  let assert login.PendingStatus = login.stored_status(pending)

  // The storage port distinguishes absent, unavailable, and uncertain commits.
  let missing = reply_store(login.Missing)
  let assert Error(login.TransactionMissing) =
    login.consume_callback(missing, code_outcome)
  let unavailable = reply_store(login.Unavailable(login.StoreUnavailableCode))
  let assert Error(login.StoreUnavailable(login.StoreUnavailableCode)) =
    login.consume_callback(unavailable, code_outcome)
  let uncertain = reply_store(login.CommitUnknown)
  let assert Error(login.CommitOutcomeUnknown) =
    login.consume_callback(uncertain, code_outcome)
  Nil
}

fn consume_success(checked: login.CheckedOutcome) -> login.PublicConsumption {
  let store = reply_store(login.Decided(login.WasConsumed))
  let assert Ok(result) = login.consume_callback(store, checked)
  result
}

fn reply_store(reply: login.StoreReply) -> login.TransactionStore {
  login.transaction_store(
    login.clock(fn() { timestamp(1) }),
    fn(_command, _clock) { reply },
  )
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
