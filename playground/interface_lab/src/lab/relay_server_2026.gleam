// THROWAWAY: Can parsed modern calls reuse Relay exchange ownership and protected dispatch?
import lab/relay
import lab/relay_authorization as authorization
import lab/relay_exchange as exchange
import lab/relay_protocol_2026 as protocol
import lab/value.{type Value}

type CallContext(context, principal) {
  CallContext(
    grant: authorization.GrantedRequest(principal),
    application_context: context,
    metadata: protocol.RequestMetadata,
  )
}

pub opaque type Server(context, principal) {
  Server(
    protected_registry: authorization.ProtectedRegistry(context, principal),
    exchanges: exchange.Server(CallContext(context, principal)),
  )
}

pub fn server(
  registry: authorization.ProtectedRegistry(context, principal),
) -> Server(context, principal) {
  let dispatch = fn(call_context, name, arguments) {
    let CallContext(grant, application_context, _) = call_context
    case
      authorization.dispatch_granted(
        registry,
        application_context,
        grant,
        name,
        arguments,
      )
    {
      Ok(output) -> Ok(output)
      Error(authorization.InaccessibleTool(_)) -> Error(relay.UnknownTool(name))
      Error(authorization.GrantUseFailed(_)) -> Error(relay.UnknownTool(name))
      Error(authorization.InvocationFailed(error)) ->
        Error(relay.InvocationFailed(error))
    }
  }
  Server(registry, exchange.server_with_dispatch(dispatch))
}

pub type Input(context, principal) {
  RequestReceived(
    exchange: exchange.ExchangeId,
    application_context: context,
    grant: authorization.GrantedRequest(principal),
    message: Value,
  )
  ToolFinished(
    invocation: exchange.InvocationId,
    outcome: Result(Value, relay.DispatchError),
  )
  ToolProgress(invocation: exchange.InvocationId, value: Int)
  ResponseStreamClosed(exchange: exchange.ExchangeId)
}

pub type Effect(context, principal) {
  Response(exchange: exchange.ExchangeId, body: Value)
  UnhandledMessage(
    exchange: exchange.ExchangeId,
    reason: protocol.UnhandledReason,
  )
  OpenResponseStream(exchange.ExchangeId)
  Invoke(Invocation(context, principal))
  SendProgress(exchange.ExchangeId, body: Value)
  CancelInvocation(exchange.InvocationId)
  CloseResponseStream(exchange.ExchangeId)
}

pub opaque type Invocation(context, principal) {
  Invocation(exchange.Invocation(CallContext(context, principal)))
}

pub fn invocation_id(
  invocation: Invocation(context, principal),
) -> exchange.InvocationId {
  let Invocation(task) = invocation
  exchange.invocation_id(task)
}

pub fn invocation_metadata(
  invocation: Invocation(context, principal),
) -> protocol.RequestMetadata {
  let Invocation(task) = invocation
  let CallContext(_, _, metadata) = exchange.invocation_context(task)
  metadata
}

// Calling the handler is outside the server reducer and remains attached to
// the exact protected dispatcher selected when the server was configured.
pub fn perform(
  invocation: Invocation(context, principal),
) -> Input(context, principal) {
  let Invocation(task) = invocation
  let assert exchange.Finished(id, outcome) = exchange.perform(task)
  ToolFinished(id, outcome)
}

pub fn step(
  server: Server(context, principal),
  input: Input(context, principal),
) -> #(Server(context, principal), List(Effect(context, principal))) {
  let Server(protected_registry, exchanges) = server
  case input {
    RequestReceived(exchange_id, application_context, grant, message) ->
      route_request(
        protected_registry,
        exchanges,
        exchange_id,
        application_context,
        grant,
        message,
      )
    ToolFinished(invocation, outcome) -> {
      let #(next, effects) =
        exchange.step(exchanges, exchange.Finished(invocation, outcome))
      #(Server(protected_registry, next), translate_effects(effects))
    }
    ToolProgress(invocation, value) -> {
      let #(next, effects) =
        exchange.step(exchanges, exchange.Progress(invocation, value))
      #(Server(protected_registry, next), translate_effects(effects))
    }
    ResponseStreamClosed(exchange_id) -> {
      let #(next, effects) =
        exchange.step(exchanges, exchange.Closed(exchange_id))
      #(Server(protected_registry, next), translate_effects(effects))
    }
  }
}

