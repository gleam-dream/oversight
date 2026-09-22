# LLM Wire Wave 3 independent review

## Review target and verdict

- The target is the complete staged, unstaged, and untracked change in `/code/gleam-dream/llm_wire` relative to `e643755`. The review changed no LLM Wire source.
- Full Wave 3 is not complete. The ledger correctly retains multimodal content, embeddings, prompt caching, provider option coverage, retry policy, and broader reasoning behavior as Wave 3 work. Google thought signatures remain explicitly unsupported, and the strict response-header allocation bound remains unsatisfied.
- The delivered subset is not ready for acceptance. It exposes provider credentials, projects Google tool schemas through the wrong wire field, conflates application and provider tool-call identities, gives adversarial JSON objects quadratic work, and can block pool lifecycle operations behind connection setup.
- The strict response-header contract should remain unchanged. Patch and pin Gun at the identified pre-parse seam, preferably upstream, before release acceptance. Replacing Gun is the fallback if the maintainers will not carry that patch. A post-parse size check must not be accepted as the allocation bound.

## Adherence

- **PreparedCall security · `src/llm_wire/api.gleam:123` · divergent.** `prepared_headers/1` returns every transport header from an opaque prepared call. The list contains `Authorization`, `x-api-key`, or `x-goog-api-key`, so any dependent package holding a prepared call can recover the caller's credential. The external boundary probe checks fabrication and raw transport calls but does not check credential extraction. Remove this public accessor or return a deliberately redacted inspection value. Proposed **(in-place-fix, now)**.
- **Google tool schema admission · `src/llm_wire/api.gleam:841` and `src/llm_wire/schema.gleam:45` · divergent.** Google tools reuse the generic JSON Schema projection and send it as `FunctionDeclaration.parameters`. That projection emits JSON Schema forms including `additionalProperties` and `anyOf`. Google's current primary contract distinguishes OpenAPI `parameters` from JSON Schema `parametersJsonSchema`; the local test only string-matches a permissive fake peer. Project the admitted Blueprint schema through a Google-specific profile and send the matching field, then test nullable, closed-object, range, list, and rejected forms against pinned fixtures. Proposed **(in-place-fix, now)**.
- **Google tool identity · `src/llm_wire/google.gleam:391` and `src/llm_wire/api.gleam:1096,1170` · divergent.** A provider call without an `id` receives synthetic application identity `call_0`. Continuation serializes that synthetic value back as both `functionCall.id` and `functionResponse.id`, although Google defines the wire identifier as an optional provider-issued correlation value. This violates the design rule that application call identity and provider routing identity are separate. Preserve an optional provider identity independently, and omit it on the follow-up wire when the provider omitted it. Add a complete no-ID continuation test; the current test stops at reducer output. Proposed **(in-place-fix, now)**.
- **Bounded malformed JSON · `src/llm_wire_wire_json_ffi.erl:5` · bypass.** Duplicate detection calls `lists:keymember/3` for each member of the growing object. A read-only benchmark measured 1,000/2,000/4,000/8,000 unique members at approximately 5.7/19.6/77.5/324 milliseconds, while ordinary OTP decoding stayed near 0.4–1.6 milliseconds. The allowed event size therefore admits quadratic CPU work before the existing byte bounds can protect the owner. Keep the strict duplicate parser as a small internal boundary, but use a set-based accumulator and keep standard Gleam decoders and encoders on all typed paths. Proposed **(in-place-fix, now)**.
- **Pool deadlines and shutdown · `src/llm_wire_gun_pool.erl:239` and `src/llm_wire_gun_pool.erl:322` · divergent.** The pool performs `gun:open/3` and `gun:await_up/2` synchronously inside the GenServer callback. While one target connects, the pool cannot process lease returns, owner death, waiter deadlines, information requests, or shutdown. `stop/1` then catches its own five-second timeout and returns success even if the pool remains alive. Move connection establishment outside the server loop and report stop failure instead of swallowing it. Add slow-connect, stop-during-connect, and unrelated-target isolation tests. Proposed **(in-place-fix, now)**.
- **Google option admission · `src/llm_wire/api.gleam:823` · unbuilt.** Local admission only rejects OpenAI stop sequences. Google documents at most five stop sequences, but this adapter accepts and transmits an unbounded list. Enforce the admitted Google option limits locally and add accepted-boundary and first-rejected-value cases. Proposed **(in-place-fix, now)**.
- **Satisfied checks.** Terminal-only executable tool batches remain intact: Google buffers calls and publishes them only after `STOP`, while output-limited calls remain partial outcomes. The owner retains one transport credit and bounded progress queues. Pool tests establish sequential reuse, separate concurrent leases, client-owner death cleanup, queue cap, waiter timeout, and ordinary shutdown. Ordinary JSON numbers retain OTP semantics for floats and arbitrary-sized integers in the inspected cases.

