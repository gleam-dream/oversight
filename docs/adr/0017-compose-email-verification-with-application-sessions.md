# ADR 0017: Compose email verification with application sessions

<a id="adr-0017"></a>

## Decision

- Correio owns its email and passwordless contracts in its package repository.
- Oversight retains the email portal consumer to exercise delivery, development inspection, intentional verification and application session publication.
- The application maps Correio verification evidence into its own principal. Warden's OIDC identity remains a separate authentication method.
- Correio's detailed browser, transport, storage and oracle tests remain package-owned evidence.

## Rationale

- Delivery acknowledgement does not establish possession or grant application permission.
- A consumed challenge cannot safely be verified again to repair session-publication failure.
- Application-owned publication can retain confirmed evidence and use the verification identity for idempotency.
- A separately compiled consumer exposes dependency and ownership mistakes without duplicating the package's full browser example.

## Scope

- The consumer uses memory storage and in-process mailbox HTTP requests.
- The local Correio baseline revision can be pinned before publication. Remote CI requires that revision to be available from the configured sibling repository.
