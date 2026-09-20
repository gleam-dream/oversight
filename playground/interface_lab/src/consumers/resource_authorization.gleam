// THROWAWAY: Can Relay retain a verified grant and reauthorize each tool call?
import lab/blueprint
import lab/relay
import lab/relay_authorization as authorization
import lab/value

pub opaque type TenantId {
  TenantId(String)
}

pub fn tenant_id(raw: String) -> TenantId {
  TenantId(raw)
}

fn tenant_id_value(tenant: TenantId) -> String {
  let TenantId(raw) = tenant
  raw
}

pub opaque type ServicePrincipal {
  ServicePrincipal(id: String, tenant: TenantId)
}

pub fn service_principal(id: String, tenant: TenantId) -> ServicePrincipal {
  ServicePrincipal(id, tenant)
}

fn principal_id(principal: ServicePrincipal) -> String {
  let ServicePrincipal(id, _) = principal
  id
}

fn principal_tenant(principal: ServicePrincipal) -> TenantId {
  let ServicePrincipal(_, tenant) = principal
  tenant
}

pub type RequestContext {
  RequestContext(tenant: TenantId, archive_visible: Bool, archive_allowed: Bool)
}

pub type LookupInput {
  LookupInput(invoice_id: String, tenant: TenantId)
}

pub type ArchiveInput {
  ArchiveInput
}

type LookupError {
  TenantMismatch
}

