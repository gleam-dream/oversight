// THROWAWAY: Can Relay admit one verified bearer grant and reauthorize tools?
import lab/relay
import lab/value

type Maybe(value) {
  NoValue
  Value(value)
}

pub opaque type BearerToken {
  BearerToken(String)
}

pub opaque type Resource {
  Resource(String)
}

pub opaque type Scope {
  Scope(String)
}

pub type BoundaryValueError {
  EmptyBearerToken
  EmptyResource
  EmptyScope
}

pub fn bearer_token(raw: String) -> Result(BearerToken, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyBearerToken)
    _ -> Ok(BearerToken(raw))
  }
}

// The configured verifier receives this value to inspect the caller-supplied token.
pub fn bearer_token_value(token: BearerToken) -> String {
  let BearerToken(raw) = token
  raw
}

pub fn resource(raw: String) -> Result(Resource, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyResource)
    _ -> Ok(Resource(raw))
  }
}

pub fn scope(raw: String) -> Result(Scope, BoundaryValueError) {
  case raw {
    "" -> Error(EmptyScope)
    _ -> Ok(Scope(raw))
  }
}

pub opaque type ProtectionConfig {
  ProtectionConfig(resource: Resource, required_scopes: List(Scope))
}

pub fn protection_config(
  resource: Resource,
  required_scopes: List(Scope),
) -> ProtectionConfig {
  ProtectionConfig(resource, required_scopes)
}

pub type VerifierPurpose {
  TrustedVerifier
  TestOnlyVerifier
}

pub type VerifierDeclaration {
  VerifierDeclaration(name: String, version: String, purpose: VerifierPurpose)
}

// This public value is a trusted adapter assertion, not proof of verification.
pub type VerifierAttestation(principal) {
  VerifierAttestation(
    principal: principal,
    audiences: List(Resource),
    scopes: List(Scope),
  )
}

pub type VerificationError {
  BearerRejected
  VerifierUnavailable
  VerifierUnmapped
}

pub type AdmissionError {
  VerificationFailed(VerificationError)
  ResourceNotGranted
  MissingEndpointScope(Scope)
}

pub type GrantUseError {
  GrantResourceMismatch
  GrantMissingEndpointScope(Scope)
}

pub opaque type Verifier(principal) {
  Verifier(
    declaration: VerifierDeclaration,
    verify: fn(BearerToken) ->
      Result(VerifierAttestation(principal), VerificationError),
  )
}

pub opaque type GrantedRequest(principal) {
  GrantedRequest(principal: principal, resource: Resource, scopes: List(Scope))
}

pub fn trust_verifier(
  declaration: VerifierDeclaration,
  verify: fn(BearerToken) ->
    Result(VerifierAttestation(principal), VerificationError),
) -> Verifier(principal) {
  Verifier(declaration, verify)
}

pub fn verifier_declaration(
  verifier: Verifier(principal),
) -> VerifierDeclaration {
  let Verifier(declaration, _) = verifier
  declaration
}

pub fn admit(
  verifier: Verifier(principal),
  token: BearerToken,
  protection: ProtectionConfig,
) -> Result(GrantedRequest(principal), AdmissionError) {
  let Verifier(_, verify) = verifier
  case verify(token) {
    Error(error) -> Error(VerificationFailed(error))
    Ok(VerifierAttestation(principal, audiences, scopes)) -> {
      let ProtectionConfig(resource, required_scopes) = protection
      case audiences {
        [audience] if audience == resource ->
          case first_missing_scope(required_scopes, scopes) {
            Value(missing) -> Error(MissingEndpointScope(missing))
            NoValue -> Ok(GrantedRequest(principal, resource, scopes))
          }
        _ -> Error(ResourceNotGranted)
      }
    }
  }
}

pub fn grant_principal(grant: GrantedRequest(principal)) -> principal {
  let GrantedRequest(principal, _, _) = grant
  principal
}

pub fn grant_resource(grant: GrantedRequest(principal)) -> Resource {
  let GrantedRequest(_, resource, _) = grant
  resource
}

pub fn grant_scopes(grant: GrantedRequest(principal)) -> List(Scope) {
  let GrantedRequest(_, _, scopes) = grant
  scopes
}

fn first_missing_scope(
  required: List(Scope),
  granted: List(Scope),
) -> Maybe(Scope) {
  case required {
    [] -> NoValue
    [scope, ..rest] ->
      case contains_scope(granted, scope) {
        True -> first_missing_scope(rest, granted)
        False -> Value(scope)
      }
  }
}

fn contains_scope(scopes: List(Scope), expected: Scope) -> Bool {
  case scopes {
    [] -> False
    [scope, ..rest] -> scope == expected || contains_scope(rest, expected)
  }
}

pub type Visibility {
  Visible
  Hidden
}

pub type ExecutionAuthorization {
  ExecutionAuthorized
  ExecutionUnauthorized
}

