// THROWAWAY: Can callback checks feed one revision-bound atomic consumption boundary?
// This type experiment supplies neither entropy nor token verification. A
// configured adapter is an explicit trust boundary, not cryptographic proof;
// callback exceptions and retained request copies are not managed here. The
// store callback owns the record and samples its clock after entering its
// atomic section. Gleam values are copyable; this reducer proves no concurrency.

pub type InputError {
  ValueMustNotBeEmpty
  TimestampMustNotBeNegative
  ScopeTokenInvalid
}

pub type PlanError {
  ExpirationMustBeInTheFuture
}

pub type CallbackCheckError {
  StateMismatch
  IssuerMismatch
  AuthorizationCodeMissing
  AuthorizationCodeEmpty
  CallbackAlreadyUsed
  CallbackExpired
}

pub type StoredRevisionError {
  RevisionMustNotBeEmpty
}

pub type DenialClass {
  AccessDenied
  OtherDenied
}

pub type StoreFailureCode {
  StoreUnavailableCode
  StoreRejectedWrite
  StoreFailureUnclassified
}

pub type ConsumeError {
  TransactionMissing
  TransactionExpired
  CallbackAlreadyConsumed
  TransactionChanged
  StoreUnavailable(StoreFailureCode)
  CommitOutcomeUnknown
}

pub type PublicConsumption {
  CodeConsumed
  DenialConsumed(DenialClass)
}

pub type AdapterPurpose {
  TrustedAdapter
  TestOnlyAdapter
}

pub type AdapterDeclaration {
  AdapterDeclaration(name: String, version: String, purpose: AdapterPurpose)
}

pub type AuthorizedParty {
  NoAuthorizedParty
  AuthorizedParty(ClientId)
}

pub type AudiencePolicy {
  ExactSingletonClient
}

pub type VerificationProfile {
  VerificationProfile(
    require_nonce: Bool,
    require_pkce: Bool,
    audience_policy: AudiencePolicy,
    require_id_token: Bool,
  )
}

// A custom adapter attests only the claims this experiment consumes. Its
// constructor is public by design; it remains an adapter assertion, not proof.
pub type BackendAttestation {
  BackendAttestation(
    issuer: Issuer,
    audiences: List(ClientId),
    authorized_party: AuthorizedParty,
    subject: String,
  )
}

// A successful exchange carries the identity assertion, exact token material,
// and authentication evidence as one adapter result. Its public constructor
// remains an adapter assertion, not cryptographic proof.
pub type LoginAttestation {
  LoginAttestation(
    identity: BackendAttestation,
    tokens: TokenMaterial,
    authentication: AuthenticationEvidence,
  )
}

pub type BackendError {
  ExchangeRejected
  ExchangeOutcomeUnknown
  MissingIdToken
  InvalidSignature
  InvalidNonce
  InvalidTokenTime
  BackendUnmapped
}

pub type CompleteLoginError {
  ConsumptionFailed(ConsumeError)
  BackendConfigurationMismatch
  ProviderRejection(DenialClass)
  BackendFailed(BackendError)
  AttestedIssuerMismatch
  AttestedAudienceMismatch
  AuthorizedPartyMismatch
  SubjectMissing
  AuthenticationNonceMismatch
  CustodyInstallRejected(CustodyFailure)
}

pub type ExchangeParameters {
  ExchangeParameters(
    issuer: String,
    client_id: String,
    redirect_uri: String,
    authorization_code: String,
    nonce: String,
    pkce_verifier: String,
    profile: VerificationProfile,
  )
}

pub type ConsumeDecision {
  WasConsumed
  ExpiredDuringConsume
  AlreadyConsumed
  ChangedSinceCheck
}