pub fn probe() -> Nil {
  let assert Error(authorization.EmptyBearerToken) =
    authorization.bearer_token("")
  let assert Error(authorization.EmptyResource) = authorization.resource("")
  let assert Error(authorization.EmptyScope) = authorization.scope("")
  let assert Ok(token_resource) =
    authorization.resource("https://billing.example/api")
  let assert Ok(other_resource) =
    authorization.resource("https://reports.example/api")
  let assert Ok(read_scope) = authorization.scope("invoice:read")
  let assert Ok(archive_scope) = authorization.scope("invoice:archive")
  let assert Ok(support_scope) = authorization.scope("support:open")
  let tenant = tenant_id("tenant-acme")
  let principal = service_principal("billing-worker", tenant)
  let weak_protection =
    authorization.protection_config(token_resource, [read_scope])
  let strong_protection =
    authorization.protection_config(token_resource, [read_scope, archive_scope])
  let full_attestation =
    authorization.VerifierAttestation(principal, [token_resource], [
      read_scope,
      archive_scope,
      support_scope,
    ])
  let configured_verifier = verifier_for(full_attestation)
  let assert authorization.VerifierDeclaration(
    "billing-token-adapter",
    "test-profile-1",
    authorization.TestOnlyVerifier,
  ) = authorization.verifier_declaration(configured_verifier)
  let assert Ok(presented_token) =
    authorization.bearer_token("bearer-sentinel-42")
  let assert Ok(grant) =
    authorization.admit(configured_verifier, presented_token, weak_protection)
  let assert Ok(wrong_sentinel) = authorization.bearer_token("not-the-sentinel")
  let assert Error(authorization.VerificationFailed(
    authorization.BearerRejected,
  )) = authorization.admit(configured_verifier, wrong_sentinel, weak_protection)
  let assert True = authorization.grant_principal(grant) == principal
  let assert True = authorization.grant_resource(grant) == token_resource
  let assert True =
    authorization.grant_scopes(grant)
    == [read_scope, archive_scope, support_scope]

  let assert Error(authorization.ResourceNotGranted) =
    admit_attestation(
      authorization.VerifierAttestation(principal, [other_resource], [
        read_scope,
        archive_scope,
      ]),
      weak_protection,
    )
  let assert Error(authorization.ResourceNotGranted) =
    admit_attestation(
      authorization.VerifierAttestation(
        principal,
        [token_resource, other_resource],
        [read_scope, archive_scope],
      ),
      weak_protection,
    )
  let assert Error(authorization.ResourceNotGranted) =
    admit_attestation(
      authorization.VerifierAttestation(
        principal,
        [token_resource, token_resource],
        [read_scope, archive_scope],
      ),
      weak_protection,
    )
  let assert Error(authorization.ResourceNotGranted) =
    admit_attestation(
      authorization.VerifierAttestation(principal, [], [read_scope]),
      weak_protection,
    )
  let assert Error(authorization.MissingEndpointScope(missing_admission_scope)) =
    admit_attestation(
      authorization.VerifierAttestation(principal, [token_resource], [
        archive_scope,
      ]),
      weak_protection,
    )
  let assert True = missing_admission_scope == read_scope

  let assert Ok(registry) = relay.registry([lookup_tool(), archive_tool()])
  let old_context = RequestContext(tenant, True, True)
  let protected =
    authorization.protect_registry(
      weak_protection,
      registry,
      service_policy(archive_scope),
    )
  let assert Ok([
    relay.Declaration("lookup-invoice", _),
    relay.Declaration("archive-invoice", _),
  ]) = authorization.visible_declarations(protected, old_context, grant)
  let assert Ok(value.Text("tenant=tenant-acme; invoice=inv-42")) =
    authorization.dispatch_granted(
      protected,
      old_context,
      grant,
      "lookup-invoice",
      lookup_value("inv-42", tenant),
    )

  // The grant retains archive scope while admitted under the weaker endpoint.
  let strong_registry =
    authorization.protect_registry(
      strong_protection,
      registry,
      service_policy(archive_scope),
    )
  let assert Ok([_, _]) =
    authorization.visible_declarations(strong_registry, old_context, grant)
  let assert Ok(value.Text("tenant=tenant-acme; invoice=inv-42")) =
    authorization.dispatch_granted(
      strong_registry,
      old_context,
      grant,
      "lookup-invoice",
      lookup_value("inv-42", tenant),
    )

  // Resource and endpoint-scope rechecks precede even a policy that panics.
  let wrong_resource_registry =
    authorization.protect_registry(
      authorization.protection_config(other_resource, [read_scope]),
      registry,
      panic_policy(),
    )
  let assert Error(authorization.GrantResourceMismatch) =
    authorization.visible_declarations(
      wrong_resource_registry,
      old_context,
      grant,
    )
  let assert Error(authorization.GrantUseFailed(
    authorization.GrantResourceMismatch,
  )) =
    authorization.dispatch_granted(
      wrong_resource_registry,
      old_context,
      grant,
      "archive-invoice",
      archive_value("inv-42"),
    )

  let assert Ok(read_only_grant) =
    admit_attestation(
      authorization.VerifierAttestation(principal, [token_resource], [
        read_scope,
      ]),
      weak_protection,
    )
  let assert Ok([relay.Declaration("lookup-invoice", _)]) =
    authorization.visible_declarations(protected, old_context, read_only_grant)
  let assert Error(authorization.InaccessibleTool(authorization.HiddenTool)) =
    authorization.dispatch_granted(
      protected,
      old_context,
      read_only_grant,
      "archive-invoice",
      archive_value("inv-42"),
    )
  let assert Error(authorization.GrantMissingEndpointScope(missing_list_scope)) =
    authorization.visible_declarations(
      strong_registry,
      old_context,
      read_only_grant,
    )
  let assert True = missing_list_scope == archive_scope
  let assert Error(authorization.GrantUseFailed(authorization.GrantMissingEndpointScope(
    missing_dispatch_scope,
  ))) =
    authorization.dispatch_granted(
      authorization.protect_registry(
        strong_protection,
        registry,
        panic_policy(),
      ),
      old_context,
      read_only_grant,
      "archive-invoice",
      archive_value("inv-42"),
    )
  let assert True = missing_dispatch_scope == archive_scope

  // A current context can remove execution access after a visible listing.
  let current_denied_context = RequestContext(tenant, True, False)
  let assert Error(authorization.InaccessibleTool(authorization.ExecutionDenied)) =
    authorization.dispatch_granted(
      protected,
      current_denied_context,
      grant,
      "archive-invoice",
      archive_value("inv-42"),
    )

  let hidden_context = RequestContext(tenant, False, False)
  let assert Ok([relay.Declaration("lookup-invoice", _)]) =
    authorization.visible_declarations(protected, hidden_context, grant)
  let assert Error(authorization.InaccessibleTool(authorization.HiddenTool)) =
    authorization.dispatch_granted(
      protected,
      hidden_context,
      grant,
      "archive-invoice",
      archive_value("inv-42"),
    )
  let assert Error(authorization.InaccessibleTool(authorization.UnknownTool)) =
    authorization.dispatch_granted(
      protected,
      old_context,
      grant,
      "not-registered",
      archive_value("inv-42"),
    )
  let hidden_classification =
    authorization.external_classification(authorization.HiddenTool)
  let unknown_classification =
    authorization.external_classification(authorization.UnknownTool)
  let execution_classification =
    authorization.external_classification(authorization.ExecutionDenied)
  let assert True = hidden_classification == unknown_classification
  let assert True = unknown_classification == execution_classification

  // Input-dependent tenant authorization stays inside the typed handler.
  let other_tenant = tenant_id("tenant-other")
  let assert Error(authorization.InvocationFailed(relay.ApplicationFailure(value.Text(
    "tenant_mismatch",
  )))) =
    authorization.dispatch_granted(
      protected,
      old_context,
      grant,
      "lookup-invoice",
      lookup_value("inv-42", other_tenant),
    )
  Nil
}

