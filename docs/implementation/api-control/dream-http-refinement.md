# Deferred Dream HTTP Client adoption

## Status

- Deferred on 23 September 2026 at the user's request. The user owns upstream discussion and the path to merge.
- Relay and LLM Wire retain their current Gun transports. Adoption is a possible refinement, not an approved dependency change.
- No automatic monitoring, upstream outreach, or further implementation is scheduled.

## Candidate implementation

- The local fork is `/code/forks/dream`, with GitHub fork `lostbean/dream` and upstream `TrustBound/dream`.
- The combined branch is `codex/http-client-combined` at `4b6c0ef`. The branch and commit were verified locally when this note was recorded.
- Six focused branches remain available for future PRs: `codex/http-client-cancellation`, `codex/http-client-controls`, `codex/http-client-demand-streams`, `codex/http-client-honest-recordings`, `codex/http-client-profiles`, and `codex/http-client-response-errors`.
- The reported changes cover request-level connection, redirect, and CA controls; demand-driven pull streaming; underlying request cancellation; structured live-stream errors; recordings without invented stream status; and isolated connection profiles.
- The user reports passing verification: 257 Dream core tests, 205 HTTP client tests, 25 mock server tests, formatting, and an OTP 27 compile and profile smoke check. These checks were not rerun for this tracking note.
- The user reports a clean working tree with nothing pushed or published. The contribution did not modify the Gleam Dream packages.

## Remaining limitations

- `httpc` does not supply a successful response status in `stream_start`. Adoption must explicitly accept this missing capability or use a supported solution; it must not fabricate a successful status.
- OTP 27 can automatically retry a 503 response with `Retry-After`. A strict single-attempt guarantee cannot be promised on that runtime with the reported implementation.
- Reference documentation: [httpc](https://www.erlang.org/doc/apps/inets/httpc.html) and [OTP hardening guidance](https://www.erlang.org/doc/apps/inets/hardening.html). Runtime support and behavior must be rechecked against the version selected for adoption.

## Conditions for reconsideration

- Resume when the user reports an upstream decision or explicitly requests adoption work. Record the resulting upstream PRs, accepted API, and release version before selecting a dependency.
- Reassess whether Relay and LLM Wire can accept the missing successful status and the runtime-specific retry behavior. Keep this decision explicit in their public contracts.
- Verify the selected implementation against consumer requirements for bounded streaming, cancellation cleanup, error headers, deadlines, TLS, and connection ownership before replacing Gun.
- Measure the transport code removed and the adapter code retained. Prefer adoption only when it reduces maintenance without hiding unsupported guarantees.