pub type StoreReply {
  Decided(ConsumeDecision)
  Missing
  Unavailable(StoreFailureCode)
  CommitUnknown
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

// These wrappers distinguish token kinds at API boundaries. They do not
// encrypt values or prevent VM inspection by trusted code.
pub opaque type AccessToken {
  AccessToken(String)
}

pub opaque type RefreshToken {
  RefreshToken(String)
}

pub opaque type LogoutIdToken {
  LogoutIdToken(String)
}

pub opaque type TokenExpiry {
  TokenExpiry(unix_seconds: Int)
}

pub opaque type Scope {
  Scope(String)
}

pub type RefreshTokenChoice {
  NoRefreshToken
  RefreshTokenPresent(RefreshToken)
}

pub type LogoutIdTokenChoice {
  NoLogoutIdToken
  LogoutIdTokenPresent(LogoutIdToken)
}

pub opaque type TokenMaterial {
  TokenMaterial(
    access_token: AccessToken,
    refresh_token: RefreshTokenChoice,
    logout_id_token: LogoutIdTokenChoice,
    expires_at: TokenExpiry,
    scopes: List(Scope),
  )
}

pub type TokenMaterialMetadata {
  TokenMaterialMetadata(
    has_refresh_token: Bool,
    has_logout_id_token: Bool,
    expires_at_unix_seconds: Int,
    scopes: List(String),
  )
}

pub type TrustedTokenChoice {
  NoTrustedToken
  TrustedTokenValue(String)
}

pub type TrustedTokenMaterialView {
  TrustedTokenMaterialView(
    access_token: String,
    refresh_token: TrustedTokenChoice,
    logout_id_token: TrustedTokenChoice,
    expires_at_unix_seconds: Int,
    scopes: List(String),
  )
}

pub type AuthenticationTime {
  NoAuthenticationTime
  AuthenticationTimePresent(Timestamp)
}

pub type AuthenticationEvidence {
  AuthenticationEvidence(
    original_nonce: Nonce,
    authentication_time: AuthenticationTime,
  )
}

pub opaque type StoredRevision {
  StoredRevision(String)
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

// The store supplies a fresh revision whenever immutable transaction material
// changes. Terminal transitions retain the revision that identifies the
// consumed or expired material. Freshness across processes is a store duty.
pub fn stored_revision(
  value: String,
) -> Result(StoredRevision, StoredRevisionError) {
  case value {
    "" -> Error(RevisionMustNotBeEmpty)
    _ -> Ok(StoredRevision(value))
  }
}

pub fn revision_value(revision: StoredRevision) -> String {
  let StoredRevision(value) = revision
  value
}

// This laboratory timestamp uses seconds since the Unix epoch. No clock runs
// unless an adapter invokes its injected callback.
pub fn timestamp(value: Int) -> Result(Timestamp, InputError) {
  case value {
    seconds if seconds >= 0 -> Ok(Timestamp(seconds))
    _ -> Error(TimestampMustNotBeNegative)
  }
}

pub fn access_token(value: String) -> Result(AccessToken, InputError) {
  checked_text(value, AccessToken)
}

pub fn refresh_token(value: String) -> Result(RefreshToken, InputError) {
  checked_text(value, RefreshToken)
}

pub fn logout_id_token(value: String) -> Result(LogoutIdToken, InputError) {
  checked_text(value, LogoutIdToken)
}

pub fn token_expiry_unix_seconds(
  unix_seconds: Int,
) -> Result(TokenExpiry, InputError) {
  case unix_seconds >= 0 {
    True -> Ok(TokenExpiry(unix_seconds))
    False -> Error(TimestampMustNotBeNegative)
  }
}

pub fn scope(value: String) -> Result(Scope, InputError) {
  case valid_scope_token(scope_bytes(value)) {
    True -> Ok(Scope(value))
    False -> Error(ScopeTokenInvalid)
  }
}

pub fn token_material(
  access_token: AccessToken,
  refresh_token: RefreshTokenChoice,
  logout_id_token: LogoutIdTokenChoice,
  expires_at: TokenExpiry,
  scopes: List(Scope),
) -> TokenMaterial {
  TokenMaterial(
    access_token,
    refresh_token,
    logout_id_token,
    expires_at,
    normalize_scopes(scopes),
  )
}

pub fn token_material_metadata(
  material: TokenMaterial,
) -> TokenMaterialMetadata {
  let TokenMaterial(
    _,
    refresh_token,
    logout_id_token,
    TokenExpiry(expires),
    scopes,
  ) = material
  TokenMaterialMetadata(
    has_refresh_token: has_refresh_token(refresh_token),
    has_logout_id_token: has_logout_id_token(logout_id_token),
    expires_at_unix_seconds: expires,
    scopes: scope_values(scopes),
  )
}

// These accessors are for trusted adapters that must serialize a token or
// attach it to an authenticated request. They expose secrets to the caller.
pub fn trusted_token_material_view(
  material: TokenMaterial,
) -> TrustedTokenMaterialView {
  let TokenMaterial(access, refresh, logout, TokenExpiry(expires), scopes) =
    material
  TrustedTokenMaterialView(
    trusted_access_token_value(access),
    trusted_refresh_token_choice(refresh),
    trusted_logout_id_token_choice(logout),
    expires,
    scope_values(scopes),
  )
}

pub fn trusted_access_token_value(token: AccessToken) -> String {
  let AccessToken(value) = token
  value
}

pub fn trusted_refresh_token_value(token: RefreshToken) -> String {
  let RefreshToken(value) = token
  value
}

pub fn trusted_logout_id_token_value(token: LogoutIdToken) -> String {
  let LogoutIdToken(value) = token
  value
}

pub fn authentication_evidence(
  original_nonce: Nonce,
  authentication_time: AuthenticationTime,
) -> AuthenticationEvidence {
  AuthenticationEvidence(original_nonce, authentication_time)
}

// Erlang strings are UTF-8 binaries. This boundary bridge exposes raw bytes so
// the pure Gleam validator can reject every non-RFC-6749 scope byte.
@external(erlang, "erlang", "binary_to_list")
fn scope_bytes(value: String) -> List(Int)

fn valid_scope_token(bytes: List(Int)) -> Bool {
  case bytes {
    [] -> False
    [first, ..rest] -> valid_scope_byte(first) && valid_scope_bytes(rest)
  }
}

fn valid_scope_bytes(remaining: List(Int)) -> Bool {
  case remaining {
    [] -> True
    [byte, ..rest] -> valid_scope_byte(byte) && valid_scope_bytes(rest)
  }
}

fn valid_scope_byte(byte: Int) -> Bool {
  byte == 33 || byte >= 35 && byte <= 91 || byte >= 93 && byte <= 126
}

fn normalize_scopes(scopes: List(Scope)) -> List(Scope) {
  normalize_scopes_from(scopes, [], [])
}

fn normalize_scopes_from(
  remaining: List(Scope),
  seen: List(Scope),
  reversed: List(Scope),
) -> List(Scope) {
  case remaining {
    [] -> reverse_scopes(reversed, [])
    [next, ..rest] ->
      case contains_scope(next, seen) {
        True -> normalize_scopes_from(rest, seen, reversed)
        False -> normalize_scopes_from(rest, [next, ..seen], [next, ..reversed])
      }
  }
}

fn contains_scope(scope: Scope, scopes: List(Scope)) -> Bool {
  case scopes {
    [] -> False
    [next, ..rest] -> scope == next || contains_scope(scope, rest)
  }
}

fn reverse_scopes(
  remaining: List(Scope),
  reversed: List(Scope),
) -> List(Scope) {
  case remaining {
    [] -> reversed
    [next, ..rest] -> reverse_scopes(rest, [next, ..reversed])
  }
}

fn scope_values(scopes: List(Scope)) -> List(String) {
  case scopes {
    [] -> []
    [Scope(value), ..rest] -> [value, ..scope_values(rest)]
  }
}

fn has_refresh_token(choice: RefreshTokenChoice) -> Bool {
  case choice {
    NoRefreshToken -> False
    RefreshTokenPresent(_) -> True
  }
}

fn has_logout_id_token(choice: LogoutIdTokenChoice) -> Bool {
  case choice {
    NoLogoutIdToken -> False
    LogoutIdTokenPresent(_) -> True
  }
}

fn trusted_refresh_token_choice(
  choice: RefreshTokenChoice,
) -> TrustedTokenChoice {
  case choice {
    NoRefreshToken -> NoTrustedToken
    RefreshTokenPresent(token) ->
      TrustedTokenValue(trusted_refresh_token_value(token))
  }
}

fn trusted_logout_id_token_choice(
  choice: LogoutIdTokenChoice,
) -> TrustedTokenChoice {
  case choice {
    NoLogoutIdToken -> NoTrustedToken
    LogoutIdTokenPresent(token) ->
      TrustedTokenValue(trusted_logout_id_token_value(token))
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

// A trusted persistence adapter may rebuild an immutable transaction from its
// own secret store. This function deliberately accepts typed secret material;
// it is not a parser for untrusted callback data.
pub fn trusted_rehydrate_transaction(
  id: TransactionId,
  client: Client,
  state: State,
  nonce: Nonce,
  verifier: PkceVerifier,
  expires_at: Timestamp,
) -> Transaction {
  Transaction(id, client, state, nonce, verifier, expires_at)
}

pub type TransactionMetadata {
  TransactionMetadata(
    id: TransactionId,
    issuer: Issuer,
    client_id: ClientId,
    redirect_uri: RedirectUri,
    expires_at: Timestamp,
  )
}

// Safe descriptive metadata. State, nonce, verifier, code, and token values
// have no metadata accessors.
pub fn transaction_metadata(transaction: Transaction) -> TransactionMetadata {
  let Transaction(
    id,
    Client(issuer, client_id, redirect_uri),
    _,
    _,
    _,
    expires_at,
  ) = transaction
  TransactionMetadata(id, issuer, client_id, redirect_uri, expires_at)
}

pub fn transaction_expiry(transaction: Transaction) -> Timestamp {
  let Transaction(_, _, _, _, _, expires_at) = transaction
  expires_at
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

pub opaque type StoredTransaction {
  PendingRecord(transaction: Transaction, revision: StoredRevision)
  ConsumedRecord(id: TransactionId, revision: StoredRevision)
  ExpiredRecord(id: TransactionId, revision: StoredRevision)
}

// These constructors are the explicit trusted-adapter boundary for loading a
// row. A durable adapter remains responsible for preserving secret material
// and never reusing a revision for changed immutable material.
pub fn trusted_rehydrate_pending(
  transaction: Transaction,
  revision: StoredRevision,
) -> StoredTransaction {
  PendingRecord(transaction, revision)
}

pub fn trusted_rehydrate_consumed(
  id: TransactionId,
  revision: StoredRevision,
) -> StoredTransaction {
  ConsumedRecord(id, revision)
}

pub fn trusted_rehydrate_expired(
  id: TransactionId,
  revision: StoredRevision,
) -> StoredTransaction {
  ExpiredRecord(id, revision)
}

pub type StoredStatus {
  PendingStatus
  ConsumedStatus
  ExpiredStatus
}

pub type StoredMetadata {
  StoredMetadata(
    id: TransactionId,
    revision: StoredRevision,
    status: StoredStatus,
  )
}

pub fn stored_metadata(stored: StoredTransaction) -> StoredMetadata {
  case stored {
    PendingRecord(transaction, revision) -> {
      let Transaction(id, _, _, _, _, _) = transaction
      StoredMetadata(id, revision, PendingStatus)
    }
    ConsumedRecord(id, revision) -> StoredMetadata(id, revision, ConsumedStatus)
    ExpiredRecord(id, revision) -> StoredMetadata(id, revision, ExpiredStatus)
  }
}

pub fn stored_transaction_id(stored: StoredTransaction) -> TransactionId {
  let StoredMetadata(id, _, _) = stored_metadata(stored)
  id
}

pub fn stored_revision_of(stored: StoredTransaction) -> StoredRevision {
  let StoredMetadata(_, revision, _) = stored_metadata(stored)
  revision
}

pub fn stored_status(stored: StoredTransaction) -> StoredStatus {
  let StoredMetadata(_, _, status) = stored_metadata(stored)
  status
}

pub opaque type CheckedCallback {
  CheckedCallback(
    transaction: Transaction,
    revision: StoredRevision,
    code: AuthorizationCode,
  )
}

pub opaque type CheckedDenial {
  CheckedDenial(
    id: TransactionId,
    revision: StoredRevision,
    client: Client,
    classification: DenialClass,
  )
}

pub type CheckedOutcome {
  CodeReady(CheckedCallback)
  ProviderDenied(CheckedDenial)
}

pub fn denial_classification(denial: CheckedDenial) -> DenialClass {
  denial.classification
}

pub fn checked_outcome_id(outcome: CheckedOutcome) -> TransactionId {
  case outcome {
    CodeReady(CheckedCallback(transaction, _, _)) -> {
      let Transaction(id, _, _, _, _, _) = transaction
      id
    }
    ProviderDenied(CheckedDenial(id, _, _, _)) -> id
  }
}

pub fn checked_outcome_revision(outcome: CheckedOutcome) -> StoredRevision {
  case outcome {
    CodeReady(CheckedCallback(_, revision, _)) -> revision
    ProviderDenied(CheckedDenial(_, revision, _, _)) -> revision
  }
}

// The check validates callback binding and code shape. Expiry is decided only
// from the clock sample inside the atomic store operation.
pub fn check_callback(
  stored: StoredTransaction,
  callback: Callback,
) -> Result(CheckedOutcome, CallbackCheckError) {
  case stored {
    PendingRecord(transaction, revision) ->
      check_pending(transaction, revision, callback)
    ConsumedRecord(_, _) -> Error(CallbackAlreadyUsed)
    ExpiredRecord(_, _) -> Error(CallbackExpired)
  }
}

fn check_pending(
  transaction: Transaction,
  revision: StoredRevision,
  callback: Callback,
) -> Result(CheckedOutcome, CallbackCheckError) {
  let Transaction(id, Client(expected_issuer, _, _), expected_state, _, _, _) =
    transaction
  let Callback(actual_issuer, actual_state, code_shape) = callback
  case actual_state == expected_state {
    False -> Error(StateMismatch)
    True ->
      case actual_issuer == expected_issuer {
        False -> Error(IssuerMismatch)
        True -> checked_code(transaction, id, revision, code_shape)
      }
  }
}

fn checked_code(
  transaction: Transaction,
  id: TransactionId,
  revision: StoredRevision,
  shape: CallbackCode,
) -> Result(CheckedOutcome, CallbackCheckError) {
  case shape {
    AuthorizationCodeReceived("") -> Error(AuthorizationCodeEmpty)
    AuthorizationCodeReceived(code) ->
      Ok(
        CodeReady(CheckedCallback(
          transaction,
          revision,
          AuthorizationCode(code),
        )),
      )
    CallbackWithoutCode -> Error(AuthorizationCodeMissing)
    CallbackRejected(reason) -> {
      let Transaction(_, client, _, _, _, _) = transaction
      Ok(
        ProviderDenied(CheckedDenial(id, revision, client, denial_class(reason))),
      )
    }
  }
}

fn denial_class(reason: String) -> DenialClass {
  case reason {
    "access_denied" -> AccessDenied
    _ -> OtherDenied
  }
}

pub opaque type ConsumeCommand {
  ConsumeCommand(id: TransactionId, revision: StoredRevision)
}

pub type ConsumeCommandMetadata {
  ConsumeCommandMetadata(id: TransactionId, revision: StoredRevision)
}

pub fn consume_command_metadata(
  command: ConsumeCommand,
) -> ConsumeCommandMetadata {
  let ConsumeCommand(id, revision) = command
  ConsumeCommandMetadata(id, revision)
}

// A command can be made only from a checked, issuer/state-bound outcome.
// It contains no callback code and exposes no secret metadata.
pub fn consume_command(outcome: CheckedOutcome) -> ConsumeCommand {
  case outcome {
    CodeReady(CheckedCallback(transaction, revision, _)) -> {
      let Transaction(id, _, _, _, _, _) = transaction
      ConsumeCommand(id, revision)
    }
    ProviderDenied(CheckedDenial(id, revision, _, _)) ->
      ConsumeCommand(id, revision)
  }
}

// This reducer's order is part of the contract: identifier, terminal
// tombstone, revision, then locked expiry. A terminal record contains only ID
// and revision, so this returned state drops the current row's secret payload.
pub fn decide_consume(
  current: StoredTransaction,
  command: ConsumeCommand,
  locked_now: Timestamp,
) -> #(StoredTransaction, ConsumeDecision) {
  let ConsumeCommand(command_id, command_revision) = command
  case stored_transaction_id(current) == command_id {
    False -> #(current, ChangedSinceCheck)
    True ->
      case current {
        ConsumedRecord(_, _) -> #(current, AlreadyConsumed)
        ExpiredRecord(_, _) -> #(current, ExpiredDuringConsume)
        PendingRecord(transaction, revision) ->
          case revision == command_revision {
            False -> #(current, ChangedSinceCheck)
            True ->
              case
                at_or_after_expiry(locked_now, transaction_expiry(transaction))
              {
                True -> #(
                  ExpiredRecord(command_id, revision),
                  ExpiredDuringConsume,
                )
                False -> #(ConsumedRecord(command_id, revision), WasConsumed)
              }
          }
      }
  }
}

fn at_or_after_expiry(now: Timestamp, expiry: Timestamp) -> Bool {
  let Timestamp(now_seconds) = now
  let Timestamp(expiry_seconds) = expiry
  now_seconds >= expiry_seconds
}

pub opaque type Clock {
  Clock(sample: fn() -> Timestamp)
}

pub fn clock(sample: fn() -> Timestamp) -> Clock {
  Clock(sample)
}

// A store adapter must call this only after acquiring its row lock or
// equivalent critical section. The type cannot enforce that ordering.
pub fn sample_locked_clock(clock: Clock) -> Timestamp {
  clock.sample()
}

pub opaque type TransactionStore {
  TransactionStore(
    clock: Clock,
    atomic_consume: fn(ConsumeCommand, Clock) -> StoreReply,
  )
}

pub fn transaction_store(
  clock: Clock,
  atomic_consume: fn(ConsumeCommand, Clock) -> StoreReply,
) -> TransactionStore {
  TransactionStore(clock, atomic_consume)
}

// The store callback owns the current record. It must atomically compare and
// persist the decision returned by decide_consume; it may not accept a
// caller-supplied current record or timestamp. This seam is a scriptable
// protocol, not a concurrency or durable-store proof.
pub fn consume_callback(
  store: TransactionStore,
  checked: CheckedOutcome,
) -> Result(PublicConsumption, ConsumeError) {
  case consume_checked(store, checked) {
    Error(error) -> Error(error)
    Ok(Nil) -> Ok(public_success(checked))
  }
}

fn consume_checked(
  store: TransactionStore,
  checked: CheckedOutcome,
) -> Result(Nil, ConsumeError) {
  let command = consume_command(checked)
  let TransactionStore(clock, atomic_consume) = store
  case atomic_consume(command, clock) {
    Decided(WasConsumed) -> Ok(Nil)
    Decided(ExpiredDuringConsume) -> Error(TransactionExpired)
    Decided(AlreadyConsumed) -> Error(CallbackAlreadyConsumed)
    Decided(ChangedSinceCheck) -> Error(TransactionChanged)
    Missing -> Error(TransactionMissing)
    Unavailable(code) -> Error(StoreUnavailable(code))
    CommitUnknown -> Error(CommitOutcomeUnknown)
  }
}

fn public_success(checked: CheckedOutcome) -> PublicConsumption {
  case checked {
    CodeReady(_) -> CodeConsumed
    ProviderDenied(denial) -> DenialConsumed(denial.classification)
  }
}

fn checked_text(value: String, wrap: fn(String) -> a) -> Result(a, InputError) {
  case value {
    "" -> Error(ValueMustNotBeEmpty)
    _ -> Ok(wrap(value))
  }
}

pub opaque type ExchangeRequest {
  ExchangeRequest(
    client: Client,
    code: AuthorizationCode,
    nonce: Nonce,
    verifier: PkceVerifier,
  )
}

pub opaque type VerificationBackend {
  VerificationBackend(
    client: Client,
    declaration: AdapterDeclaration,
    exchange: fn(ExchangeRequest) -> Result(LoginAttestation, BackendError),
  )
}

pub fn trust_adapter(
  client: Client,
  declaration: AdapterDeclaration,
  exchange: fn(ExchangeRequest) -> Result(LoginAttestation, BackendError),
) -> VerificationBackend {
  // The caller explicitly records whether this adapter is trusted in ordinary
  // use or is a test-only fixture. Neither label verifies its implementation.
  VerificationBackend(client, declaration, exchange)
}

// Only a configured backend receives this capability. It intentionally omits
// browser state and exposes the retained code, nonce, verifier, and redirect.
// The requested PKCE policy is explicit; this fixture does not prove how the
// authorization challenge was generated or that an adapter enforces the flag.
pub fn exchange_parameters(request: ExchangeRequest) -> ExchangeParameters {
  let ExchangeRequest(
    Client(issuer, client_id, redirect_uri),
    AuthorizationCode(code),
    Nonce(nonce),
    PkceVerifier(verifier),
  ) = request
  let Issuer(issuer_value) = issuer
  let ClientId(client_value) = client_id
  let RedirectUri(redirect_value) = redirect_uri
  ExchangeParameters(
    issuer_value,
    client_value,
    redirect_value,
    code,
    nonce,
    verifier,
    VerificationProfile(True, True, ExactSingletonClient, True),
  )
}

pub opaque type VerifiedIdentity {
  VerifiedIdentity(issuer: Issuer, subject: Subject)
}

type Subject {
  Subject(String)
}

pub opaque type CustodyOwnerId {
  CustodyOwnerId(String)
}

pub opaque type CustodyReference {
  CustodyReference(String)
}

pub opaque type CustodyRevision {
  CustodyRevision(String)
}

pub opaque type ProviderBinding {
  ProviderBinding(client: Client, adapter: AdapterDeclaration)
}

// This typed composite is a stable idempotency key, not a generated secret or
// a proof of durable installation.
pub opaque type CustodyInstallationId {
  CustodyInstallationId(
    owner: CustodyOwnerId,
    provider: ProviderBinding,
    transaction: TransactionId,
  )
}

pub opaque type CustodyCommand {
  CustodyCommand(
    owner: CustodyOwnerId,
    installation_id: CustodyInstallationId,
    provider: ProviderBinding,
    transaction: TransactionId,
    identity: VerifiedIdentity,
    original_nonce: Nonce,
    authentication: AuthenticationEvidence,
    tokens: TokenMaterial,
  )
}

pub opaque type CustodyRecoveryCommand {
  CustodyRecoveryCommand(owner: CustodyOwnerId, command: CustodyCommand)
}

pub type CustodyCommandMetadata {
  CustodyCommandMetadata(
    owner: CustodyOwnerId,
    installation_id: CustodyInstallationId,
    provider: ProviderBinding,
    transaction: TransactionId,
    identity: VerifiedIdentity,
  )
}

// This view is for the explicitly trusted custody adapter. Token values stay
// typed, but Gleam opacity is not a VM secrecy boundary.
pub type CustodyCommandContents {
  CustodyCommandContents(
    owner: CustodyOwnerId,
    installation_id: CustodyInstallationId,
    provider: ProviderBinding,
    transaction: TransactionId,
    identity: VerifiedIdentity,
    original_nonce: Nonce,
    authentication: AuthenticationEvidence,
    tokens: TokenMaterial,
  )
}

pub type CustodyFailure {
  // The trusted adapter confirms that this command was not installed.
  CustodyPortRejected
}

pub opaque type CustodyReceipt {
  CustodyReceipt(
    accepted_command: CustodyCommand,
    reference: CustodyReference,
    revision: CustodyRevision,
  )
}

// A successful receipt must identify the exact command received by the port.
// The custody adapter remains responsible for returning the same session
// reference and revision when it replays a previously installed command id.
// Hellhound cannot prove those values came from a durable ledger.
pub type CustodyReply {
  CustodyInstalled(CustodyReceipt)
  CustodyRejected(CustodyFailure)
  CustodyOutcomeUnknown
  CustodyPortUnavailable
}

pub opaque type RefreshReservationRequest {
  RefreshReservationRequest(
    owner: CustodyOwnerId,
    command_id: RefreshCommandId,
    session: Session,
    provider: ProviderBinding,
  )
}

// This dispatch is returned only after the trusted owner has atomically
// reserved a generation and recorded issuance. Gleam values are copyable; the
// owner, not this type, must deduplicate commands across processes.
pub opaque type RefreshDispatch {
  RefreshDispatch(
    request: RefreshReservationRequest,
    current_tokens: TokenMaterial,
    refresh_token: RefreshToken,
    authentication: AuthenticationEvidence,
  )
}

pub opaque type RefreshSettlementCommand {
  RefreshSettlementCommand(
    dispatch: RefreshDispatch,
    value: RefreshSettlementValue,
  )
}

pub opaque type RefreshSettlementReceipt {
  RefreshSettlementReceipt(command: RefreshSettlementCommand)
}

// The command retains the original reservation and exact replacement material.
// The owner must atomically match the reservation and expected session revision.
pub opaque type RefreshPublicationCommand {
  RefreshPublicationCommand(
    request: RefreshReservationRequest,
    dispatch: RefreshDispatch,
    updated_tokens: TokenMaterial,
  )
}

pub opaque type RefreshPublicationReceipt {
  RefreshPublicationReceipt(
    accepted_command: RefreshPublicationCommand,
    reference: CustodyReference,
    revision: CustodyRevision,
  )
}

pub opaque type RefreshReservationRecovery {
  RefreshReservationRecovery(
    owner: CustodyOwnerId,
    request: RefreshReservationRequest,
    evidence: RefreshReservationRecoveryEvidence,
  )
}

pub opaque type RefreshPublicationRecovery {
  RefreshPublicationRecovery(
    owner: CustodyOwnerId,
    command: RefreshPublicationCommand,
  )
}

pub opaque type RefreshPort {
  RefreshPort(
    reserve: fn(RefreshReservationRequest) -> RefreshReserveReply,
    settle: fn(RefreshSettlementCommand) -> RefreshSettlementReply,
    publish: fn(RefreshPublicationCommand) -> RefreshPublicationReply,
    recover_reservation: fn(RefreshReservationRecovery) ->
      RefreshReservationStatus,
    recover_publication: fn(RefreshPublicationRecovery) ->
      RefreshPublicationReply,
  )
}

pub opaque type RefreshBackend {
  RefreshBackend(
    provider: ProviderBinding,
    perform: fn(RefreshDispatch) -> RefreshProviderOutcome,
  )
}

type RefreshOwnerPortChoice {
  NoRefreshOwnerPort
  RefreshOwnerPortInstalled(RefreshPort)
}

pub opaque type CustodyOwner {
  CustodyOwner(
    id: CustodyOwnerId,
    install: fn(CustodyCommand) -> CustodyReply,
    recover: fn(CustodyRecoveryCommand) -> CustodyReply,
    refresh_port: RefreshOwnerPortChoice,
  )
}

pub opaque type Session {
  Session(
    identity: VerifiedIdentity,
    custody_reference: CustodyReference,
    custody_revision: CustodyRevision,
    provider: ProviderBinding,
    installation_id: CustodyInstallationId,
  )
}

// Refresh callbacks are carried by the same canonical owner as login custody.
// The adapter callbacks are trusted claims, not proof of durable serialization
// or provider behavior. Session remains the only identity-bearing handle.
pub opaque type RefreshCommandId {
  RefreshCommandId(String)
}

pub type RefreshTokenUpdate {
  RetainRefreshToken
  ReplaceRefreshToken(RefreshToken)
}

pub type RefreshScopeUpdate {
  RefreshScopesOmitted
  RefreshScopesReturned(List(Scope))
}

pub type RefreshNonceUpdate {
  RefreshNonceOmitted
  RefreshNonceReturned(Nonce)
}

// A returned refresh ID token is an adapter attestation. Absence preserves the
// already-verified identity and logout hint; presence is checked against them.
pub type RefreshIdTokenUpdate {
  RefreshIdTokenAbsent
  RefreshIdTokenPresent(
    identity: BackendAttestation,
    nonce: RefreshNonceUpdate,
    authentication_time: AuthenticationTime,
    logout_id_token: LogoutIdToken,
  )
}

pub type RefreshAttestation {
  RefreshAttestation(
    access_token: AccessToken,
    expires_at: TokenExpiry,
    refresh_token: RefreshTokenUpdate,
    scopes: RefreshScopeUpdate,
    id_token: RefreshIdTokenUpdate,
  )
}

pub type RefreshProviderOutcome {
  // The configured adapter proves it did not send a provider request.
  ProvenNotSent
  // A definite provider response rejected this attempt; generic transport
  // failure must not be translated to this case.
  EndpointRejected
  // The request may have rotated the token but its outcome is not known.
  ProviderOutcomeUnknown
  RefreshAttested(RefreshAttestation)
}

pub type RefreshValidationError {
  RefreshedIssuerMismatch
  RefreshedAudienceMismatch
  RefreshedAuthorizedPartyMismatch
  RefreshedSubjectMismatch
  RefreshedNonceMismatch
  RefreshedAuthenticationTimeMismatch
  RefreshedScopeChangeUnsupported
}

pub type RefreshReservationRejection {
  RefreshSessionMissing
  RefreshSessionStale
  RefreshProviderBindingRejected
  RefreshMaterialMissing
  RefreshGenerationQuarantined
  RefreshCommandConflict
}

pub type RefreshError {
  RefreshOwnerHasNoPort
  RefreshOwnerMismatch
  RefreshSessionOwnerMismatch
  RefreshSessionBindingMismatch
  RefreshBackendConfigurationMismatch
  RefreshReservationRejected(RefreshReservationRejection)
}

pub type RefreshRecordedValue {
  RefreshNoSendRecorded
  RefreshEndpointRejectionRecorded
  RefreshProviderQuarantinedRecorded
  RefreshInvalidResponseQuarantined(RefreshValidationError)
  RefreshPublicationRecorded(RefreshPublicationReceipt)
}

pub type RefreshResult {
  RefreshCompleted(Session)
  RefreshDidNotSend
  RefreshRejectedByEndpoint
  RefreshProviderQuarantined(RefreshReservationRecovery)
  RefreshResponseQuarantined(RefreshValidationError, RefreshReservationRecovery)
  RefreshReservationUnresolved(RefreshReservationRecovery)
  RefreshPublicationUnresolved(RefreshPublicationRecovery)
}

pub type RefreshReservationRecoveryEvidence {
  NoRefreshEvidence
  ReturnedRefreshDispatch(RefreshDispatch)
  ReturnedRefreshRecord(RefreshRecordedOutcome)
  SubmittedRefreshSettlement(RefreshSettlementCommand)
  ReturnedRefreshSettlement(RefreshSettlementReceipt)
  ReturnedRefreshRecovery(RefreshReservationRecovery)
}

pub type RefreshReservationStatus {
  RefreshReservationStillPending
  RefreshReservationRecorded(RefreshRecordedOutcome)
  RefreshReservationStillQuarantined
  RefreshReservationStatusUnknown
  RefreshReservationStatusUnavailable
}

pub type RefreshSettlementValue {
  RefreshNoSend
  RefreshEndpointRejected
  RefreshProviderUnknown
  RefreshAttestationInvalid(RefreshValidationError)
}

pub type RefreshSettlementReply {
  RefreshSettlementRecorded(RefreshSettlementReceipt)
  RefreshSettlementUnknown
  RefreshSettlementUnavailable
}

pub type RefreshPublicationReply {
  RefreshPublicationAccepted(RefreshPublicationReceipt)
  RefreshPublicationUnknown
  RefreshPublicationUnavailable
  RefreshPublicationRejected
}

pub type RefreshReserveReply {
  RefreshDispatchIssued(RefreshDispatch)
  RefreshCommandRecorded(RefreshRecordedOutcome)
  RefreshCommandPending(RefreshReservationRecovery)
  RefreshCommandBusy(RefreshReservationRecovery)
  RefreshCommandRejected(RefreshReservationRejection)
  RefreshCommandUnknown(RefreshReservationRecovery)
}

pub type RefreshReservationMetadata {
  RefreshReservationMetadata(
    owner: CustodyOwnerId,
    command_id: RefreshCommandId,
    session: Session,
    provider: ProviderBinding,
  )
}

pub type TrustedRefreshDispatchView {
  TrustedRefreshDispatchView(
    owner: CustodyOwnerId,
    command_id: RefreshCommandId,
    session_reference: CustodyReference,
    session_revision: CustodyRevision,
    provider: ProviderBinding,
    identity: VerifiedIdentity,
    refresh_token: String,
    original_nonce: Nonce,
    authentication_time: AuthenticationTime,
    scopes: List(String),
  )
}

pub type RefreshRecordedOutcome {
  RefreshRecordedOutcome(
    request: RefreshReservationRequest,
    value: RefreshRecordedValue,
  )
}

pub type RefreshSettlementContents {
  RefreshSettlementContents(
    dispatch: RefreshDispatch,
    value: RefreshSettlementValue,
  )
}

pub type RefreshPublicationContents {
  RefreshPublicationContents(
    request: RefreshReservationRequest,
    dispatch: RefreshDispatch,
    updated_tokens: TokenMaterial,
  )
}

pub type RefreshPublicationRecoveryContents {
  RefreshPublicationRecoveryContents(
    owner: CustodyOwnerId,
    command: RefreshPublicationCommand,
  )
}

pub type RefreshReservationRecoveryContents {
  RefreshReservationRecoveryContents(
    owner: CustodyOwnerId,
    request: RefreshReservationRequest,
    evidence: RefreshReservationRecoveryEvidence,
  )
}

pub type LoginCompletion {
  LoginCompleted(Session)
  LoginRecoveryRequired(CustodyRecoveryCommand)
}

pub type CustodyRecoveryResult {
  CustodyRecovered(Session)
  CustodyStillUncertain(CustodyRecoveryCommand)
  CustodyRecoveryRejected(CustodyFailure)
}

pub type CustodyRecoveryError {
  RecoveryOwnerMismatch
}

pub fn custody_owner_id(value: String) -> Result(CustodyOwnerId, InputError) {
  checked_text(value, CustodyOwnerId)
}

pub fn custody_reference(
  value: String,
) -> Result(CustodyReference, InputError) {
  checked_text(value, CustodyReference)
}

pub fn custody_revision(value: String) -> Result(CustodyRevision, InputError) {
  checked_text(value, CustodyRevision)
}

pub fn provider_binding(
  client: Client,
  adapter: AdapterDeclaration,
) -> ProviderBinding {
  ProviderBinding(client, adapter)
}

pub fn custody_installation_id(
  owner: CustodyOwnerId,
  provider: ProviderBinding,
  transaction: TransactionId,
) -> CustodyInstallationId {
  CustodyInstallationId(owner, provider, transaction)
}

pub fn custody_owner(
  id: CustodyOwnerId,
  install: fn(CustodyCommand) -> CustodyReply,
  recover: fn(CustodyRecoveryCommand) -> CustodyReply,
) -> CustodyOwner {
  CustodyOwner(id, install, recover, NoRefreshOwnerPort)
}

pub fn refresh_command_id(
  value: String,
) -> Result(RefreshCommandId, InputError) {
  checked_text(value, RefreshCommandId)
}

pub fn refresh_command_id_value(command_id: RefreshCommandId) -> String {
  let RefreshCommandId(value) = command_id
  value
}

pub fn refresh_backend(
  provider: ProviderBinding,
  perform: fn(RefreshDispatch) -> RefreshProviderOutcome,
) -> RefreshBackend {
  RefreshBackend(provider, perform)
}

pub fn refresh_port(
  reserve: fn(RefreshReservationRequest) -> RefreshReserveReply,
  settle: fn(RefreshSettlementCommand) -> RefreshSettlementReply,
  publish: fn(RefreshPublicationCommand) -> RefreshPublicationReply,
  recover_reservation: fn(RefreshReservationRecovery) ->
    RefreshReservationStatus,
  recover_publication: fn(RefreshPublicationRecovery) -> RefreshPublicationReply,
) -> RefreshPort {
  RefreshPort(
    reserve,
    settle,
    publish,
    recover_reservation,
    recover_publication,
  )
}

// Adds refresh custody to the same owner identity and existing session model.
// The owner callbacks are an adapter seam; real atomicity and durable deduplication
// remain responsibilities of the trusted implementation.
pub fn with_refresh(owner: CustodyOwner, port: RefreshPort) -> CustodyOwner {
  let CustodyOwner(id, install, recover, _) = owner
  CustodyOwner(id, install, recover, RefreshOwnerPortInstalled(port))
}

pub fn refresh_reservation_metadata(
  request: RefreshReservationRequest,
) -> RefreshReservationMetadata {
  let RefreshReservationRequest(owner, command_id, session, provider) = request
  RefreshReservationMetadata(owner, command_id, session, provider)
}

// The trusted owner returns an issued dispatch only after reserving and
// durably recording the command. Missing refresh material is a typed rejection.
pub fn refresh_dispatch_issued(
  request: RefreshReservationRequest,
  current_tokens: TokenMaterial,
  authentication: AuthenticationEvidence,
) -> RefreshReserveReply {
  let TokenMaterial(_, refresh_choice, _, _, _) = current_tokens
  case refresh_choice {
    NoRefreshToken -> RefreshCommandRejected(RefreshMaterialMissing)
    RefreshTokenPresent(refresh_token) ->
      RefreshDispatchIssued(RefreshDispatch(
        request,
        current_tokens,
        refresh_token,
        authentication,
      ))
  }
}

pub fn refresh_command_pending(
  request: RefreshReservationRequest,
) -> RefreshReserveReply {
  RefreshCommandPending(make_reservation_recovery(request, NoRefreshEvidence))
}

pub fn refresh_command_pending_from_dispatch(
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
) -> RefreshReserveReply {
  RefreshCommandPending(make_reservation_recovery(
    request,
    ReturnedRefreshDispatch(dispatch),
  ))
}

pub fn refresh_command_busy_from_dispatch(
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
) -> RefreshReserveReply {
  RefreshCommandBusy(make_reservation_recovery(
    request,
    ReturnedRefreshDispatch(dispatch),
  ))
}

pub fn refresh_command_unknown(
  request: RefreshReservationRequest,
) -> RefreshReserveReply {
  RefreshCommandUnknown(make_reservation_recovery(request, NoRefreshEvidence))
}

pub fn refresh_command_busy(
  request: RefreshReservationRequest,
) -> RefreshReserveReply {
  RefreshCommandBusy(make_reservation_recovery(request, NoRefreshEvidence))
}

pub fn refresh_command_recorded(
  request: RefreshReservationRequest,
  value: RefreshRecordedValue,
) -> RefreshReserveReply {
  RefreshCommandRecorded(RefreshRecordedOutcome(request, value))
}

pub fn refresh_dispatch_reservation(
  dispatch: RefreshDispatch,
) -> RefreshReservationRequest {
  let RefreshDispatch(request, _, _, _) = dispatch
  request
}

pub fn trusted_refresh_dispatch_view(
  dispatch: RefreshDispatch,
) -> TrustedRefreshDispatchView {
  let RefreshDispatch(
    request,
    TokenMaterial(_, _, _, _, scopes),
    refresh_token,
    AuthenticationEvidence(original_nonce, authentication_time),
  ) = dispatch
  let RefreshReservationRequest(owner, command_id, session, provider) = request
  TrustedRefreshDispatchView(
    owner,
    command_id,
    session_custody_reference(session),
    session_custody_revision(session),
    provider,
    session_identity(session),
    trusted_refresh_token_value(refresh_token),
    original_nonce,
    authentication_time,
    scope_values(scopes),
  )
}

pub fn refresh_settlement_contents(
  command: RefreshSettlementCommand,
) -> RefreshSettlementContents {
  let RefreshSettlementCommand(dispatch, value) = command
  RefreshSettlementContents(dispatch, value)
}

pub fn refresh_settlement_recorded(
  command: RefreshSettlementCommand,
) -> RefreshSettlementReply {
  RefreshSettlementRecorded(RefreshSettlementReceipt(command))
}

pub fn refresh_settlement_unknown() -> RefreshSettlementReply {
  RefreshSettlementUnknown
}

pub fn refresh_settlement_unavailable() -> RefreshSettlementReply {
  RefreshSettlementUnavailable
}

pub fn refresh_publication_contents(
  command: RefreshPublicationCommand,
) -> RefreshPublicationContents {
  let RefreshPublicationCommand(request, dispatch, updated_tokens) = command
  RefreshPublicationContents(request, dispatch, updated_tokens)
}

pub fn refresh_publication_accepted(
  accepted_command: RefreshPublicationCommand,
  reference: CustodyReference,
  revision: CustodyRevision,
) -> RefreshPublicationReply {
  RefreshPublicationAccepted(RefreshPublicationReceipt(
    accepted_command,
    reference,
    revision,
  ))
}

pub fn refresh_publication_unknown() -> RefreshPublicationReply {
  RefreshPublicationUnknown
}

pub fn refresh_publication_unavailable() -> RefreshPublicationReply {
  RefreshPublicationUnavailable
}

pub fn refresh_publication_rejected() -> RefreshPublicationReply {
  RefreshPublicationRejected
}

pub fn refresh_reservation_recovery_contents(
  recovery: RefreshReservationRecovery,
) -> RefreshReservationRecoveryContents {
  let RefreshReservationRecovery(owner, request, evidence) = recovery
  RefreshReservationRecoveryContents(owner, request, evidence)
}

pub fn refresh_publication_recovery_contents(
  recovery: RefreshPublicationRecovery,
) -> RefreshPublicationRecoveryContents {
  let RefreshPublicationRecovery(owner, command) = recovery
  RefreshPublicationRecoveryContents(owner, command)
}

pub fn custody_installed(
  accepted_command: CustodyCommand,
  reference: CustodyReference,
  revision: CustodyRevision,
) -> CustodyReply {
  CustodyInstalled(CustodyReceipt(accepted_command, reference, revision))
}

pub fn custody_rejected(failure: CustodyFailure) -> CustodyReply {
  CustodyRejected(failure)
}

pub fn custody_outcome_unknown() -> CustodyReply {
  CustodyOutcomeUnknown
}

pub fn custody_port_unavailable() -> CustodyReply {
  CustodyPortUnavailable
}

pub fn custody_command_metadata(
  command: CustodyCommand,
) -> CustodyCommandMetadata {
  let CustodyCommand(
    owner,
    installation_id,
    provider,
    transaction,
    identity,
    _,
    _,
    _,
  ) = command
  CustodyCommandMetadata(
    owner,
    installation_id,
    provider,
    transaction,
    identity,
  )
}

pub fn custody_command_contents(
  command: CustodyCommand,
) -> CustodyCommandContents {
  let CustodyCommand(
    owner,
    installation_id,
    provider,
    transaction,
    identity,
    original_nonce,
    authentication,
    tokens,
  ) = command
  CustodyCommandContents(
    owner,
    installation_id,
    provider,
    transaction,
    identity,
    original_nonce,
    authentication,
    tokens,
  )
}

pub fn recovery_command_metadata(
  recovery: CustodyRecoveryCommand,
) -> CustodyCommandMetadata {
  let CustodyRecoveryCommand(_, command) = recovery
  custody_command_metadata(command)
}

// The port receives the original opaque command for idempotent replay. It
// cannot obtain a new login request or authorization code through this value.
pub fn recovery_custody_command(
  recovery: CustodyRecoveryCommand,
) -> CustodyCommand {
  let CustodyRecoveryCommand(_, command) = recovery
  command
}

pub fn session_identity(session: Session) -> VerifiedIdentity {
  let Session(identity, _, _, _, _) = session
  identity
}

pub fn session_custody_reference(session: Session) -> CustodyReference {
  let Session(_, reference, _, _, _) = session
  reference
}

pub fn session_custody_revision(session: Session) -> CustodyRevision {
  let Session(_, _, revision, _, _) = session
  revision
}

pub fn session_provider_binding(session: Session) -> ProviderBinding {
  let Session(_, _, _, provider, _) = session
  provider
}

pub fn session_installation_id(session: Session) -> CustodyInstallationId {
  let Session(_, _, _, _, installation_id) = session
  installation_id
}

// Refresh is admitted only by the canonical owner that installed this session.
// The owner validates the stored revision/provider and atomically reserves a
// generation before returning an issued dispatch. Copyable Gleam values do not
// prove cross-process once-only behavior; the trusted port owns deduplication.
pub fn refresh_session(
  owner: CustodyOwner,
  backend: RefreshBackend,
  session: Session,
  command_id: RefreshCommandId,
) -> Result(RefreshResult, RefreshError) {
  let CustodyOwner(owner_id, _, _, owner_port) = owner
  let Session(_, _, _, session_provider, installation_id) = session
  let CustodyInstallationId(installation_owner, installed_provider, _) =
    installation_id
  let RefreshBackend(backend_provider, _) = backend
  case owner_id == installation_owner {
    False -> Error(RefreshSessionOwnerMismatch)
    True ->
      case installed_provider == session_provider {
        False -> Error(RefreshSessionBindingMismatch)
        True ->
          case backend_provider == session_provider {
            False -> Error(RefreshBackendConfigurationMismatch)
            True ->
              case owner_port {
                NoRefreshOwnerPort -> Error(RefreshOwnerHasNoPort)
                RefreshOwnerPortInstalled(port) -> {
                  let request =
                    RefreshReservationRequest(
                      owner_id,
                      command_id,
                      session,
                      session_provider,
                    )
                  let RefreshPort(reserve, _, _, _, _) = port
                  reserve_refresh(
                    owner,
                    backend,
                    request,
                    port,
                    reserve(request),
                  )
                }
              }
          }
      }
  }
}

pub fn recover_refresh_reservation(
  owner: CustodyOwner,
  recovery: RefreshReservationRecovery,
) -> Result(RefreshResult, RefreshError) {
  let CustodyOwner(owner_id, _, _, owner_port) = owner
  let RefreshReservationRecovery(recovery_owner, request, _) = recovery
  case
    recovery_owner == owner_id
    && reservation_request_owner_matches(request, owner_id)
  {
    False -> Error(RefreshOwnerMismatch)
    True ->
      case owner_port {
        NoRefreshOwnerPort -> Error(RefreshOwnerHasNoPort)
        RefreshOwnerPortInstalled(port) -> {
          let RefreshPort(_, _, _, recover_reservation, _) = port
          resolve_reservation_status(
            owner_id,
            request,
            recovery,
            recover_reservation(recovery),
          )
        }
      }
  }
}

pub fn recover_refresh_publication(
  owner: CustodyOwner,
  recovery: RefreshPublicationRecovery,
) -> Result(RefreshResult, RefreshError) {
  let CustodyOwner(owner_id, _, _, owner_port) = owner
  let RefreshPublicationRecovery(recovery_owner, command) = recovery
  let RefreshPublicationCommand(request, _, _) = command
  case
    recovery_owner == owner_id
    && reservation_request_owner_matches(request, owner_id)
  {
    False -> Error(RefreshOwnerMismatch)
    True ->
      case owner_port {
        NoRefreshOwnerPort -> Error(RefreshOwnerHasNoPort)
        RefreshOwnerPortInstalled(port) -> {
          let RefreshPort(_, _, _, _, recover_publication) = port
          resolve_publication(
            owner_id,
            request,
            command,
            recovery,
            recover_publication(recovery),
          )
        }
      }
  }
}

fn reserve_refresh(
  owner: CustodyOwner,
  backend: RefreshBackend,
  request: RefreshReservationRequest,
  port: RefreshPort,
  reply: RefreshReserveReply,
) -> Result(RefreshResult, RefreshError) {
  case reply {
    RefreshDispatchIssued(dispatch) ->
      case refresh_dispatch_request(dispatch) == request {
        True -> invoke_refresh_backend(owner, backend, port, request, dispatch)
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshDispatch(dispatch),
            )),
          )
      }
    RefreshCommandRecorded(recorded) ->
      case recorded.request == request {
        True -> resolve_recorded_outcome(owner, request, recorded)
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshRecord(recorded),
            )),
          )
      }
    RefreshCommandPending(recovery) ->
      case refresh_recovery_matches(recovery, request) {
        True -> Ok(RefreshReservationUnresolved(recovery))
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshRecovery(recovery),
            )),
          )
      }
    RefreshCommandBusy(recovery) ->
      case refresh_recovery_matches(recovery, request) {
        True -> Ok(RefreshReservationUnresolved(recovery))
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshRecovery(recovery),
            )),
          )
      }
    RefreshCommandRejected(rejection) ->
      Error(RefreshReservationRejected(rejection))
    RefreshCommandUnknown(recovery) ->
      case refresh_recovery_matches(recovery, request) {
        True -> Ok(RefreshReservationUnresolved(recovery))
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshRecovery(recovery),
            )),
          )
      }
  }
}

