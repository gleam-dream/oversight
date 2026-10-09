# Email portal

## Purpose

- This separately compiled application composes Correio delivery, development mailbox inspection, intentional verification and application-owned session publication.
- Correio owns message and challenge semantics. Oversight owns this consumer's composition assertions.
- `AccountId`, `Principal` and opaque `Session` are application-native types. An email verification principal does not claim Warden OIDC evidence.

## Run

- Check out Correio beside Oversight at the revision in the ecosystem manifest.
- Run from Oversight's root:

```sh
nix develop -c sh -c 'cd apps/email_portal && gleam test && gleam run'
```

- The executable creates and stops its own bounded memory store and capture.
- The executable prints one result line. It does not print authentication secrets.
- No database, credentials, HTTP listener or live mail provider is required.

## Flow

- Construct the challenge service from an explicitly owned memory runtime.
- Construct `email_portal.new` with a typed sender and trusted sender address.
- Take a capture checkpoint before calling `email_portal.request` with the current trusted account.
- Inspect new mail with `correio/testing.await` and the same capture's explicitly configured `correio_mailbox` handler.
- Call `email_portal.confirm` only after intentional submission of the answer.
- Supply the current trusted account on every confirmation or recovery attempt.
- Keep returned `Retry` values in application custody. They may contain confirmed evidence or an uncertain verification command.
- Thread the returned application state sequentially.
- Publish a session through an application callback keyed by `session_id`.
- Retry failed publication with retained evidence. The consumed answer is not verified again.

## Policy and evidence

- Disabled accounts and accounts whose identity or destination changed cannot receive a session.
- Capture acceptance proves local capture admission. Provider acceptance does not prove inbox delivery.
- Mailbox inspection neither consumes the challenge nor creates a session.
- Delivery failures remain typed outcomes. Unknown submission is returned without an automatic resend.
- The publication callback must be idempotent by `session_id`, including when publication succeeds but its reply is lost.
- `session_id` is a publication identity, not a browser bearer credential. This consumer implements no cookie or browser session transport.
- The default example uses a magic link. The advanced test uses an eight-digit code, a shorter challenge lifetime, two attempts, a custom sender and a custom mailbox mount.
- The fixed key and `portal.example` link are local fixtures. The example is not a production deployment template.

## Retained checks

- Ordinary delivery, capture checkpoint, inbox and message HTTP handler inspection, intentional confirmation and native principal mapping.
- Wrong-answer refusal followed by a valid code; consumed-answer reuse refusal.
- Publication failure followed by evidence-based recovery and repeated publication returning one session.
- Publication committed before a lost reply, followed by idempotent recovery of that same session.
- Challenge consumption committed before a lost reply, followed by unavailable recovery and successful replay of the original verification command.
- Current account policy checked before consumption and again before publication recovery.
- Full and stopped capture failures; unknown delivery without automatic resend.

## Limits

- Tests call the standard Gleam HTTP handler in process. They do not prove browser navigation or network transport.
- Session state is local and sequential. A production publisher needs durable atomic idempotency and an application-owned session credential.
- Pending evidence belongs to this application's service context and must not be accepted from untrusted clients or other application instances.
- Correio's package owns its browser, SMTP, provider, database, concurrent consumption, benchmark and upstream-oracle evidence.