fn route_request(
  protected_registry: authorization.ProtectedRegistry(context, principal),
  exchanges: exchange.Server(CallContext(context, principal)),
  exchange_id: exchange.ExchangeId,
  application_context: context,
  grant: authorization.GrantedRequest(principal),
  message: Value,
) -> #(Server(context, principal), List(Effect(context, principal))) {
  case protocol.admit(message) {
    protocol.Rejected(request_id, error) ->
      respond_once(
        protected_registry,
        exchanges,
        exchange_id,
        protocol.error_response(request_id, error),
      )
    protocol.UnsupportedNotification -> {
      let #(next, admitted) = exchange.claim_exchange(exchanges, exchange_id)
      case admitted {
        True -> #(Server(protected_registry, next), [
          UnhandledMessage(exchange_id, protocol.UnsupportedNotificationReason),
        ])
        False -> #(Server(protected_registry, next), [])
      }
    }
    protocol.UnexpectedResponseMessage -> {
      let #(next, admitted) = exchange.claim_exchange(exchanges, exchange_id)
      case admitted {
        True -> #(Server(protected_registry, next), [
          UnhandledMessage(exchange_id, protocol.UnexpectedResponseReason),
        ])
        False -> #(Server(protected_registry, next), [])
      }
    }
    protocol.Admitted(request) ->
      route_admitted_request(
        protected_registry,
        exchanges,
        exchange_id,
        application_context,
        grant,
        request,
      )
  }
}

fn route_admitted_request(
  protected_registry: authorization.ProtectedRegistry(context, principal),
  exchanges: exchange.Server(CallContext(context, principal)),
  exchange_id: exchange.ExchangeId,
  application_context: context,
  grant: authorization.GrantedRequest(principal),
  request: protocol.Request,
) -> #(Server(context, principal), List(Effect(context, principal))) {
  case request {
    protocol.Discover(request_id, _) ->
      respond_once(
        protected_registry,
        exchanges,
        exchange_id,
        protocol.discovery_result(request_id),
      )
    protocol.ToolsList(request_id, _, exchange.Present(_cursor)) ->
      respond_once(
        protected_registry,
        exchanges,
        exchange_id,
        protocol.error_response(
          exchange.Present(request_id),
          protocol.InvalidParams,
        ),
      )
    protocol.ToolsList(request_id, _, exchange.Absent) -> {
      let #(next, admitted) = exchange.claim_exchange(exchanges, exchange_id)
      case admitted {
        False -> #(Server(protected_registry, next), [])
        True ->
          case
            authorization.visible_declarations(
              protected_registry,
              application_context,
              grant,
            )
          {
            Ok(declarations) -> #(Server(protected_registry, next), [
              Response(
                exchange_id,
                protocol.tools_result(request_id, declarations),
              ),
            ])
            Error(_) -> #(Server(protected_registry, next), [
              Response(
                exchange_id,
                protocol.error_response(
                  exchange.Present(request_id),
                  protocol.InvalidParams,
                ),
              ),
            ])
          }
      }
    }
    protocol.ToolsCall(request_id, metadata, name, arguments) -> {
      let call_context = CallContext(grant, application_context, metadata)
      let parsed_call =
        exchange.ParsedCall(
          call_context,
          request_id,
          metadata.progress_token,
          name,
          arguments,
        )
      let #(next, effects) =
        exchange.step(exchanges, exchange.Begin(exchange_id, parsed_call))
      #(Server(protected_registry, next), translate_effects(effects))
    }
  }
}

fn respond_once(
  protected_registry: authorization.ProtectedRegistry(context, principal),
  exchanges: exchange.Server(CallContext(context, principal)),
  exchange_id: exchange.ExchangeId,
  body: Value,
) -> #(Server(context, principal), List(Effect(context, principal))) {
  let #(next, admitted) = exchange.claim_exchange(exchanges, exchange_id)
  case admitted {
    True -> #(Server(protected_registry, next), [Response(exchange_id, body)])
    False -> #(Server(protected_registry, next), [])
  }
}

fn translate_effects(
  effects: List(exchange.ServerEffect(CallContext(context, principal))),
) -> List(Effect(context, principal)) {
  case effects {
    [] -> []
    [effect, ..rest] -> [translate_effect(effect), ..translate_effects(rest)]
  }
}

fn translate_effect(
  effect: exchange.ServerEffect(CallContext(context, principal)),
) -> Effect(context, principal) {
  case effect {
    exchange.OpenStream(exchange_id) -> OpenResponseStream(exchange_id)
    exchange.Invoke(task) -> Invoke(Invocation(task))
    exchange.SendProgress(exchange_id, token, value) ->
      SendProgress(exchange_id, protocol.progress_notification(token, value))
    exchange.Complete(exchange_id, request_id, outcome) ->
      Response(exchange_id, protocol.call_response(request_id, outcome))
    exchange.Cancel(invocation) -> CancelInvocation(invocation)
    exchange.CloseStream(exchange_id) -> CloseResponseStream(exchange_id)
  }
}
