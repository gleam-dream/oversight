// THROWAWAY: Can app-owned request context bind one function to Relay and Fabric?
import lab/blueprint.{type Codec, type DecodeError}
import lab/fabric
import lab/hellhound.{type VerifiedIdentity}
import lab/relay
import lab/value

pub opaque type TenantId {
  TenantId(String)
}

pub fn tenant_id(value: String) -> TenantId {
  TenantId(value)
}

fn tenant_id_value(id: TenantId) -> String {
  let TenantId(value) = id
  value
}

pub type RequestContext {
  RequestContext(tenant: TenantId, identity: VerifiedIdentity)
}

pub type OrderLookup {
  OrderLookup(order_id: String, tenant: TenantId)
}

pub type OrderSummary {
  OrderSummary(String)
}

pub type AppError {
  AuthorizationDenied
  TenantDoesNotMatch
  OrderUnavailable
  ContextReloadFailed
}

pub type AppPolicy =
  fn(RequestContext, OrderLookup) -> Result(Nil, AppError)

pub type ToolRegistries {
  ToolRegistries(relay_tools: List(relay.Tool), fabric_tools: List(fabric.Tool))
}

// The same ordinary typed function is bound separately into two registries.
// Authorization runs first inside the closure that captures this request's context.
pub fn registries(
  context: RequestContext,
  policy: AppPolicy,
) -> ToolRegistries {
  let handler = authorize_then_run(context, policy, lookup_order)
  let input = order_lookup_codec()
  let output = order_summary_codec()
  let error = app_error_codec()
  let relay_tool = relay.tool("get-order", input, output, error, handler)
  let fabric_tool = fabric.tool("get-order", input, output, error, handler)
  ToolRegistries([relay_tool], [fabric_tool])
}

fn authorize_then_run(
  context: RequestContext,
  policy: AppPolicy,
  operation: fn(RequestContext, OrderLookup) -> Result(OrderSummary, AppError),
) -> fn(OrderLookup) -> Result(OrderSummary, AppError) {
  fn(input) {
    case policy(context, input) {
      Error(error) -> Error(error)
      Ok(Nil) -> operation(context, input)
    }
  }
}

// This is an ordinary application function. The registries don't own its
// request context, policy, or tenant rules.
fn lookup_order(
  context: RequestContext,
  input: OrderLookup,
) -> Result(OrderSummary, AppError) {
  let RequestContext(tenant, identity) = context
  let OrderLookup(order_id, requested_tenant) = input
  case tenant == requested_tenant {
    False -> Error(TenantDoesNotMatch)
    True -> {
      let requester = hellhound.subject(identity)
      Ok(OrderSummary(
        "tenant="
        <> tenant_id_value(tenant)
        <> "; order="
        <> order_id
        <> "; requester="
        <> requester,
      ))
    }
  }
}

pub opaque type RequestId {
  RequestId(String)
}

pub fn request_id(value: String) -> RequestId {
  RequestId(value)
}

pub opaque type JobPayload {
  JobPayload(request_id: RequestId)
}

pub fn job_payload(id: RequestId) -> JobPayload {
  JobPayload(id)
}

// Only this opaque ID crosses the job boundary. VerifiedIdentity stays in the
// request process and is reloaded by the worker callback.
pub fn encode_job_payload(payload: JobPayload) -> value.Value {
  let JobPayload(RequestId(id)) = payload
  value.Object([#("request_id", value.Text(id))])
}

pub type JobPayloadDecodeError {
  InvalidJobPayload(DecodeError)
}

pub fn decode_job_payload(
  raw: value.Value,
) -> Result(JobPayload, JobPayloadDecodeError) {
  case raw {
    value.Object([#("request_id", value.Text(id))]) ->
      Ok(JobPayload(RequestId(id)))
    _ ->
      Error(
        InvalidJobPayload(blueprint.CannotDecode("Expected opaque request id")),
      )
  }
}

pub type ReloadAuthorization =
  fn(RequestId) -> Result(#(RequestContext, OrderLookup), AppError)

// The worker loads current authorization data through an injected application
// function, then applies the same policy before calling the ordinary operation.
pub fn handle_job(
  payload: JobPayload,
  reload_authorization: ReloadAuthorization,
  policy: AppPolicy,
) -> Result(OrderSummary, AppError) {
  let JobPayload(id) = payload
  case reload_authorization(id) {
    Error(error) -> Error(error)
    Ok(#(context, input)) ->
      authorize_then_run(context, policy, lookup_order)(input)
  }
}

fn order_lookup_codec() -> Codec(OrderLookup) {
  blueprint.new(
    fn(input) {
      let OrderLookup(order_id, tenant) = input
      Ok(
        value.Object([
          #("order_id", value.Text(order_id)),
          #("tenant_id", value.Text(tenant_id_value(tenant))),
        ]),
      )
    },
    fn(raw) {
      case raw {
        value.Object([
          #("order_id", value.Text(order_id)),
          #("tenant_id", value.Text(tenant)),
        ]) -> Ok(OrderLookup(order_id, TenantId(tenant)))
        _ -> Error(blueprint.CannotDecode("Expected order id and tenant id"))
      }
    },
  )
}

fn order_summary_codec() -> Codec(OrderSummary) {
  blueprint.new(
    fn(summary) {
      let OrderSummary(text) = summary
      Ok(value.Object([#("summary", value.Text(text))]))
    },
    fn(raw) {
      case raw {
        value.Object([#("summary", value.Text(text))]) -> Ok(OrderSummary(text))
        _ -> Error(blueprint.CannotDecode("Expected order summary"))
      }
    },
  )
}

fn app_error_codec() -> Codec(AppError) {
  blueprint.new(
    fn(error) {
      case error {
        AuthorizationDenied -> Ok(value.Text("authorization_denied"))
        TenantDoesNotMatch -> Ok(value.Text("tenant_does_not_match"))
        OrderUnavailable -> Ok(value.Text("order_unavailable"))
        ContextReloadFailed -> Ok(value.Text("context_reload_failed"))
      }
    },
    fn(raw) {
      case raw {
        value.Text("authorization_denied") -> Ok(AuthorizationDenied)
        value.Text("tenant_does_not_match") -> Ok(TenantDoesNotMatch)
        value.Text("order_unavailable") -> Ok(OrderUnavailable)
        value.Text("context_reload_failed") -> Ok(ContextReloadFailed)
        _ -> Error(blueprint.CannotDecode("Unknown application error"))
      }
    },
  )
}