fn invoke_refresh_backend(
  owner: CustodyOwner,
  backend: RefreshBackend,
  port: RefreshPort,
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
) -> Result(RefreshResult, RefreshError) {
  let RefreshBackend(backend_provider, perform) = backend
  let RefreshDispatch(actual_request, _, _, _) = dispatch
  case actual_request == request && backend_provider == request.provider {
    False ->
      Ok(
        RefreshReservationUnresolved(make_reservation_recovery(
          request,
          ReturnedRefreshDispatch(dispatch),
        )),
      )
    True ->
      case perform(dispatch) {
        ProvenNotSent ->
          settle_refresh(owner, port, request, dispatch, RefreshNoSend)
        EndpointRejected ->
          settle_refresh(
            owner,
            port,
            request,
            dispatch,
            RefreshEndpointRejected,
          )
        ProviderOutcomeUnknown ->
          settle_refresh(owner, port, request, dispatch, RefreshProviderUnknown)
        RefreshAttested(attestation) ->
          case validate_refresh_attestation(dispatch, attestation) {
            Error(validation_error) ->
              settle_refresh(
                owner,
                port,
                request,
                dispatch,
                RefreshAttestationInvalid(validation_error),
              )
            Ok(updated_tokens) ->
              publish_refresh(owner, port, request, dispatch, updated_tokens)
          }
      }
  }
}

