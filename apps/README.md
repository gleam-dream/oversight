# Example applications

[![CI](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/oversight/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Each application combines public library APIs with its own types, policy and
resource cleanup. External services are scripted locally.

| Application                                        | Caller task                                     | Main boundaries                                                                     |
| -------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| [checkout](checkout/README.md)                     | Reserve stock, charge payment and book shipment | Saga compensation, Grind delivery, transactional enqueue, shared PostgreSQL         |
| [financial_recovery](financial_recovery/README.md) | Recover a payment without repeating its effect  | Application evidence, Saga resolvers, audited Grind replay, isolation and retention |
| [webhooks](webhooks/README.md)                     | Deliver signed outbound events                  | Receiver idempotency, destination policy, HTTP failure to job outcome               |
| [extractor](extractor/README.md)                   | Fetch documents and extract typed invoices      | Streaming bounds, provider portability, native codec, retry policy                  |
| [support_desk](support_desk/README.md)             | Approve and execute a refund tool               | Authenticated approval, Saga reporting, preserved uncertainty                       |
| [tool_hub](tool_hub/README.md)                     | Use and serve MCP tools through an agent        | Discovery schemas, typed protocol results, invocation identity and cancellation     |
| [secure_mcp](secure_mcp/README.md)                 | Protect MCP tools and run long work as jobs     | Token validation, domain permission, HTTP mount, result lookup                      |
| [sso_portal](sso_portal/README.md)                 | Sign in and call a protected API                | Browser sessions, durable token custody, concurrent refresh                         |
| [email_portal](email_portal/README.md)             | Sign in through captured email                  | Development mailbox, explicit confirmation, account policy, session recovery        |
| [research_agent](research_agent/README.md)         | Resume research and publish with compensation   | Grind/Fabric/Saga authority, effect evidence, cancellation and VM restart           |
| [session_replay](session_replay/README.md)         | Record and reconstruct a cart session           | Retrace core, native application types, checkpoint continuation and refused gaps    |

## Run an application

From the Oversight repository, enter `nix develop` and change to the application
directory. For applications without PostgreSQL:

```sh
gleam test
gleam run
```

Applications that need PostgreSQL use the disposable cluster helper, which creates
and removes its own local database:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

No existing database, provider account or sibling checkout is needed. Published
libraries resolve from Hex; unpublished adapters use Git+path pins. Each
`manifest.toml` locks the resolved versions.

The [ecosystem design](../docs/design/design-layer.pdf) describes each
application's contract. Package designs describe each library's behavior.
