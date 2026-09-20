// THROWAWAY: Can request-scoped exchanges own one pure Relay invocation?
import lab/relay
import lab/value.{type Value}

// IDs are local to one live Erlang VM. A runtime must prevent reuse while a
// callback for an older exchange can still arrive; restart recovery is absent.
pub opaque type ExchangeId {
  ExchangeId(Int)
}

pub fn fresh_exchange() -> ExchangeId {
  ExchangeId(unique_integer())
}

pub opaque type InvocationId {
  InvocationId(Int)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

pub type RequestId {
  RequestString(String)
  RequestInteger(Int)
}

pub type ProgressToken {
  ProgressString(String)
  ProgressInteger(Int)
}

pub type Optional(a) {
  Absent
  Present(a)
}

pub type ParsedCall(context) {
  ParsedCall(
    context: context,
    request_id: RequestId,
    progress_token: Optional(ProgressToken),
    tool_name: String,
    arguments: Value,
  )
}

pub type ServerInput(context) {
  Begin(exchange: ExchangeId, call: ParsedCall(context))
  Finished(
    invocation: InvocationId,
    outcome: Result(Value, relay.DispatchError),
  )
  Progress(invocation: InvocationId, value: Int)
  Closed(exchange: ExchangeId)
}

pub opaque type Server(context) {
  Server(
    dispatch: fn(context, String, Value) -> Result(Value, relay.DispatchError),
    exchanges: List(ExchangeRecord),
  )
}

pub fn server(registry: relay.Registry(context)) -> Server(context) {
  server_with_dispatch(fn(context, name, arguments) {
    relay.dispatch(registry, context, name, arguments)
  })
}

// The runtime task keeps the dispatch boundary selected by its server adapter.
// Protected adapters use this to retain the real authorization-aware callback
// rather than checking a grant and then dispatching through a raw registry.
pub fn server_with_dispatch(
  dispatch: fn(context, String, Value) -> Result(Value, relay.DispatchError),
) -> Server(context) {
  Server(dispatch, [])
}

pub type ServerEffect(context) {
  OpenStream(exchange: ExchangeId)
  Invoke(Invocation(context))
  SendProgress(exchange: ExchangeId, token: ProgressToken, value: Int)
  Complete(
    exchange: ExchangeId,
    request_id: RequestId,
    outcome: Result(Value, relay.DispatchError),
  )
  Cancel(invocation: InvocationId)
  CloseStream(exchange: ExchangeId)
}

// The task contains the exact registry, request context, tool name, and raw
// arguments chosen for this exchange. Calling perform is outside the reducer.
pub opaque type Invocation(context) {
  Invocation(
    id: InvocationId,
    dispatch: fn(context, String, Value) -> Result(Value, relay.DispatchError),
    context: context,
    tool_name: String,
    arguments: Value,
  )
}

pub fn invocation_id(invocation: Invocation(context)) -> InvocationId {
  invocation.id
}

pub fn invocation_context(invocation: Invocation(context)) -> context {
  invocation.context
}

pub fn perform(invocation: Invocation(context)) -> ServerInput(context) {
  let Invocation(id, dispatch, context, tool_name, arguments) = invocation
  Finished(id, dispatch(context, tool_name, arguments))
}

type ExchangeRecord {
  ActiveExchange(
    exchange: ExchangeId,
    request_id: RequestId,
    progress_token: Optional(ProgressToken),
    invocation: Optional(InvocationId),
    status: ExchangeStatus,
    latest_progress: Optional(Int),
  )
  ImmediateExchange(ExchangeId)
  Preclosed(ExchangeId)
}

type ExchangeStatus {
  ExchangeOpen
  ExchangeTerminal
  ExchangeClosed
}

pub fn step(
  server: Server(context),
  input: ServerInput(context),
) -> #(Server(context), List(ServerEffect(context))) {
  case input {
    Begin(exchange, call) -> begin(server, exchange, call)
    Finished(invocation, outcome) -> finish(server, invocation, outcome)
    Progress(invocation, value) -> progress(server, invocation, value)
    Closed(exchange) -> close(server, exchange)
  }
}

// Immediate JSON-RPC responses and notifications share the same exchange
// ownership record as tool calls. The returned boolean is an admission result,
// not a concurrency or persistence guarantee for copied Gleam values.
pub fn claim_exchange(
  server: Server(context),
  exchange: ExchangeId,
) -> #(Server(context), Bool) {
  let Server(dispatch, exchanges) = server
  case find_exchange(exchanges, exchange) {
    Present(_) -> #(server, False)
    Absent -> #(
      Server(dispatch, [ImmediateExchange(exchange), ..exchanges]),
      True,
    )
  }
}

fn begin(
  server: Server(context),
  exchange: ExchangeId,
  call: ParsedCall(context),
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(dispatch, exchanges) = server
  case find_exchange(exchanges, exchange) {
    Present(_) -> #(server, [])
    Absent -> {
      let id = invocation_for(exchange)
      let record =
        ActiveExchange(
          exchange,
          call.request_id,
          call.progress_token,
          Present(id),
          ExchangeOpen,
          Absent,
        )
      let invocation =
        Invocation(id, dispatch, call.context, call.tool_name, call.arguments)
      #(Server(dispatch, [record, ..exchanges]), [
        OpenStream(exchange),
        Invoke(invocation),
      ])
    }
  }
}

