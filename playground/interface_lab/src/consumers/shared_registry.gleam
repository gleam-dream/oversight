// THROWAWAY: Can adapters share one context tool without a universal context type?
import lab/blueprint
import lab/fabric
import lab/relay
import lab/value

pub type TenantContext {
  TenantContext(tenant: String, allowed: Bool)
}

pub type LookupError {
  AccessDenied
  LookupUnavailable
}

pub type Policy =
  fn(TenantContext, String) -> Result(Nil, LookupError)

pub type RegistryPair {
  RegistryPair(
    relay: relay.ContextTool(TenantContext),
    fabric: fabric.ContextTool(TenantContext),
  )
}

// Each adapter gets its own context tool and maps into the same application
// function. Context stays a caller-supplied type owned by this application.
pub fn registries(policy: Policy) -> RegistryPair {
  let relay_handler = fn(context, input) {
    authorize_then_lookup(context, input, policy, lookup_record)
  }
  let fabric_handler = fn(context, input) {
    authorize_then_lookup(context, input, policy, lookup_record)
  }
  RegistryPair(
    relay.context_tool(
      "lookup",
      blueprint.text(),
      blueprint.text(),
      lookup_error_codec(),
      relay_handler,
    ),
    fabric.context_tool(
      "lookup",
      blueprint.text(),
      blueprint.text(),
      lookup_error_codec(),
      fabric_handler,
    ),
  )
}

pub fn probe() -> Nil {
  let RegistryPair(relay_tool, fabric_tool) = registries(allow_context)
  let tenant_a = TenantContext("tenant-a", True)
  let tenant_b = TenantContext("tenant-b", True)
  let denied = TenantContext("tenant-denied", False)
  let input = value.Text("invoice-7")
  case
    relay.invoke_context(relay_tool, tenant_a, input),
    relay.invoke_context(relay_tool, tenant_b, input),
    relay.invoke_context(relay_tool, denied, input),
    fabric.invoke_context(fabric_tool, tenant_a, input),
    fabric.invoke_context(fabric_tool, tenant_b, input),
    fabric.invoke_context(fabric_tool, denied, input)
  {
    Ok(value.Text("tenant-a:invoice-7")),
      Ok(value.Text("tenant-b:invoice-7")),
      Error(relay.ApplicationFailure(value.Text("access denied"))),
      Ok(value.Text("tenant-a:invoice-7")),
      Ok(value.Text("tenant-b:invoice-7")),
      Error(fabric.ActionFailed(value.Text("access denied")))
    -> Nil
    _, _, _, _, _, _ ->
      panic as "both adapters must bind independent contexts and preserve policy errors"
  }
  let assert Error(AccessDenied) =
    authorize_then_lookup(denied, "invoice-7", allow_context, fn(_, _) {
      panic as "authorization denial must prevent invocation"
    })
  Nil
}

fn authorize_then_lookup(
  context: TenantContext,
  input: String,
  policy: Policy,
  operation: fn(TenantContext, String) -> Result(String, LookupError),
) -> Result(String, LookupError) {
  case policy(context, input) {
    Error(error) -> Error(error)
    Ok(Nil) -> operation(context, input)
  }
}

fn allow_context(
  context: TenantContext,
  _input: String,
) -> Result(Nil, LookupError) {
  case context.allowed {
    True -> Ok(Nil)
    False -> Error(AccessDenied)
  }
}

fn lookup_record(
  context: TenantContext,
  input: String,
) -> Result(String, LookupError) {
  Ok(context.tenant <> ":" <> input)
}

fn lookup_error_codec() -> blueprint.Codec(LookupError) {
  blueprint.new(
    fn(error) {
      case error {
        AccessDenied -> Ok(value.Text("access denied"))
        LookupUnavailable -> Ok(value.Text("lookup unavailable"))
      }
    },
    fn(raw) {
      case raw {
        value.Text("access denied") -> Ok(AccessDenied)
        value.Text("lookup unavailable") -> Ok(LookupUnavailable)
        _ -> Error(blueprint.CannotDecode("Expected lookup error"))
      }
    },
  )
}