fn settle_refresh(
  owner: CustodyOwner,
  port: RefreshPort,
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
  value: RefreshSettlementValue,
) -> Result(RefreshResult, RefreshError) {
  let RefreshPort(_, settle, _, _, _) = port
  let command = RefreshSettlementCommand(dispatch, value)
  case settle(command) {
    RefreshSettlementRecorded(receipt) -> {
      let RefreshSettlementReceipt(accepted_command) = receipt
      case accepted_command == command {
        True -> result_for_settlement(owner, request, dispatch, value)
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshSettlement(receipt),
            )),
          )
      }
    }
    RefreshSettlementUnknown | RefreshSettlementUnavailable ->
      Ok(
        RefreshReservationUnresolved(make_reservation_recovery(
          request,
          SubmittedRefreshSettlement(command),
        )),
      )
  }
}

fn result_for_settlement(
  _owner: CustodyOwner,
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
  value: RefreshSettlementValue,
) -> Result(RefreshResult, RefreshError) {
  case value {
    RefreshNoSend -> Ok(RefreshDidNotSend)
    RefreshEndpointRejected -> Ok(RefreshRejectedByEndpoint)
    RefreshProviderUnknown ->
      Ok(
        RefreshProviderQuarantined(make_reservation_recovery(
          request,
          ReturnedRefreshDispatch(dispatch),
        )),
      )
    RefreshAttestationInvalid(validation_error) ->
      Ok(RefreshResponseQuarantined(
        validation_error,
        make_reservation_recovery(request, ReturnedRefreshDispatch(dispatch)),
      ))
  }
}