fn finish(
  server: Server(context),
  invocation: InvocationId,
  outcome: Result(Value, relay.DispatchError),
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(dispatch, exchanges) = server
  case find_invocation(exchanges, invocation) {
    Absent -> #(server, [])
    Present(ActiveExchange(exchange, request_id, _, Present(_), ExchangeOpen, _)) -> {
      let updated =
        replace_invocation_status(exchanges, invocation, ExchangeTerminal)
      let effects = [
        Complete(exchange, request_id, outcome),
        CloseStream(exchange),
      ]
      #(Server(dispatch, updated), effects)
    }
    Present(_) -> #(server, [])
  }
}

fn progress(
  server: Server(context),
  invocation: InvocationId,
  value: Int,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(dispatch, exchanges) = server
  case find_invocation(exchanges, invocation) {
    Absent -> #(server, [])
    Present(Preclosed(_)) -> #(server, [])
    Present(ImmediateExchange(_)) -> #(server, [])
    Present(ActiveExchange(exchange, _, token, _, status, latest)) ->
      case status, token, valid_progress(value, latest) {
        ExchangeOpen, Present(retained_token), True -> {
          let updated = replace_progress(exchanges, invocation, value)
          #(Server(dispatch, updated), [
            SendProgress(exchange, retained_token, value),
          ])
        }
        _, _, _ -> #(server, [])
      }
  }
}

fn close(
  server: Server(context),
  exchange: ExchangeId,
) -> #(Server(context), List(ServerEffect(context))) {
  let Server(dispatch, exchanges) = server
  case find_exchange(exchanges, exchange) {
    Absent -> #(Server(dispatch, [Preclosed(exchange), ..exchanges]), [])
    Present(Preclosed(_)) -> #(server, [])
    Present(ActiveExchange(_, _, _, invocation, ExchangeOpen, _)) -> {
      let next = replace_exchange_status(exchanges, exchange, ExchangeClosed)
      let effects = case invocation {
        Present(id) -> [Cancel(id), CloseStream(exchange)]
        Absent -> [CloseStream(exchange)]
      }
      #(Server(dispatch, next), effects)
    }
    Present(_) -> #(server, [])
  }
}

fn invocation_for(exchange: ExchangeId) -> InvocationId {
  let ExchangeId(value) = exchange
  InvocationId(value)
}

fn valid_progress(value: Int, latest: Optional(Int)) -> Bool {
  case latest {
    Absent -> value >= 0
    Present(previous) -> value >= 0 && value > previous
  }
}

fn find_exchange(
  exchanges: List(ExchangeRecord),
  exchange: ExchangeId,
) -> Optional(ExchangeRecord) {
  case exchanges {
    [] -> Absent
    [ActiveExchange(id, _, _, _, _, _) as record, ..rest] ->
      case id == exchange {
        True -> Present(record)
        False -> find_exchange(rest, exchange)
      }
    [Preclosed(id) as record, ..rest] ->
      case id == exchange {
        True -> Present(record)
        False -> find_exchange(rest, exchange)
      }
    [ImmediateExchange(id) as record, ..rest] ->
      case id == exchange {
        True -> Present(record)
        False -> find_exchange(rest, exchange)
      }
  }
}

fn find_invocation(
  exchanges: List(ExchangeRecord),
  invocation: InvocationId,
) -> Optional(ExchangeRecord) {
  case exchanges {
    [] -> Absent
    [ActiveExchange(_, _, _, Present(id), _, _) as record, ..rest] ->
      case id == invocation {
        True -> Present(record)
        False -> find_invocation(rest, invocation)
      }
    [_record, ..rest] -> find_invocation(rest, invocation)
  }
}

fn replace_invocation_status(
  exchanges: List(ExchangeRecord),
  invocation: InvocationId,
  status: ExchangeStatus,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [
      ActiveExchange(exchange, request_id, token, Present(id), _, latest) as record,
      ..rest
    ] ->
      case id == invocation {
        True -> [
          ActiveExchange(
            exchange,
            request_id,
            token,
            Present(id),
            status,
            latest,
          ),
          ..rest
        ]
        False -> [record, ..replace_invocation_status(rest, invocation, status)]
      }
    [record, ..rest] -> [
      record,
      ..replace_invocation_status(rest, invocation, status)
    ]
  }
}

fn replace_progress(
  exchanges: List(ExchangeRecord),
  invocation: InvocationId,
  value: Int,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [
      ActiveExchange(exchange, request_id, token, Present(id), status, _) as record,
      ..rest
    ] ->
      case id == invocation {
        True -> [
          ActiveExchange(
            exchange,
            request_id,
            token,
            Present(id),
            status,
            Present(value),
          ),
          ..rest
        ]
        False -> [record, ..replace_progress(rest, invocation, value)]
      }
    [record, ..rest] -> [record, ..replace_progress(rest, invocation, value)]
  }
}

fn replace_exchange_status(
  exchanges: List(ExchangeRecord),
  target: ExchangeId,
  status: ExchangeStatus,
) -> List(ExchangeRecord) {
  case exchanges {
    [] -> []
    [
      ActiveExchange(exchange, request_id, token, invocation, _, latest) as record,
      ..rest
    ] ->
      case exchange == target {
        True -> [
          ActiveExchange(
            exchange,
            request_id,
            token,
            invocation,
            status,
            latest,
          ),
          ..rest
        ]
        False -> [record, ..replace_exchange_status(rest, target, status)]
      }
    [record, ..rest] -> [
      record,
      ..replace_exchange_status(rest, target, status)
    ]
  }
}
// Tombstones are retained in this unbounded in-memory model. A host must own
// one authoritative serialized history and define real retention and replay.