## Spec

- The work order requires Google continuation without hiding provider mismatches. Explicit `thoughtSignature` rejection is honest subset behavior, but it excludes current Gemini function-calling responses that carry required signatures. Accepting this subset must retain that exclusion; it must not be described as complete Google tool continuation.
- The work order requires the retained Wave 3 families. `DESIGN-COVERAGE.md:14-25` correctly records provider options, retry, multimodal content, embeddings, prompt caching, and broad reasoning parity as partial or deferred within Wave 3. No full-wave acceptance is available while those rows remain.
- The header investigation satisfies the requested evidence boundary: the complete-header fixture proves post-parse rejection and the report does not claim pre-allocation enforcement. The required contract decision is to retain the bound and patch the dependency seam. Silently weakening the contract to post-parse rejection would contradict the work order.
- The selected ReqLLM inventory records exact tag and commit identities, licenses, named cases, exclusions, and local mappings. It is a selected comparison rather than upstream-suite evidence, as required.
- Provider fragmentation evidence is meaningful for the claimed corpus: complete representative text interactions cross every two-chunk split for all three providers. It does not cover every tool/refusal/usage interaction, and the report states that limit.

## Standards

- No documented repository-rule violation was found. The review used the repository's Nix development shell and did not edit or commit the implementation.
- The implementation uses ordinary OTP/Gleam JSON for provider envelopes and reserves Blueprint for schema-bearing contracts. The duplicate-member callback is a justified narrow exception because vanilla `gleam_json` loses duplicate-member evidence before typed decoding. `llm_wire/wire_json` should be internal rather than a new public general JSON surface; its broad dynamic helpers should remain only where Google arguments and result objects require them.

## Craft

- **Boundary test gap.** `test/external_package_boundary.sh` proves that a dependent package cannot construct `PreparedCall` or call raw client and transport entries. It still passes after the new public credential accessor was added, so it does not cover the security property stated by `DESIGN-COVERAGE.md:11`. Add a negative dependent-package credential-extraction probe. Proposed **(in-place-fix, now)**.
- **Pool test gap.** The pool suite does not exercise connection establishment that stays pending while stop, waiter deadlines, lease returns, or another target require service. Its shutdown and isolation claims therefore do not cover the blocking callback path. Proposed **(in-place-fix, now)**.
- **Report drift.** `WAVE-3-REPORT.md:102` says `git diff --cached --check` still reports two whitespace failures. The independent run passed with no output, as did `git diff --check e643755`; update the report to the current tree. Proposed **(in-place-fix, now)**.
- **JSON boundary shape.** The `wire_json` wrapper correctly composes the standard `decode.Decoder` with strict duplicate rejection, and numeric probes preserved `0`, `-0`, floats, exponents, and integers beyond 64-bit range according to OTP semantics. The public `any`, `parse_dynamic`, `is_object`, and `encode` helpers create a second consumer-facing JSON API without a design need. Keep only the strict parse seam public within the package and use standard typed decoding and encoding elsewhere. Proposed **(in-place-fix, now)**.

## Independent checks

- `nix develop --command gleam format --check src test`: passed.
- `nix develop --command gleam check --target erlang`: passed.
- `nix develop --command gleam test --target erlang`: passed, 122 tests.
- `nix develop --command sh test/external_package_boundary.sh`: passed; its stated constructor/raw-call checks are valid, subject to the credential-extraction gap above.
- `nix flake check`: passed on `aarch64-darwin`; Nix skipped the other declared systems.
- `git diff --check e643755`, `git diff --check`, and `git diff --cached --check`: passed.

## Routing

- Proposed **(in-place-fix, now)**: remove or redact `prepared_headers/1`; give Google tool schemas a provider-specific projection; separate synthetic application identity from optional Google wire identity; replace quadratic duplicate detection; make pool connection setup non-blocking; enforce admitted Google option limits; extend the boundary and pool tests; correct the stale report line; keep the JSON bridge internal and narrow.
- The retained strict header contract needs the same cure class: patch and pin the dependency at the pre-parse seam before release acceptance. If that patch cannot be maintained, select a transport that provides the bound. Proposed **(in-place-fix, tracked)**.
- No design scope should be removed to obtain acceptance. Full Wave 3 remains partial until the ledger's Wave 3 rows are built or the design owner explicitly re-scopes them.