fn publish_refresh(
  _owner: CustodyOwner,
  port: RefreshPort,
  request: RefreshReservationRequest,
  dispatch: RefreshDispatch,
  updated_tokens: TokenMaterial,
) -> Result(RefreshResult, RefreshError) {
  let RefreshPort(_, _, publish, _, _) = port
  let command = RefreshPublicationCommand(request, dispatch, updated_tokens)
  case publish(command) {
    RefreshPublicationAccepted(receipt) ->
      case confirmed_refresh_session(request, command, receipt) {
        Ok(session) -> Ok(RefreshCompleted(session))
        Error(Nil) ->
          Ok(RefreshPublicationUnresolved(make_publication_recovery(command)))
      }
    RefreshPublicationUnknown
    | RefreshPublicationUnavailable
    | RefreshPublicationRejected ->
      Ok(RefreshPublicationUnresolved(make_publication_recovery(command)))
  }
}

fn resolve_reservation_status(
  owner_id: CustodyOwnerId,
  request: RefreshReservationRequest,
  recovery: RefreshReservationRecovery,
  status: RefreshReservationStatus,
) -> Result(RefreshResult, RefreshError) {
  case status {
    RefreshReservationStillPending -> Ok(RefreshReservationUnresolved(recovery))
    RefreshReservationStillQuarantined ->
      Ok(RefreshProviderQuarantined(recovery))
    RefreshReservationStatusUnknown | RefreshReservationStatusUnavailable ->
      Ok(RefreshReservationUnresolved(recovery))
    RefreshReservationRecorded(recorded) ->
      case recorded.request == request {
        True ->
          resolve_recorded_outcome_for_recovery(owner_id, request, recorded)
        False ->
          Ok(
            RefreshReservationUnresolved(make_reservation_recovery(
              request,
              ReturnedRefreshRecord(recorded),
            )),
          )
      }
  }
}

