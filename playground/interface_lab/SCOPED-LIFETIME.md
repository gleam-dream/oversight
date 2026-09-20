# Scoped observation lifetime

## Question

- Can scoped observation preserve a completed work value and cleanup outcome while keeping registration identity private and re-raising catchable BEAM exceptions faithfully?
- The experiment covers the scoped control boundary with a scripted attachment backend. It does not validate a production `:telemetry` adapter or callback quiescence.

## Public boundary

- `with_attachments` accepts one configured backend, a nonempty event set, one typed handler, handler-failure reporting, exceptional cleanup-failure reporting, and a work callback.
- The result is `Result(ScopedCompletion(a), AttachError)`. `ScopedCompletion` retains the work value and `Result(Nil, ScopeCleanupFailure)` separately, so an ordinary `Result.Error` from application work remains a value.
- Duplicate logical event names fail before allocating a scoped identity or calling the backend or work callback. Backend attachment rejection also skips work.
- Each accepted scope creates a private handler-identity variant. Nested scopes receive distinct runtime-local identities, and the accepted attachment retains its own detach callback. The scope caller receives neither the identity nor the attachment.

## Observed behavior

- Nested scopes each detach once and preserve both inner and outer work results. The probe covers duplicate-name rejection and backend rejection before work.
- Ordinary work values survive a returned detach error and a detach exception. These become `DetachReturnedError` or `DetachRaisedException` inside the cleanup result.
- If the scripted handler removes itself before scope exit, cleanup reports `NotAttached` as `DetachReturnedError`. The registration is already absent, satisfying the removal-ownership goal, while the cleanup outcome remains explicit.
- A catchable work error, exit, or throw triggers one cleanup attempt and is re-raised with the original BEAM class, reason, and stacktrace. Cleanup failures reach the dedicated reporter; an exception raised by that reporter does not replace the original work exception.
- The scripted backend retains a callback selected before detachment. The probe invokes it after the scope returns, showing that detachment does not wait for already selected callback work.

## Evidence boundary

- [`scoped_lifetime.gleam`](src/consumers/scoped_lifetime.gleam) exercises the public boundary with a scripted backend. [`sinal_scope_ffi.erl`](src/sinal_scope_ffi.erl) captures and re-raises BEAM exception triples around the work and cleanup callbacks.
- The prototype does not connect attachment or event delivery to `:telemetry`. Native name and atom/map conversion, callback-failure forwarding, timing, real registry behavior, and synchronous delivery need the pinned telemetry oracle.
- Scope exit does not establish callback quiescence. Applications must keep captured resources valid until independently selected callbacks finish.

## Remaining scope

- Process termination that cannot be caught, uncertain attachment completion, and concurrent attachment or detachment require runtime evidence.
- Private scoped identity protects the Gleam API from caller-supplied identifier reuse; raw Erlang or Elixir code can inspect and deliberately replace native registry entries.
- The prototype does not prove that cleanup is safe against arbitrary foreign registry mutation or that a resource captured by the handler can be destroyed immediately after scope exit.
