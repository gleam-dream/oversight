#let terms = (
  (slug: "term-composition-application", title: [Composition application], body: [An independently compiled application that exercises several libraries through their public contracts.]),
  (slug: "term-consumer-recipe", title: [Consumer recipe], body: [Application-owned code that translates between public package contracts without importing package internals.]),
  (slug: "term-package-authority", title: [Package authority], body: [The library that owns a contract's meaning, admitted state transitions, and failure guarantees.]),
  (slug: "term-effect-evidence", title: [Effect evidence], body: [Knowledge about whether an application effect was prevented, completed, compensated, or remains unresolved. Delivery acknowledgement alone does not establish business completion.]),
  (slug: "term-admission-identity", title: [Admission identity], body: [A caller-supplied or retained identity that lets an authority recognize repeated requests for the same admission. It does not prove that an external effect is unique.]),
  (slug: "term-capability-scope", title: [Capability scope], body: [The set of responsibilities a package is intended to support, including explicitly unresolved or unbuilt capabilities.]),
  (slug: "term-behavioral-oracle", title: [Behavioral oracle], body: [A pinned external implementation or specification used to judge a stated subset of observable behavior. Its authority does not extend beyond that subset.]),
  (slug: "term-observation-correlation", title: [Observation correlation], body: [An application-selected value carried across observations so events can be associated with one operation. It neither authorizes work nor identifies a durable effect.]),
  (slug: "term-composition-boundary", title: [Composition boundary], body: [An application-owned translation between independently meaningful package contracts.]),
  (slug: "term-rendered-layer", title: [Rendered layer], body: [The single generated document assembled from a repository's design sources and canonical vocabulary.]),
  (slug: "term-public-consumer", title: [Public consumer], body: [A separate package that imports only the public modules of the library being assessed.]),
  (slug: "term-retained-experiment", title: [Retained experiment], body: [A disposable-system prototype kept as executable evidence for a named design question, rather than as a production implementation.]),
)
