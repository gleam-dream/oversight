# Tool schema admission

## Question

- Can standalone LLM callers and a Fabric adapter retain each tool's exact schema through an explicit policy check before rendering wire declarations?

## Result

- `llm_catalog.Entry` holds the tool name, description, and typed Blueprint schema.
- `entry_from_codec` derives an entry from the codec or reports `UnknownSchema`. Fabric's adapter uses its registry declarations.
- `catalog` rejects duplicate names and retains the structured entries.
- `admit` passes each complete entry to a policy. Rejection retains the tool name and the policy's native reason type.
- An admitted catalog retains the exact accepted entries. `render` converts those entries into existing low-level LLM declarations without rewriting their schemas.
- `blueprint_requirements` supplies a structural inventory with typed property, array, tuple, nullable, and tagged-branch locations. Policies may use it for diagnostics while inspecting the full AST for positional or combined constraints.

## Evidence

- `schema_admission` derives equivalent standalone and Fabric entries, rejects duplicate names and unavailable schemas, and exercises two contrasting scripted policies.
- One policy rejects a nested optional property; another rejects tagged alternatives. A separate full-AST policy requires an object root.
- Rendering after acceptance matches the existing adapter's declarations, while the same registry still performs typed decoding and invocation.
- `unadmitted_catalog` fails compilation when a raw catalog is passed to the admitted rendering API.

## Limits

- Public entries are constructible metadata. Catalog opacity does not prove universal codec provenance; the codec-derived and registry-derived paths provide the demonstrated consistency.
- Admission means that the supplied policy accepted these exact entries. It does not authenticate a provider, bind a model instance, or guarantee remote acceptance.
- A live provider must apply its own configured policy during preparation and handle remote rejection even after local admission.
- Requirements describe the laboratory schema constructs, not every JSON Schema keyword or provider restriction. They are not a substitute for complete policy inspection.
- The existing raw `llm_turn.ToolDeclaration` path remains available for explicit low-level use. It does not become validated by this wave.
- The scripted policies do not claim support for any actual provider. Model-specific profiles, schema dialect lowering, and transport opening remain subsequent experiments.