fn resolve_recorded_outcome_for_recovery(
  owner_id: CustodyOwnerId,
  request: RefreshReservationRequest,
  recorded: RefreshRecordedOutcome,
) -> Result(RefreshResult, RefreshError) {
  case recorded.value {
    RefreshNoSendRecorded -> Ok(RefreshDidNotSend)
    RefreshEndpointRejectionRecorded -> Ok(RefreshRejectedByEndpoint)
    RefreshProviderQuarantinedRecorded ->
      Ok(
        RefreshProviderQuarantined(make_reservation_recovery(
          request,
          ReturnedRefreshRecord(recorded),
        )),
      )
    RefreshInvalidResponseQuarantined(validation_error) ->
      Ok(RefreshResponseQuarantined(
        validation_error,
        make_reservation_recovery(request, ReturnedRefreshRecord(recorded)),
      ))
    RefreshPublicationRecorded(receipt) ->
      resolve_recorded_publication(owner_id, request, recorded, receipt)
  }
}

fn resolve_recorded_outcome(
  owner: CustodyOwner,
  request: RefreshReservationRequest,
  recorded: RefreshRecordedOutcome,
) -> Result(RefreshResult, RefreshError) {
  let CustodyOwner(owner_id, _, _, _) = owner
  resolve_recorded_outcome_for_recovery(owner_id, request, recorded)
}

