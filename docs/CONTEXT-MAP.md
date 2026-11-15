# Context map

## Contexts

- [Composition](./design/composition/CONTEXT.typ) — the contracts that decide who owns each resource, decision and fact when independent libraries meet in one application.
- [Applications](./design/applications/CONTEXT.typ) — the composition applications and each application's task, ownership and recovery behavior.
- [Evidence](./design/evidence/CONTEXT.typ) — retained experiments, validation profiles, source qualification and design maintenance.

## Relationships

- Composition → Applications: customer/supplier. Composition supplies the contracts and vocabulary; each application is a customer that demonstrates them and escalates a missing contract to composition.
- Composition → Evidence: customer/supplier. Evidence supplies the checks that judge a composition contract and the limits of what a passing check establishes.
- Applications → Evidence: conformist. Applications run under the validation profiles and the provenance rules that evidence defines and do not alter them.

## Ownership of shared terms

- Composition owns package authority, composition boundary, consumer recipe, effect evidence, unresolved effect, admission identity, capability scope, observation correlation, borrowed resource and gated agent call.
- Applications owns composition application, scripted peer, business identity, reconciliation decision, applied marker, session publication, model exchange, recorded outcome and promotion gate.
- Evidence owns public consumer, retained experiment, behavioral oracle, locked source, source provenance, validation profile, local-source capture and rendered layer.
- A context cites another context's term by slug and never redefines it.
- The `decisions` repository owns the decision-point vocabulary (decision point, occurrence, desk, card, verdict, policy, release, gated tool, release key, follower, hint). Oversight uses those words with the meanings that repository defines and does not redefine them.
