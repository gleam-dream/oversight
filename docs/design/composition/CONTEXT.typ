#let terms = (
  (slug: "term-package-authority", title: [Package authority], body: [The library that owns a contract's meaning, admitted state transitions, and failure guarantees.]),
  (slug: "term-composition-boundary", title: [Composition boundary], body: [An application-owned translation between independently meaningful package contracts.]),
  (slug: "term-consumer-recipe", title: [Consumer recipe], body: [Application-owned code that translates between public package contracts without importing package internals.]),
  (slug: "term-effect-evidence", title: [Effect evidence], body: [Knowledge about whether an application effect was prevented, completed, compensated, or remains unresolved. Delivery acknowledgement alone does not establish business completion.]),
  (slug: "term-unresolved-effect", title: [Unresolved effect], body: [An application effect that may have occurred and lacks confirmation of either outcome.]),
  (slug: "term-admission-identity", title: [Admission identity], body: [A caller-supplied or retained identity that lets an authority recognize repeated requests for the same admission. It does not prove that an external effect is unique.]),
  (slug: "term-capability-scope", title: [Capability scope], body: [The set of responsibilities a package is intended to support, including explicitly unresolved or unbuilt capabilities.]),
  (slug: "term-observation-correlation", title: [Observation correlation], body: [An application-selected value carried across observations so events can be associated with one operation. It neither authorizes work nor identifies a durable effect.]),
  (slug: "term-borrowed-resource", title: [Borrowed resource], body: [A pool, client, actor or transaction that one party owns and another party uses without controlling its lifetime.]),
)