fn verifier_for(
  attestation: authorization.VerifierAttestation(ServicePrincipal),
) -> authorization.Verifier(ServicePrincipal) {
  authorization.trust_verifier(
    authorization.VerifierDeclaration(
      "billing-token-adapter",
      "test-profile-1",
      authorization.TestOnlyVerifier,
    ),
    fn(token) {
      case authorization.bearer_token_value(token) == "bearer-sentinel-42" {
        True -> Ok(attestation)
        False -> Error(authorization.BearerRejected)
      }
    },
  )
}

fn admit_attestation(
  attestation: authorization.VerifierAttestation(ServicePrincipal),
  protection: authorization.ProtectionConfig,
) -> Result(
  authorization.GrantedRequest(ServicePrincipal),
  authorization.AdmissionError,
) {
  authorization.admit(verifier_for(attestation), sentinel_token(), protection)
}

fn sentinel_token() -> authorization.BearerToken {
  let assert Ok(token) = authorization.bearer_token("bearer-sentinel-42")
  token
}

fn lookup_tool() -> relay.ContextTool(RequestContext) {
  relay.context_tool(
    "lookup-invoice",
    lookup_input_codec(),
    blueprint.text(),
    lookup_error_codec(),
    lookup_invoice,
  )
}

fn archive_tool() -> relay.ContextTool(RequestContext) {
  relay.context_tool(
    "archive-invoice",
    archive_input_codec(),
    blueprint.text(),
    blueprint.text(),
    archive_invoice,
  )
}

fn lookup_input_codec() -> blueprint.Codec(LookupInput) {
  let assert Ok(properties) =
    blueprint.combine(
      blueprint.required("invoice_id", blueprint.text()),
      blueprint.required("tenant_id", blueprint.text()),
    )
  blueprint.imap(
    blueprint.object(properties),
    fn(pair) { LookupInput(pair.0, TenantId(pair.1)) },
    fn(input) {
      let LookupInput(invoice_id, TenantId(tenant)) = input
      #(invoice_id, tenant)
    },
  )
}

fn archive_input_codec() -> blueprint.Codec(ArchiveInput) {
  blueprint.imap(
    blueprint.field("invoice_id", blueprint.text()),
    fn(_) { panic as "archive input decoding must remain unreachable" },
    fn(_) { "unused" },
  )
}

fn lookup_value(invoice_id: String, tenant: TenantId) -> value.Value {
  value.Object([
    #("invoice_id", value.Text(invoice_id)),
    #("tenant_id", value.Text(tenant_id_value(tenant))),
  ])
}

