#import "../.render/designlib.typ": *

#let title = [Evidence and validation]
#let accent = "amber"

#let body = [
  #section(title: "Foundation", lead: "Evidence states what an executed check establishes. Retained experiments answer named questions, and repository checks run from recorded inputs.", body: [
    #goal(title: "Reproduce acceptance from recorded inputs")[Every check runs from recorded sources, a pinned toolchain and disposable services. It records the inputs it executed, so a later reader can repeat it.]
    #goal(title: "Keep experiments tied to named questions")[A #term("term-retained-experiment") states the question it answers, the cases it executes and the limits of its result.]
    #no-goal(title: "Historical reports as present contracts")[Assessment chronology and decision rationale belong to ADRs. Test transcripts, release plans and obsolete signatures do not define the current design.]
    #invariant(title: "Evidence claims name their actual boundary", enforcement: "convention")[Compilation, scripted exchanges, native runtime tests, database tests and upstream conformance establish different claims. An unexecuted scenario is not reported as passing.]
    #principle(title: "Use executable consumers to judge interfaces", lens: "composition")[An ordinary task, an advanced case, native values and recovery must be expressible from a #term("term-public-consumer"). Internal elegance does not replace that evidence.]
    The evidence-scoping decision is recorded in #adr(9) and the source-resolution decision in #adr(15).
  ])

  #pending-ledger(
    pending-entry(title: "Application callbacks lack a remaining-deadline port", kind: "ruling", since: "2026-10-08")[The admission experiment introduces no public remaining-deadline or cancellation argument for application callbacks. Such a port needs its own concrete consumer before a signature is chosen. See #adr(22).],
    pending-entry(title: "A pending evidence marker cannot show an in-flight effect", kind: "ruling", since: "2026-10-07")[A worker that stops after committing its pending marker and before sending leaves a condition that provider evidence alone can distinguish from an in-flight effect. The protocol reports uncertainty rather than inferring non-execution. See #adr(20).],
  )

  #section(title: "Validation profiles", lead: "The runner executes checks as named profiles through the repository's Nix shell. Continuous integration divides the same commands into jobs.", body: [
    #code-block("sh", "nix develop --command python3 -B scripts/ci.py quality
nix develop --command python3 -B scripts/ci.py application <name>
nix develop --command python3 -B scripts/ci.py experiments
nix develop --command python3 -B scripts/ci.py full")
    #md-table(4, (
      [*Obligation*], [*Check*], [*Profile*], [*Evidence and limit*],
      [Reproducible authored files], [Flake check, actionlint, ShellCheck, Ruff], [Quality], [Command logs; formatting and selected static rules],
      [Warning-free executable consumers], [Gleam warnings-as-errors and separate Erlang `-Werror` compilation], [Each application], [Compiler diagnostics; no claim about dependency warnings],
      [Local protocol, recovery and storage behavior], [Each application's test suite, through the disposable database wrapper where required], [Each application], [Test and database logs; named scenarios only],
      [Bounded compiler and oracle evidence], [Retained experiment runners and protocol-pilot tests], [Experiments], [Positive controls, intended negative diagnostics and scoped oracle comparisons],
      [Render freshness and vocabulary integrity], [The design gate check], [Full and CI], [Mechanical design checks; semantic fidelity requires review],
      [Failure reporting by the runner], [The runner's own test suite], [Quality], [Rejected job states, bad pins, native warning and failed-command controls],
    ))
    #points(
      [The full profile runs the quality checks, every registered application, the retained experiments and the design gate. The final continuous-integration status requires every mandatory job to succeed; failures, cancellations and unexpected skips cannot satisfy it.],
      [The runner's application inventory is the authority for discovery. Adding an application requires registering it and declaring whether it needs PostgreSQL; the continuous-integration matrix derives from that inventory.],
      [Handwritten Erlang in application source and tests compiles strictly after the Gleam dependency build.],
      [The experiments profile runs every retained experiment except the Fabric reader check, which needs the older Fabric commit and the sibling commits recorded in that commit's own revision file. Continuous integration holds no sibling checkouts, so that check runs manually from a checkout with Git history. The applications and experiments are the usage examples, so a public API change that breaks one fails its profile.],
      [The interface laboratory and the HTTP declaration probe contain unfinished runtime declarations by design. Their own compiler checkers are their acceptance boundary, and linting does not rewrite pinned upstream inputs or captured evidence.],
      [Applications have no stable library-performance benchmark. Test durations are operational diagnostics, not throughput or latency claims; package benchmarks belong to the package that owns the workload.],
    )
    #adr(19)
  ])

  #section(title: "Source qualification", lead: "A consumer's runtime code comes from its locked Git sources. The executed inputs are recorded separately from the repository's own revision.", body: [
    #points(
      [Composition consumers declare Git sources with matching lockfiles. The #term("term-locked-source") is the commit a lockfile resolves for such a source, and historical readers keep their explicit revision selection. Editing a sibling working tree does not change consumer runtime code.],
      [The runner records command logs, exit codes, durations, the repository's revision and dirty flag, the locked Git commits, the executed package declarations and lockfiles, and the toolchain identity as #term("term-source-provenance"). Database logs survive cluster cleanup when the gate supplies a log directory. Missing services and failed tests remain failures.],
      [All tracked library repositories are public, so dependency resolution needs no credential, and continuous integration persists none and passes none to test commands. Fresh dependency resolution verifies that the locked sources are available.],
      [Updating a library is a deliberate act: moving a lockfile reruns the affected consumers, and no scheduled job moves one. Inconsistent source requirements between libraries fail dependency resolution.],
      [A #term("term-local-source-capture") copies tracked and new authored sources into a fresh directory, refuses an existing directory, excludes credentials, local settings, caches and symlinks, and normalizes sibling dependencies throughout the copied graph. External sources and exact Hex oracle versions stay unchanged, and historical readers keep their explicit revision selection. The capture records revisions, dirty flags, original file hashes and overridden manifests. Its results do not qualify the locked sources.],
      [The Nix lock supplies the Gleam, Erlang/OTP, Elixir and PostgreSQL versions; only its lock input changes during a toolchain refresh. Rebar3 and Elixir use the shell's OTP package. After the first dependency build, repeated builds of an unchanged local-source consumer reuse its dependency resolution.],
      [Qualifying a coordinated library change updates consumer declarations and lockfiles together, then reruns the affected consumers. Oversight publishes no library artifact; release qualification combines these results with each library's own validation, and no workflow publishes packages or changes repository settings.],
    )
    #behavior(title: "Qualification records the inputs actually executed", area: "Source qualification", level: "boundary")[
      #given[A consumer builds from its recorded declarations while a sibling working tree holds uncommitted edits.]
      #when[The runner records the run.]
      #then[The receipt holds the consumer's executed declarations and lockfile separately from the repository's revision and dirty flag.]
      #then[The uncommitted edits do not change the consumer's runtime code or the locked sources.]
    ]
    #adr(15)
  ])

  #section(title: "Experiments and acceptance evidence", lead: "Retained experiments answer narrow questions and stay separate from production libraries. Evidence is reproducible only when its inputs, oracle and execution boundary are explicit.", body: [
    #answers(title: "Retained experiment",
      responsibility: [Explore typed public contracts and failure boundaries without presenting a prototype as a production implementation.],
      interface: [A runner, positive and negative cases, scripted peers and selected oracle comparisons inside each experiment directory, with a short README that gives its run command.],
      interactions: [Experiments inform package-owned designs and ADRs. An accepted capability requires an implementation and a separate-consumer check in the owning repository.],
      invariants: [Compiler success proves expressibility, not crash recovery or operational bounds. A pinned protocol snapshot retains its license and provenance. An expectation matrix is fixed before the implementation it judges.],
      failure: [An incomplete experiment leaves its capability unproven; a stub, an expected failure or a skipped check is not counted as a working runtime.],
    )
    #md-table(3, (
      [*Retained system part*], [*Question it answers*], [*Limits of the evidence*],
      [`playground/relay_admission`], [Do admission callbacks share the request deadline, and what changes when their process owner changes?], [Barrier-driven public consumers check callback deadlines, disconnects, retiring capacity, shared budgets, shutdown, panic isolation and borrowed resources. Native process probes do not establish arbitrary resource cleanup or streaming lifecycle conformance.],
      [`playground/interface_lab`], [Can proposed native types, ownership states and protocol boundaries be expressed and distinguished?], [Prototype behavior does not establish production lifecycle conformance.],
      [`playground/blueprint_compatibility`], [How do codec and schema cases compare with the pinned implementation and validator?], [Only executed supported-vocabulary cases establish equivalence.],
      [`playground/ecosystem_pilot`], [Can protocol declarations, model calls and typed observations compose through public imports?], [A pilot does not replace each package's fault and resource tests.],
      [`playground/http_gun_interface`], [Can transport ownership and provider-neutral use fit separate consumers?], [Laboratory signatures are not public API promises.],
      [`playground/archive_release`], [Can authenticated admission and durable approval bind a release to its requester, revision and current permission?], [Direct authorization admission and orderly store reopen do not establish full MCP transport or mid-effect crash recovery.],
      [`playground/instrument_replay`], [Can bounded recorded transport support offline evaluation under different application contracts?], [Synthetic measurements and local faults do not qualify a scientific instrument or remote service.],
      [`playground/erasure_campaign`], [Can reversible preparation compose with irreversible delivery and forward reconciliation?], [Application evidence, synthetic targets and local restarts do not establish legal erasure or host-loss guarantees.],
      [`playground/fabric_record_compatibility`], [Does a separately pinned earlier Fabric reader refuse the history record envelope?], [Two public consumers preserve exact writer inputs and reader revision; refusal by one older reader does not establish every older release or backend fault case.],
      [`apps/scripts/with-postgres.sh`], [Can a consumer exercise real persistence in an isolated reproducible cluster?], [No production database, remote provider or existing deployment is validated.],
    ))
    #subsection(title: "Interface laboratory")[
      #points(
        [The laboratory tests candidate typed APIs in one experimental package. Its modules are sketches and not production packages. Isolated source imports test module dependency direction; independently distributable packages need consumer builds against actual package boundaries.],
        [A definition contains code and typed codecs. A snapshot contains only data that identifies the definition and records execution progress, never a closure, actor, socket or live lease. Restore receives a fresh definition and validates persisted data against it.],
        [A checkpoint capability distinguishes an execution that may be frozen from one still running. It does not prove exclusive ownership, because values can be copied; runner exclusion, commit ordering, stale revisions and signal deduplication need runtime checks.],
        [Approval is a suspension point and not a blocked worker. An uncertain external effect stays uncertain after freeze and thaw, because restoring a snapshot cannot establish whether a remote effect happened.],
        [Compiler checks reject incompatible types, distinguish execution capabilities and native child result types, and keep a pending identity out of a verified-identity interface. They cannot prove codec laws, graph validity, persistence safety, authorization, idempotency or scheduling.],
        [The experiment excludes full graph authoring, executable freeze and thaw, provider-specific continuation, streaming cancellation, full schema support, protocol conformance, upstream oracle suites and benchmarks.],
      )
    ]
    #subsection(title: "Admission deadline and capacity")[
      #behavior(title: "One deadline covers admission and execution", area: "Relay admission", level: "boundary")[
        #given[An endpoint admits a request through a context callback and a token verifier.]
        #when[Admission consumes part of the request deadline.]
        #then[The handler receives only the remaining budget and never a fresh one.]
        #then[A positive decision that arrives after expiry cannot start the handler.]
      ]
      #behavior(title: "Retiring work retains capacity until it ends", area: "Relay admission", level: "boundary")[
        #given[A blocked admission callback outlives its request deadline.]
        #when[The endpoint answers the caller with a timeout and begins cleanup.]
        #then[The callback's capacity slot remains occupied until the callback terminates, and other callers are refused for capacity meanwhile.]
        #then[A late callback result never invokes the tool, and capacity recovers after termination.]
      ]
      #points(
        [A callback-created mailbox belongs to the worker that created it. A borrowed long-lived client, pool or actor is created outside the callback and stays application-owned.],
        [A timeout or process termination does not prove that an external effect did not occur. Detached children and children that trap exits do not become Relay-owned resources.],
        [Client header acquisition shares one request budget with transport; an acquisition that is blocked past its budget reports a timeout that was not sent, and cancellation, owner close and caller death stop the callback.],
      )
      #adr(22)
    ]
    #subsection(title: "Authorization and approval")[
      #behavior(title: "Approval binds the original requester and revision", area: "Archive release", level: "boundary")[
        #given[A release awaits approval and a different authenticated principal later holds permission on the same document.]
        #when[The release executes with fresh application context.]
        #then[The release is refused because the requester changed, and nothing is written.]
        #then[A document revision that changed during approval is refused for the same reason.]
      ]
      #points(
        [A completed agent conversation can contain a denied action. Business success is read from the action outcome and the application's release record, never from conversation completion.],
        [Permission is read from fresh application state at execution. A valid token and a valid approval proof do not carry stale permission forward.],
      )
      #adr(21)
    ]
    #subsection(title: "Irreversible effects and replay")[
      #behavior(title: "Evidence is recorded before an irreversible send", area: "Erasure campaign", level: "boundary")[
        #given[A campaign must delete several targets irreversibly after reversible preparation.]
        #when[A delivery reaches a target whose evidence is pending, confirmed or rejected.]
        #then[Only the delivery that recorded pending evidence first may send the deletion.]
        #then[Confirmed evidence returns its receipt and rejected evidence declines, both without another deletion; pending evidence reports uncertainty.]
      ]
      #behavior(title: "Transport failure stays distinct from contract failure", area: "Instrument replay", level: "boundary")[
        #given[A recorded acquisition is replayed offline with two schema policies.]
        #when[A response is truncated, oversized, or complete with a value of the wrong type.]
        #then[Truncation and excess size remain transport failures with their status evidence, and the wrong type is a located contract failure.]
        #then[Independent replay runs keep their own cursor and correlation over one unchanged capture.]
      ]
      #points(
        [Saga serves reversible preparation, and final irreversible effects use forward reconciliation with application evidence rather than invented compensation.],
        [A lookup result must equal the exact expected receipt. An absence, a malformed receipt or a failed lookup never authorizes replay.],
        [Cancellation stops future work and cannot restore data already deleted.],
      )
      #adr(20) #adr(23)
    ]
    #behavior(title: "A consumer proves only executed behavior", area: "Evidence acceptance", level: "boundary")[
      #given[A consumer compiles but its persistence or external-effect scenario is skipped.]
      #when[Its result is used to assess a package contract.]
      #then[The evidence is limited to compilation and the scenarios actually executed.]
      #then[The unexecuted operational guarantee remains unverified.]
    ]
    #points(
      [A #term("term-behavioral-oracle") names its version, license, relevant behavior and comparison limits. Native telemetry, JSON Schema, Gun/Cowlib, Reactor, Oban and protocol authorities are scoped evidence rather than automatic parity claims. #lnk("../../ORACLE.md")[The oracle reference] holds each pin, what is compared, how outcomes are classified, how to run the comparison and where the claim ends.],
      [Open-source Oban behavior and commercial Pro behavior require separate contracts and lawful evidence. Certification of an upstream identity library does not certify its wrapper.],
      [Deterministic barriers expose races and ownership; sleeps alone do not establish event ordering. Real database tests complement pure transition tests.],
      [The authored behavior areas are public facade, extension admission, effect translation, durable identity, budget and lifetime, authorization, observation and evidence acceptance. Each application adds its domain-specific cases in its executable tests.],
    )
    #adr(9) #adr(25) #adr(27)
  ])

  #section(title: "Design maintenance and rendering", lead: "Repository-local design sources are the present contract. The pinned renderer checks structure and references while semantic review checks the contract against the system.", body: [
    #answers(title: "Documentation authority",
      responsibility: [Keep package-local design, canonical terminology and decision rationale discoverable without duplicate planning authorities.],
      interface: [Typst design and glossary files, Markdown ADRs and coverage map, one generated layer document, and forwarded Nix render, check and context apps.],
      interactions: [The README and agent instructions point to the local layer. Oversight links package owners and records ecosystem-wide decisions; operational guides link the relevant design rather than restating it.],
      invariants: [The design is timeless. ADR rationale is evidence-backed; missing historical context is explicit. The #term("term-rendered-layer") is generated and never edited directly.],
      failure: [A stale rendering or broken semantic reference fails the design gate. A green gate does not prove implementation conformance or correct design.],
    )
    #points(
      [Coverage classifies actual repository parts as captured, standard, or out-of-scope. A deleted component does not survive as an invented coverage row.],
      [Source and behavior changes require reviewing affected contracts, examples, callers and stored data. API similarity alone is not a reason to impose an ecosystem-wide migration.],
      [Current gaps remain in the owning pending ledger. ADRs explain decisions and alternatives; they do not replace the standing design.],
      [Package and nested-adapter gates use the same pinned schema and renderer bundle. Nested adapter layers are checked through the parent's declared nested-project path.],
      [Examples and fixtures keep a short README that gives what the directory is and how to run it, and the compiled applications and experiments are the usage documentation. Oracle pins and comparison limits live together in the oracle reference; narrative, results and research chronology live in ADRs or the design.],
    )
    #adr(1) #adr(26) #adr(27)
  ])
]