pub type InaccessibleCause {
  UnknownTool
  HiddenTool
  ExecutionDenied
}

pub type ProtectedDispatchError {
  GrantUseFailed(GrantUseError)
  InaccessibleTool(InaccessibleCause)
  InvocationFailed(relay.InvocationError)
}

// This fixed classification intentionally carries no tool name or cause.
pub type ExternalClassification {
  ToolUnavailable
}

pub fn external_classification(
  _cause: InaccessibleCause,
) -> ExternalClassification {
  ToolUnavailable
}

pub opaque type ToolPolicy(context, principal) {
  ToolPolicy(
    visibility: fn(context, GrantedRequest(principal), relay.Declaration) ->
      Visibility,
    execution: fn(context, GrantedRequest(principal), relay.Declaration) ->
      ExecutionAuthorization,
  )
}

pub opaque type ProtectedRegistry(context, principal) {
  ProtectedRegistry(
    protection: ProtectionConfig,
    registry: relay.Registry(context),
    policy: ToolPolicy(context, principal),
  )
}

pub fn tool_policy(
  visibility: fn(context, GrantedRequest(principal), relay.Declaration) ->
    Visibility,
  execution: fn(context, GrantedRequest(principal), relay.Declaration) ->
    ExecutionAuthorization,
) -> ToolPolicy(context, principal) {
  ToolPolicy(visibility, execution)
}

pub fn protect_registry(
  protection: ProtectionConfig,
  registry: relay.Registry(context),
  policy: ToolPolicy(context, principal),
) -> ProtectedRegistry(context, principal) {
  ProtectedRegistry(protection, registry, policy)
}

pub fn visible_declarations(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
) -> Result(List(relay.Declaration), GrantUseError) {
  let ProtectedRegistry(protection, raw_registry, ToolPolicy(visibility, _)) =
    registry
  case check_grant(protection, grant) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      Ok(
        visible_from(
          relay.declarations(raw_registry),
          context,
          grant,
          visibility,
          [],
        ),
      )
  }
}

fn visible_from(
  declarations: List(relay.Declaration),
  context: context,
  grant: GrantedRequest(principal),
  visibility: fn(context, GrantedRequest(principal), relay.Declaration) ->
    Visibility,
  visible: List(relay.Declaration),
) -> List(relay.Declaration) {
  case declarations {
    [] -> reverse(visible, [])
    [declaration, ..rest] ->
      case visibility(context, grant, declaration) {
        Visible ->
          visible_from(rest, context, grant, visibility, [
            declaration,
            ..visible
          ])
        Hidden -> visible_from(rest, context, grant, visibility, visible)
      }
  }
}

pub fn dispatch_granted(
  registry: ProtectedRegistry(context, principal),
  context: context,
  grant: GrantedRequest(principal),
  name: String,
  input: value.Value,
) -> Result(value.Value, ProtectedDispatchError) {
  let ProtectedRegistry(
    protection,
    raw_registry,
    ToolPolicy(visibility, execution),
  ) = registry
  case check_grant(protection, grant) {
    Error(error) -> Error(GrantUseFailed(error))
    Ok(Nil) ->
      case find_declaration(relay.declarations(raw_registry), name) {
        NoValue -> Error(InaccessibleTool(UnknownTool))
        Value(declaration) ->
          case visibility(context, grant, declaration) {
            Hidden -> Error(InaccessibleTool(HiddenTool))
            Visible ->
              case execution(context, grant, declaration) {
                ExecutionUnauthorized ->
                  Error(InaccessibleTool(ExecutionDenied))
                ExecutionAuthorized ->
                  case relay.dispatch(raw_registry, context, name, input) {
                    Ok(output) -> Ok(output)
                    Error(relay.UnknownTool(_)) ->
                      Error(InaccessibleTool(UnknownTool))
                    Error(relay.InvocationFailed(error)) ->
                      Error(InvocationFailed(error))
                  }
              }
          }
      }
  }
}

fn check_grant(
  protection: ProtectionConfig,
  grant: GrantedRequest(principal),
) -> Result(Nil, GrantUseError) {
  let ProtectionConfig(resource, required_scopes) = protection
  let GrantedRequest(_, granted_resource, granted_scopes) = grant
  case granted_resource == resource {
    False -> Error(GrantResourceMismatch)
    True ->
      case first_missing_scope(required_scopes, granted_scopes) {
        Value(missing) -> Error(GrantMissingEndpointScope(missing))
        NoValue -> Ok(Nil)
      }
  }
}

fn find_declaration(
  declarations: List(relay.Declaration),
  name: String,
) -> Maybe(relay.Declaration) {
  case declarations {
    [] -> NoValue
    [relay.Declaration(declaration_name, _) as declaration, ..rest] ->
      case declaration_name == name {
        True -> Value(declaration)
        False -> find_declaration(rest, name)
      }
  }
}

fn reverse(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse(rest, [item, ..acc])
  }
}