fn archive_value(invoice_id: String) -> value.Value {
  value.Object([#("invoice_id", value.Text(invoice_id))])
}

fn lookup_error_codec() -> blueprint.Codec(LookupError) {
  blueprint.new(
    fn(error) {
      case error {
        TenantMismatch -> Ok(value.Text("tenant_mismatch"))
      }
    },
    fn(raw) {
      case raw {
        value.Text("tenant_mismatch") -> Ok(TenantMismatch)
        _ -> Error(blueprint.CannotDecode("Unknown lookup error"))
      }
    },
  )
}

fn lookup_invoice(
  context: RequestContext,
  input: LookupInput,
) -> Result(String, LookupError) {
  let RequestContext(context_tenant, _, _) = context
  let LookupInput(invoice_id, requested_tenant) = input
  case requested_tenant == context_tenant {
    False -> Error(TenantMismatch)
    True ->
      Ok(
        "tenant="
        <> tenant_id_value(context_tenant)
        <> "; invoice="
        <> invoice_id,
      )
  }
}

fn archive_invoice(
  _context: RequestContext,
  _input: ArchiveInput,
) -> Result(String, String) {
  panic as "archive handler must remain unreachable in this probe"
}

fn service_policy(
  archive_scope: authorization.Scope,
) -> authorization.ToolPolicy(RequestContext, ServicePrincipal) {
  authorization.tool_policy(
    fn(context, grant, declaration) {
      visible(archive_scope, context, grant, declaration)
    },
    fn(context, grant, declaration) {
      executable(archive_scope, context, grant, declaration)
    },
  )
}

fn visible(
  archive_scope: authorization.Scope,
  context: RequestContext,
  grant: authorization.GrantedRequest(ServicePrincipal),
  declaration: relay.Declaration,
) -> authorization.Visibility {
  let RequestContext(context_tenant, archive_visible, _) = context
  let principal = authorization.grant_principal(grant)
  let has_archive_scope =
    has_scope(authorization.grant_scopes(grant), archive_scope)
  case
    principal_id(principal) == "billing-worker"
    && principal_tenant(principal) == context_tenant
  {
    False -> authorization.Hidden
    True ->
      case declaration {
        relay.Declaration("lookup-invoice", _) -> authorization.Visible
        relay.Declaration("archive-invoice", _) ->
          case archive_visible && has_archive_scope {
            True -> authorization.Visible
            False -> authorization.Hidden
          }
        relay.Declaration(_, _) -> authorization.Hidden
      }
  }
}

fn executable(
  archive_scope: authorization.Scope,
  context: RequestContext,
  grant: authorization.GrantedRequest(ServicePrincipal),
  declaration: relay.Declaration,
) -> authorization.ExecutionAuthorization {
  let RequestContext(context_tenant, _, archive_allowed) = context
  let principal = authorization.grant_principal(grant)
  let has_archive_scope =
    has_scope(authorization.grant_scopes(grant), archive_scope)
  case
    principal_id(principal) == "billing-worker"
    && principal_tenant(principal) == context_tenant
  {
    False -> authorization.ExecutionUnauthorized
    True ->
      case declaration {
        relay.Declaration("lookup-invoice", _) ->
          authorization.ExecutionAuthorized
        relay.Declaration("archive-invoice", _) ->
          case archive_allowed && has_archive_scope {
            True -> authorization.ExecutionAuthorized
            False -> authorization.ExecutionUnauthorized
          }
        relay.Declaration(_, _) -> authorization.ExecutionUnauthorized
      }
  }
}

fn has_scope(
  scopes: List(authorization.Scope),
  expected: authorization.Scope,
) -> Bool {
  case scopes {
    [] -> False
    [scope, ..rest] -> scope == expected || has_scope(rest, expected)
  }
}

fn panic_policy() -> authorization.ToolPolicy(RequestContext, ServicePrincipal) {
  authorization.tool_policy(
    fn(
      _context: RequestContext,
      _grant: authorization.GrantedRequest(ServicePrincipal),
      _declaration: relay.Declaration,
    ) {
      panic as "policy must not run before grant recheck"
    },
    fn(
      _context: RequestContext,
      _grant: authorization.GrantedRequest(ServicePrincipal),
      _declaration: relay.Declaration,
    ) {
      panic as "policy must not run before grant recheck"
    },
  )
}