fn resolve_recorded_publication(
  owner_id: CustodyOwnerId,
  request: RefreshReservationRequest,
  recorded: RefreshRecordedOutcome,
  receipt: RefreshPublicationReceipt,
) -> Result(RefreshResult, RefreshError) {
  let RefreshPublicationReceipt(command, _, _) = receipt
  let RefreshPublicationCommand(actual_request, dispatch, _) = command
  case
    actual_request == request && refresh_dispatch_request(dispatch) == request
  {
    False ->
      Ok(
        RefreshReservationUnresolved(make_reservation_recovery(
          request,
          ReturnedRefreshRecord(recorded),
        )),
      )
    True ->
      case confirmed_refresh_session(request, command, receipt) {
        Ok(session) -> Ok(RefreshCompleted(session))
        Error(Nil) -> {
          let _ = owner_id
          Ok(RefreshPublicationUnresolved(make_publication_recovery(command)))
        }
      }
  }
}

fn resolve_publication(
  _owner_id: CustodyOwnerId,
  request: RefreshReservationRequest,
  command: RefreshPublicationCommand,
  recovery: RefreshPublicationRecovery,
  reply: RefreshPublicationReply,
) -> Result(RefreshResult, RefreshError) {
  case reply {
    RefreshPublicationAccepted(receipt) ->
      case confirmed_refresh_session(request, command, receipt) {
        Ok(session) -> Ok(RefreshCompleted(session))
        Error(Nil) -> Ok(RefreshPublicationUnresolved(recovery))
      }
    RefreshPublicationUnknown
    | RefreshPublicationUnavailable
    | RefreshPublicationRejected -> Ok(RefreshPublicationUnresolved(recovery))
  }
}

fn confirmed_refresh_session(
  request: RefreshReservationRequest,
  command: RefreshPublicationCommand,
  receipt: RefreshPublicationReceipt,
) -> Result(Session, Nil) {
  let RefreshPublicationCommand(actual_request, dispatch, _) = command
  let RefreshPublicationReceipt(accepted_command, reference, revision) = receipt
  let RefreshReservationRequest(owner, command_id, session, provider) = request
  let Session(
    identity,
    old_reference,
    old_revision,
    session_provider,
    installation_id,
  ) = session
  let CustodyInstallationId(installation_owner, installed_provider, _) =
    installation_id
  let RefreshDispatch(dispatch_request, _, _, _) = dispatch
  case
    accepted_command == command
    && actual_request == request
    && dispatch_request == request
    && owner == installation_owner
    && provider == session_provider
    && installed_provider == session_provider
    && reference == old_reference
    && revision != old_revision
    && command_id == request.command_id
  {
    True ->
      Ok(Session(
        identity,
        reference,
        revision,
        session_provider,
        installation_id,
      ))
    False -> Error(Nil)
  }
}

fn validate_refresh_attestation(
  dispatch: RefreshDispatch,
  attestation: RefreshAttestation,
) -> Result(TokenMaterial, RefreshValidationError) {
  let RefreshAttestation(
    new_access_token,
    new_expiry,
    refresh_update,
    scope_update,
    id_token_update,
  ) = attestation
  let RefreshDispatch(
    request,
    current_tokens,
    previous_refresh_token,
    authentication,
  ) = dispatch
  let RefreshReservationRequest(_, _, session, provider) = request
  let Session(identity, _, _, _, _) = session
  let TokenMaterial(_, _, current_logout_hint, _, current_scopes) =
    current_tokens
  let ProviderBinding(client, _) = provider
  let next_refresh_choice = case refresh_update {
    RetainRefreshToken -> RefreshTokenPresent(previous_refresh_token)
    ReplaceRefreshToken(replacement) -> RefreshTokenPresent(replacement)
  }
  case accepted_refresh_scopes(scope_update, current_scopes) {
    Error(error) -> Error(error)
    Ok(scopes) ->
      case
        accepted_refresh_identity(
          client,
          identity,
          authentication,
          id_token_update,
          current_logout_hint,
        )
      {
        Error(error) -> Error(error)
        Ok(logout_hint) ->
          Ok(token_material(
            new_access_token,
            next_refresh_choice,
            logout_hint,
            new_expiry,
            scopes,
          ))
      }
  }
}

fn accepted_refresh_scopes(
  update: RefreshScopeUpdate,
  current_scopes: List(Scope),
) -> Result(List(Scope), RefreshValidationError) {
  case update {
    RefreshScopesOmitted -> Ok(current_scopes)
    RefreshScopesReturned(returned_scopes) ->
      case same_scope_set(current_scopes, returned_scopes) {
        True -> Ok(current_scopes)
        False -> Error(RefreshedScopeChangeUnsupported)
      }
  }
}

fn same_scope_set(left: List(Scope), right: List(Scope)) -> Bool {
  let normalized_right = normalize_scopes(right)
  scope_count(left) == scope_count(normalized_right)
  && scopes_contained(left, normalized_right)
}

fn scope_count(scopes: List(Scope)) -> Int {
  case scopes {
    [] -> 0
    [_, ..rest] -> 1 + scope_count(rest)
  }
}

fn scopes_contained(scopes: List(Scope), in candidates: List(Scope)) -> Bool {
  case scopes {
    [] -> True
    [next, ..rest] ->
      contains_scope(next, candidates) && scopes_contained(rest, candidates)
  }
}

fn accepted_refresh_identity(
  client: Client,
  identity: VerifiedIdentity,
  original_authentication: AuthenticationEvidence,
  update: RefreshIdTokenUpdate,
  current_logout_hint: LogoutIdTokenChoice,
) -> Result(LogoutIdTokenChoice, RefreshValidationError) {
  case update {
    RefreshIdTokenAbsent -> Ok(current_logout_hint)
    RefreshIdTokenPresent(
      attestation,
      returned_nonce,
      returned_authentication_time,
      new_logout_hint,
    ) ->
      case refresh_identity_matches(client, identity, attestation) {
        Error(error) -> Error(error)
        Ok(Nil) ->
          case original_authentication {
            AuthenticationEvidence(original_nonce, original_authentication_time) ->
              case
                refresh_nonce_matches(returned_nonce, original_nonce)
                && refresh_authentication_time_matches(
                  returned_authentication_time,
                  original_authentication_time,
                )
              {
                True -> Ok(LogoutIdTokenPresent(new_logout_hint))
                False ->
                  case refresh_nonce_matches(returned_nonce, original_nonce) {
                    False -> Error(RefreshedNonceMismatch)
                    True -> Error(RefreshedAuthenticationTimeMismatch)
                  }
              }
          }
      }
  }
}

fn refresh_identity_matches(
  client: Client,
  identity: VerifiedIdentity,
  attestation: BackendAttestation,
) -> Result(Nil, RefreshValidationError) {
  let Client(expected_issuer, expected_client_id, _) = client
  let VerifiedIdentity(identity_issuer, Subject(identity_subject)) = identity
  let BackendAttestation(issuer, audiences, authorized_party, subject) =
    attestation
  case issuer == expected_issuer && issuer == identity_issuer {
    False -> Error(RefreshedIssuerMismatch)
    True ->
      case audiences == [expected_client_id] {
        False -> Error(RefreshedAudienceMismatch)
        True ->
          case authorized_party_matches(authorized_party, expected_client_id) {
            False -> Error(RefreshedAuthorizedPartyMismatch)
            True ->
              case subject == identity_subject {
                True -> Ok(Nil)
                False -> Error(RefreshedSubjectMismatch)
              }
          }
      }
  }
}

