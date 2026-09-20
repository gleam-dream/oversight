# Agent action policy and model-turn limits

## Question

- Can an application inspect agent actions, apply its own policy, and pause for approval while Fabric retains the original provider continuation?
- The experiment composes the existing contextual tool registry and tool-turn boundary. Ordinary typed application functions remain independently callable.

## Ownership

- The controller owns one run's model-turn budget, outstanding calls, accepted reports, and approval revisions.
- The host supplies a distinct trusted incarnation for each independently started controller, including another start of the same logical run. Reports and approvals retain this incarnation privately; the pure prototype does not generate or prove its freshness.
- The application supplies a policy and its context. Policy has no implicit allow branch.
- A described action carries its run, model-turn ordinal, provider call identifier, exact arguments, and registered declaration when available.
- Predecode policy does not validate native argument types. Input-dependent authorization may remain inside the typed application handler.
- The host chooses the execution order of outstanding actions. Inspection does not impose serial execution.
- An inspected action does not execute a tool. A prepared invocation retains the exact call and context that policy admitted.
- The originating pending turn retains its provider. Another provider with the same continuation type must not receive its results.

## Outcome distinctions

- Denial and a known unregistered tool may become model-visible failures without invoking a handler.
- An ordinary typed business failure may become a model-visible tool failure.
- Policy failures and codec boundary failures remain host failures. They must not silently resume the model as ordinary business outcomes.
- An uncertain effect means invocation may have happened but its outcome is unknown. It stops continuation until explicit reconciliation; it never authorizes automatic retry.
- Inspection cannot synthesize successful tool results for dry runs or manual review.

## Approval and limits

- An approval reference identifies an action and its requirement version and revision. Provider call identifiers alone are insufficient because providers may reuse them on later turns.
- Approval answers are checked against the latest controller state. Wrong, stale, and already answered references remain distinct.
- Approval rechecks the current application policy. Current denial or policy failure wins; a changed approval requirement needs another review.
- Approved invocation retains the same current context used for that check.
- The model-turn limit counts the initial request and every attempted continuation. Waiting for approval and executing tools do not reset it.
- Exhaustion preserves outstanding state and prevents new effects whose results cannot be continued within the limit.

## Consumer evidence

- One mixed batch performs a lookup, denies deletion before decoding or invocation, waits for purchase approval, and reports an unregistered tool without inventing an uncertain effect.
- The consumer changes approval requirements and application context, then checks stale and repeated answers against the evolved controller.
- A later model turn reuses a provider call identifier. Scoped action identity keeps earlier reports from satisfying that new action.
- Distinct incarnations use identical logical labels to test rejection of foreign reports, approval references, and effect reconciliation.
- Issued denial reports cannot be replaced by success from another policy path. Ordinary business failures, codec failures, policy failures, and uncertain effects follow different outcomes.
- Panic continuations establish that blocked states do not invoke the provider. Malformed replies and transport failures retain consumed attempts; repeated terminal inspection preserves the count.
- Compiler-negative consumers reject another context type, an approval reference used as an invocation, and another native continuation type.

## Remaining obligations

- The pure controller is copyable. A caller can reuse an old controller or prepared invocation; the experiment cannot establish linear execution or atomic policy enforcement.
- Applications own incarnation freshness and the authenticity of approval commands. Durable compare-and-set ownership, approval expiry, cancellation, and concurrent hosts remain separate work.
- The provider and tool callbacks remain trusted boundaries. Foreign exception containment, transport cleanup, process loss, and retry safety need runtime evidence.
- Token and elapsed-time budgets, streamed progress, persisted provider continuations, and Saga child or subagent execution remain unfinished families.
- The earlier `fabric.bounded` function only packages a callback and tools. It does not acquire these controller guarantees automatically.
