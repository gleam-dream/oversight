#let terms = (
  (slug: "term-composition-application", title: [Composition application], body: [An independently compiled application that exercises several libraries through their public contracts.]),
  (slug: "term-scripted-peer", title: [Scripted peer], body: [A deterministic loopback service that stands in for an external provider and exposes planned failure paths without credentials.]),
  (slug: "term-business-identity", title: [Business identity], body: [The application-chosen identity of one business operation. It is independent of job, workflow and queue identities and outlives their retention.]),
  (slug: "term-reconciliation-decision", title: [Reconciliation decision], body: [An attributed application record that settles a finished unresolved operation from authoritative evidence, identified by one stable decision identity.]),
  (slug: "term-applied-marker", title: [Applied marker], body: [An application-owned durable record that an outcome has been incorporated. It prevents a later delivery from starting the same work again after execution records are pruned.]),
  (slug: "term-session-publication", title: [Session publication], body: [The application step that turns confirmed verification evidence into an application session, identified by a publication identity rather than a browser credential.]),
  (slug: "term-model-exchange", title: [Model exchange], body: [One provider request and its answer, stored together as evidence before the answer is used and keyed by a digest of the request bytes. A replay answers only a request with the same bytes and needs no transport.]),
  (slug: "term-recorded-outcome", title: [Recorded outcome], body: [What an occurrence's record states happened to a gated act, such as a payout paid with its amount. The application tells a customer only what the recorded outcome states. _Avoid_: truth — the record is the authority, not a judgment of fact.]),
  (slug: "term-promotion-gate", title: [Promotion gate], body: [An application rule that publishes a candidate policy version only when a tally or replay over the record clears a stated threshold.]),
)
