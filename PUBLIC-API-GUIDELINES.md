# Public API guidelines

## Scope

- Apply these rules when proposing or changing a library's public API. Package designs retain their declared behavior, protocol oracles, and capability backlog; these rules govern how callers reach those capabilities.
- These rules do not declare package signatures or add a shared ecosystem abstraction. The examples below and earlier laboratory signatures are illustrative until an implementation and external consumer establish them.

## Caller contract

- **Ask for decisions; derive owned facts.** A required argument must change observable behavior. A definition that already owns a name and codecs supplies them to registration and calls. A generic application failure needs no error codec when the boundary discards its detail; an explicit renderer is justified when the caller chooses to expose safe detail. Persistence may separately require an error codec to replay a recorded failure.
- An illustrative common path retains one definition across binding and calling:

  ```gleam
  let definition = define("lookup", input_codec, output_codec)
  let handler = bind(definition, lookup)
  let result = call(client, definition, input)
  ```

- **Keep configuration pure and composable.** Provide useful defaults and value-first settings operations. Validate the complete settings value before opening a connection, starting a process, or allocating other resources. Use public records for straightforward settings, even when complete validation occurs at startup; use an opaque admitted value when unrestricted construction would violate a required invariant. Record updates need no duplicate builder for every field.
- An illustrative settings path composes values before connection:

  ```gleam
  let settings = client.config(endpoint) |> client.with_timeout(5000)
  let assert Ok(connection) = client.connect(settings)
  ```

- **Represent distinct meanings with types.** Use named alternatives for mutually exclusive policies and separate fields for independent properties. Preserve `None` versus `Some(False)` when omission differs from false. Preserve missing fields, explicit nulls, empty collections, and unknown measurements when their behavior differs.

## Ownership and composition

- **Keep application values generic and implementation state local.** Accept caller records and error types unless a nominal type enforces a useful contract. Bind each typed operation to its value before placing heterogeneous operations behind a small opaque invocation. Do not spread `Dynamic` or private state type parameters through ordinary callers; dynamic protocol and native foreign boundaries may still require decoding. Captured resources need explicit lifetime and memory rules.
- **Group modules by owned decisions.** Configuration owns defaults, settings, and validation without network activity. A provider adapter owns encoding and interpretation, not application retry policy. Execution owns deadlines, cancellation, and resource lifecycle, not provider payloads. A protocol model owns wire meaning, not business records; an application adapter translates package vocabularies without importing either package's internals. Keep coupled code together, and split when responsibility changes independently or hiding machinery simplifies the interface.
- **Provide one ordinary path and distinct advanced capabilities.** An advanced operation must express behavior the ordinary operation cannot, such as rendering a public application error. Avoid overlapping constructor families for the same operation. Remove superseded forms from unreleased APIs when they add no capability; account for migration costs in published APIs.
- **Preserve shared guarantees at extension points.** An extension supplies variable behavior while common admission, limits, correlation, cancellation, and cleanup remain with the library. Test an extension from a separate consumer package using public imports. State which guarantees its author owns, including the memory and lifetime of captured state.
- **Keep package composition explicit and small.** Applications translate between package vocabularies. Share an abstraction only when meaning and invariants match, rather than because fields look similar. Blueprint belongs to JSON Schema paths; ordinary JSON and generic application errors do not acquire a Blueprint dependency solely for composition.

## Failure, lifecycle, and acceptance

- **Make operational behavior part of the contract.** Return structured failures when callers must distinguish deadline, closure, size, protocol, or retry outcomes. Retain useful underlying detail without requiring diagnostic-string parsing. Specify resource ownership, cleanup, cancellation, and where limits apply. A pull-shaped interface alone does not prove backpressure; rejecting an already allocated value does not prove an allocation bound.
- **Accept an API through an external application.** The consumer must complete the common task, configure a distinct advanced case, supply its own application values and errors, and handle failures using public imports only. Verify behavior and resource limits at the relevant boundary; a compiling signature proves neither lifecycle nor operational safety.
