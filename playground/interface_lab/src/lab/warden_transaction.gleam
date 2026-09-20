// THROWAWAY: Can callback checks feed one revision-bound atomic consumption boundary?
// This type experiment supplies neither entropy nor token verification. The
// store callback owns the record and must sample its injected clock only after
// entering its atomic critical section. Gleam values are copyable; the pure
// reducer does not prove concurrency behavior or erase copies held elsewhere.

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
    ProviderDenied(CheckedDenial(id, _, _)) -> id
  }
}

pub fn checked_outcome_revision(outcome: CheckedOutcome) -> StoredRevision {
  case outcome {
    CodeReady(CheckedCallback(_, revision, _)) -> revision
    ProviderDenied(CheckedDenial(_, revision, _)) -> revision
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
    CallbackRejected(reason) ->
      Ok(ProviderDenied(CheckedDenial(id, revision, denial_class(reason))))
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
    ProviderDenied(CheckedDenial(id, revision, _)) ->
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
  let command = consume_command(checked)
  let public_success = public_success(checked)
  let TransactionStore(clock, atomic_consume) = store
  case atomic_consume(command, clock) {
    Decided(WasConsumed) -> Ok(public_success)
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
