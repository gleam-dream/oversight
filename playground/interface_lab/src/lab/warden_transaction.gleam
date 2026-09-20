// THROWAWAY: Can callback checks feed one revision-bound atomic consumption boundary?
// This type experiment supplies neither entropy nor token verification. A
// configured adapter is an explicit trust boundary, not cryptographic proof;
// callback exceptions and retained request copies are not managed here. The
// store callback owns the record and samples its clock after entering its
// atomic section. Gleam values are copyable; this reducer proves no concurrency.

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
    exchange: fn(ExchangeRequest) -> Result(BackendAttestation, BackendError),
  )
}

pub fn trust_adapter(
  client: Client,
  declaration: AdapterDeclaration,
  exchange: fn(ExchangeRequest) -> Result(BackendAttestation, BackendError),
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

pub opaque type Session {
  Session(VerifiedIdentity)
}

pub fn session_identity(session: Session) -> VerifiedIdentity {
  let Session(identity) = session
  identity
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
  checked: CheckedOutcome,
) -> Result(Session, CompleteLoginError) {
  let VerificationBackend(backend_client, _, _) = backend
  case checked_client(checked) == backend_client {
    False -> Error(BackendConfigurationMismatch)
    True ->
      case checked {
        CodeReady(callback) -> complete_code(store, backend, callback)
        ProviderDenied(denial) -> complete_denial(store, denial)
      }
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
  checked: CheckedCallback,
) -> Result(Session, CompleteLoginError) {
  case consume_checked(store, CodeReady(checked)) {
    Error(error) -> Error(ConsumptionFailed(error))
    Ok(Nil) -> exchange_consumed_code(backend, checked)
  }
}

fn complete_denial(
  store: TransactionStore,
  denial: CheckedDenial,
) -> Result(Session, CompleteLoginError) {
  case consume_checked(store, ProviderDenied(denial)) {
    Error(error) -> Error(ConsumptionFailed(error))
    Ok(Nil) -> Error(ProviderRejection(denial.classification))
  }
}

fn exchange_consumed_code(
  backend: VerificationBackend,
  checked: CheckedCallback,
) -> Result(Session, CompleteLoginError) {
  let CheckedCallback(transaction, _, code) = checked
  let Transaction(_, client, _, nonce, verifier, _) = transaction
  let VerificationBackend(_, _, exchange) = backend
  let request = ExchangeRequest(client, code, nonce, verifier)
  case exchange(request) {
    Error(error) -> Error(BackendFailed(error))
    Ok(attestation) -> validate_attestation(client, attestation)
  }
}

fn validate_attestation(
  client: Client,
  attestation: BackendAttestation,
) -> Result(Session, CompleteLoginError) {
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
                _ -> Ok(Session(VerifiedIdentity(issuer, Subject(subject))))
              }
          }
      }
  }
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
