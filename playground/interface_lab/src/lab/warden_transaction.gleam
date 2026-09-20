// THROWAWAY: Can login transaction checks precede, but not impersonate, token verification?
// Host code injects synthetic flow material; this module supplies no entropy,
// URL assembly, protocol transport, persistence, or token verification.

pub type InputError {
  ValueMustNotBeEmpty
  TimestampMustNotBeNegative
}

pub type PlanError {
  ExpirationMustBeInTheFuture
}

pub type CallbackCheckError {
  StateMismatch
  IssuerMismatch
  TransactionExpired
  AuthorizationCodeMissing
  AuthorizationCodeEmpty
  ProviderRejected(String)
}

pub opaque type Issuer {
  Issuer(String)
}

pub opaque type ClientId {
  ClientId(String)
}

pub opaque type RedirectUri {
  RedirectUri(String)
}

pub opaque type TransactionId {
  TransactionId(String)
}

pub opaque type State {
  State(String)
}

pub opaque type Nonce {
  Nonce(String)
}

pub opaque type PkceVerifier {
  PkceVerifier(String)
}

pub opaque type PkceChallenge {
  PkceChallenge(String)
}

pub opaque type AuthorizationCode {
  AuthorizationCode(String)
}

pub opaque type Timestamp {
  Timestamp(Int)
}

pub fn issuer(value: String) -> Result(Issuer, InputError) {
  checked_text(value, Issuer)
}

pub fn client_id(value: String) -> Result(ClientId, InputError) {
  checked_text(value, ClientId)
}

pub fn redirect_uri(value: String) -> Result(RedirectUri, InputError) {
  checked_text(value, RedirectUri)
}

pub fn transaction_id(value: String) -> Result(TransactionId, InputError) {
  checked_text(value, TransactionId)
}

pub fn state(value: String) -> Result(State, InputError) {
  checked_text(value, State)
}

pub fn nonce(value: String) -> Result(Nonce, InputError) {
  checked_text(value, Nonce)
}

pub fn pkce_verifier(value: String) -> Result(PkceVerifier, InputError) {
  checked_text(value, PkceVerifier)
}

pub fn pkce_challenge(value: String) -> Result(PkceChallenge, InputError) {
  checked_text(value, PkceChallenge)
}

// This laboratory timestamp uses seconds since the Unix epoch. No clock runs.
pub fn timestamp(value: Int) -> Result(Timestamp, InputError) {
  case value {
    seconds if seconds >= 0 -> Ok(Timestamp(seconds))
    _ -> Error(TimestampMustNotBeNegative)
  }
}

pub opaque type Client {
  Client(issuer: Issuer, id: ClientId, redirect_uri: RedirectUri)
}

pub fn client(
  issuer: Issuer,
  id: ClientId,
  redirect_uri: RedirectUri,
) -> Client {
  Client(issuer, id, redirect_uri)
}

pub type LoginMaterial {
  LoginMaterial(
    state: State,
    nonce: Nonce,
    verifier: PkceVerifier,
    challenge: PkceChallenge,
  )
}

pub type AuthorizationRequest {
  AuthorizationRequest(
    issuer: Issuer,
    client_id: ClientId,
    redirect_uri: RedirectUri,
    state: State,
    nonce: Nonce,
    pkce_challenge: PkceChallenge,
  )
}

pub opaque type Transaction {
  Transaction(
    id: TransactionId,
    client: Client,
    state: State,
    nonce: Nonce,
    verifier: PkceVerifier,
    expires_at: Timestamp,
  )
}

pub fn plan_login(
  client: Client,
  id: TransactionId,
  material: LoginMaterial,
  now: Timestamp,
  expires_at: Timestamp,
) -> Result(#(AuthorizationRequest, Transaction), PlanError) {
  let Client(issuer, client_id, redirect_uri) = client
  let LoginMaterial(state, nonce, verifier, challenge) = material
  let Timestamp(current_time) = now
  let Timestamp(expiry) = expires_at
  case expiry > current_time {
    False -> Error(ExpirationMustBeInTheFuture)
    True ->
      Ok(#(
        AuthorizationRequest(
          issuer,
          client_id,
          redirect_uri,
          state,
          nonce,
          challenge,
        ),
        Transaction(id, client, state, nonce, verifier, expires_at),
      ))
  }
}

pub type CallbackCode {
  AuthorizationCodeReceived(String)
  CallbackWithoutCode
  CallbackRejected(String)
}

// Issuer is part of the callback profile and must match the transaction's
// configured client. Parsing/normalizing an external response is a boundary.
pub type Callback {
  Callback(issuer: Issuer, state: State, code: CallbackCode)
}

pub opaque type CheckedCallback {
  CheckedCallback(transaction: Transaction, code: AuthorizationCode)
}

// This checked value is copyable and in memory; it is not a consume-once
// transaction and does not establish a verified identity.
pub fn check_callback(
  transaction: Transaction,
  callback: Callback,
  now: Timestamp,
) -> Result(CheckedCallback, CallbackCheckError) {
  let Transaction(
    _,
    Client(expected_issuer, _, _),
    expected_state,
    _,
    _,
    expires_at,
  ) = transaction
  let Callback(actual_issuer, actual_state, code_shape) = callback
  let Timestamp(current_time) = now
  let Timestamp(expiry) = expires_at
  case actual_state == expected_state {
    False -> Error(StateMismatch)
    True ->
      case actual_issuer == expected_issuer {
        False -> Error(IssuerMismatch)
        True ->
          case current_time < expiry {
            False -> Error(TransactionExpired)
            True -> checked_code(transaction, code_shape)
          }
      }
  }
}

fn checked_code(
  transaction: Transaction,
  shape: CallbackCode,
) -> Result(CheckedCallback, CallbackCheckError) {
  case shape {
    AuthorizationCodeReceived("") -> Error(AuthorizationCodeEmpty)
    AuthorizationCodeReceived(code) ->
      Ok(CheckedCallback(transaction, AuthorizationCode(code)))
    CallbackWithoutCode -> Error(AuthorizationCodeMissing)
    CallbackRejected(reason) -> Error(ProviderRejected(reason))
  }
}

fn checked_text(value: String, wrap: fn(String) -> a) -> Result(a, InputError) {
  case value {
    "" -> Error(ValueMustNotBeEmpty)
    _ -> Ok(wrap(value))
  }
}