fn refresh_nonce_matches(update: RefreshNonceUpdate, original: Nonce) -> Bool {
  case update {
    RefreshNonceOmitted -> True
    RefreshNonceReturned(returned) -> returned == original
  }
}

fn refresh_authentication_time_matches(
  returned: AuthenticationTime,
  original: AuthenticationTime,
) -> Bool {
  case returned, original {
    NoAuthenticationTime, _ -> True
    AuthenticationTimePresent(_), NoAuthenticationTime -> False
    AuthenticationTimePresent(returned_time),
      AuthenticationTimePresent(original_time)
    -> returned_time == original_time
  }
}

fn reservation_request_owner_matches(
  request: RefreshReservationRequest,
  owner_id: CustodyOwnerId,
) -> Bool {
  let RefreshReservationRequest(request_owner, _, session, provider) = request
  let Session(_, _, _, session_provider, installation_id) = session
  let CustodyInstallationId(installation_owner, installed_provider, _) =
    installation_id
  request_owner == owner_id
  && installation_owner == owner_id
  && provider == session_provider
  && provider == installed_provider
}

fn refresh_dispatch_request(
  dispatch: RefreshDispatch,
) -> RefreshReservationRequest {
  let RefreshDispatch(request, _, _, _) = dispatch
  request
}

fn refresh_recovery_matches(
  recovery: RefreshReservationRecovery,
  request: RefreshReservationRequest,
) -> Bool {
  let RefreshReservationRecovery(_, recovery_request, _) = recovery
  recovery_request == request
}

fn make_reservation_recovery(
  request: RefreshReservationRequest,
  evidence: RefreshReservationRecoveryEvidence,
) -> RefreshReservationRecovery {
  let RefreshReservationRequest(owner, _, _, _) = request
  RefreshReservationRecovery(owner, request, evidence)
}

fn make_publication_recovery(
  command: RefreshPublicationCommand,
) -> RefreshPublicationRecovery {
  let RefreshPublicationCommand(request, _, _) = command
  let RefreshReservationRequest(owner, _, _, _) = request
  RefreshPublicationRecovery(owner, command)
}

pub fn verified_subject(identity: VerifiedIdentity) -> String {
  let VerifiedIdentity(_, Subject(value)) = identity
  value
}

pub fn verified_issuer(identity: VerifiedIdentity) -> Issuer {
  let VerifiedIdentity(issuer, _) = identity
  issuer
}

pub fn complete_login(
  store: TransactionStore,
  backend: VerificationBackend,
  custody_owner: CustodyOwner,
  checked: CheckedOutcome,
) -> Result(LoginCompletion, CompleteLoginError) {
  let VerificationBackend(backend_client, _, _) = backend
  case checked_client(checked) == backend_client {
    False -> Error(BackendConfigurationMismatch)
    True ->
      case checked {
        CodeReady(callback) ->
          complete_code(store, backend, custody_owner, callback)
        ProviderDenied(denial) -> complete_denial(store, denial)
      }
  }
}

pub fn recover_custody(
  owner: CustodyOwner,
  recovery: CustodyRecoveryCommand,
) -> Result(CustodyRecoveryResult, CustodyRecoveryError) {
  let CustodyOwner(owner_id, _, recover, _) = owner
  let CustodyRecoveryCommand(recovery_owner, command) = recovery
  case owner_id == recovery_owner {
    False -> Error(RecoveryOwnerMismatch)
    True -> resolve_recovery(recovery, command, recover(recovery))
  }
}

fn checked_client(checked: CheckedOutcome) -> Client {
  case checked {
    CodeReady(CheckedCallback(transaction, _, _)) -> {
      let Transaction(_, client, _, _, _, _) = transaction
      client
    }
    ProviderDenied(CheckedDenial(_, _, client, _)) -> client
  }
}

fn complete_code(
  store: TransactionStore,
  backend: VerificationBackend,
  custody_owner: CustodyOwner,
  checked: CheckedCallback,
) -> Result(LoginCompletion, CompleteLoginError) {
  case consume_checked(store, CodeReady(checked)) {
    Error(error) -> Error(ConsumptionFailed(error))
    Ok(Nil) -> exchange_consumed_code(backend, custody_owner, checked)
  }
}

fn complete_denial(
  store: TransactionStore,
  denial: CheckedDenial,
) -> Result(LoginCompletion, CompleteLoginError) {
  case consume_checked(store, ProviderDenied(denial)) {
    Error(error) -> Error(ConsumptionFailed(error))
    Ok(Nil) -> Error(ProviderRejection(denial.classification))
  }
}

fn exchange_consumed_code(
  backend: VerificationBackend,
  custody_owner: CustodyOwner,
  checked: CheckedCallback,
) -> Result(LoginCompletion, CompleteLoginError) {
  let CheckedCallback(transaction, _, code) = checked
  let Transaction(transaction_id, client, _, nonce, verifier, _) = transaction
  let VerificationBackend(_, declaration, exchange) = backend
  let request = ExchangeRequest(client, code, nonce, verifier)
  case exchange(request) {
    Error(error) -> Error(BackendFailed(error))
    Ok(attestation) ->
      case validate_attestation(client, nonce, attestation) {
        Error(error) -> Error(error)
        Ok(#(identity, tokens, authentication)) -> {
          let CustodyOwner(owner_id, install, _, _) = custody_owner
          let provider = ProviderBinding(client, declaration)
          let installation_id =
            CustodyInstallationId(owner_id, provider, transaction_id)
          let command =
            CustodyCommand(
              owner_id,
              installation_id,
              provider,
              transaction_id,
              identity,
              nonce,
              authentication,
              tokens,
            )
          resolve_installation(custody_owner, command, install(command))
        }
      }
  }
}

fn validate_attestation(
  client: Client,
  expected_nonce: Nonce,
  attestation: LoginAttestation,
) -> Result(
  #(VerifiedIdentity, TokenMaterial, AuthenticationEvidence),
  CompleteLoginError,
) {
  let LoginAttestation(identity_attestation, tokens, authentication) =
    attestation
  case validate_identity(client, identity_attestation) {
    Error(error) -> Error(error)
    Ok(identity) ->
      case authentication {
        AuthenticationEvidence(original_nonce, _) ->
          case original_nonce == expected_nonce {
            True -> Ok(#(identity, tokens, authentication))
            False -> Error(AuthenticationNonceMismatch)
          }
      }
  }
}

fn validate_identity(
  client: Client,
  attestation: BackendAttestation,
) -> Result(VerifiedIdentity, CompleteLoginError) {
  let Client(expected_issuer, expected_client, _) = client
  let BackendAttestation(issuer, audiences, authorized_party, subject) =
    attestation
  case issuer == expected_issuer {
    False -> Error(AttestedIssuerMismatch)
    True ->
      case audiences == [expected_client] {
        False -> Error(AttestedAudienceMismatch)
        True ->
          case authorized_party_matches(authorized_party, expected_client) {
            False -> Error(AuthorizedPartyMismatch)
            True ->
              case subject {
                "" -> Error(SubjectMissing)
                _ -> Ok(VerifiedIdentity(issuer, Subject(subject)))
              }
          }
      }
  }
}

fn resolve_installation(
  owner: CustodyOwner,
  command: CustodyCommand,
  reply: CustodyReply,
) -> Result(LoginCompletion, CompleteLoginError) {
  case reply {
    CustodyInstalled(receipt) ->
      case confirmed_session(command, receipt) {
        Ok(session) -> Ok(LoginCompleted(session))
        Error(Nil) -> Ok(LoginRecoveryRequired(make_recovery(owner, command)))
      }
    CustodyRejected(failure) -> Error(CustodyInstallRejected(failure))
    CustodyOutcomeUnknown ->
      Ok(LoginRecoveryRequired(make_recovery(owner, command)))
    CustodyPortUnavailable ->
      Ok(LoginRecoveryRequired(make_recovery(owner, command)))
  }
}

fn resolve_recovery(
  recovery: CustodyRecoveryCommand,
  command: CustodyCommand,
  reply: CustodyReply,
) -> Result(CustodyRecoveryResult, CustodyRecoveryError) {
  case reply {
    CustodyInstalled(receipt) ->
      case confirmed_session(command, receipt) {
        Ok(session) -> Ok(CustodyRecovered(session))
        Error(Nil) -> Ok(CustodyStillUncertain(recovery))
      }
    CustodyRejected(failure) -> Ok(CustodyRecoveryRejected(failure))
    CustodyOutcomeUnknown -> Ok(CustodyStillUncertain(recovery))
    CustodyPortUnavailable -> Ok(CustodyStillUncertain(recovery))
  }
}

fn confirmed_session(
  command: CustodyCommand,
  receipt: CustodyReceipt,
) -> Result(Session, Nil) {
  let CustodyReceipt(accepted_command, reference, revision) = receipt
  case accepted_command == command {
    False -> Error(Nil)
    True -> {
      let CustodyCommand(_, installation_id, provider, _, identity, _, _, _) =
        command
      Ok(Session(identity, reference, revision, provider, installation_id))
    }
  }
}

fn make_recovery(
  owner: CustodyOwner,
  command: CustodyCommand,
) -> CustodyRecoveryCommand {
  let CustodyOwner(owner_id, _, _, _) = owner
  CustodyRecoveryCommand(owner_id, command)
}

fn authorized_party_matches(
  authorized_party: AuthorizedParty,
  expected_client: ClientId,
) -> Bool {
  case authorized_party {
    NoAuthorizedParty -> True
    AuthorizedParty(actual_client) -> actual_client == expected_client
  }
}
