# Example applications

Each application combines public library APIs with its own types, policy and
resource cleanup. External services are scripted locally.

| Application                                | Caller task                                     | Main boundaries                                                                 |
| ------------------------------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------- |
| [checkout](checkout/README.md)             | Reserve stock, charge payment and book shipment | Saga compensation, Grind delivery, transactional enqueue, shared PostgreSQL     |
| [webhooks](webhooks/README.md)             | Deliver signed outbound events                  | Receiver idempotency, destination policy, HTTP failure to job outcome           |
| [extractor](extractor/README.md)           | Fetch documents and extract typed invoices      | Streaming bounds, provider portability, native codec, retry policy              |
| [support_desk](support_desk/README.md)     | Approve and execute a refund tool               | Authenticated approval, Saga reporting, preserved uncertainty                   |
| [tool_hub](tool_hub/README.md)             | Use and serve MCP tools through an agent        | Discovery schemas, typed protocol results, invocation identity and cancellation |
| [secure_mcp](secure_mcp/README.md)         | Protect MCP tools and run long work as jobs     | Token validation, domain permission, HTTP mount, result lookup                  |
| [sso_portal](sso_portal/README.md)         | Sign in and call a protected API                | Browser sessions, durable token custody, concurrent refresh                     |
| [research_agent](research_agent/README.md) | Resume research and publish with compensation   | Grind/Fabric/Saga authority, effect evidence, cancellation and VM restart       |

## Run an application

From the Oversight repository, enter `nix develop`, then change to the
application directory. Its README gives the commands to run the tests and demo.
For applications without PostgreSQL:

```sh
gleam test
gleam run
```

Applications that need PostgreSQL use the disposable cluster helper:

```sh
../scripts/with-postgres.sh gleam test
../scripts/with-postgres.sh gleam run
```

The helper creates and removes its own local database. No existing database or
provider account is needed. Dependencies resolve from sibling checkouts.

## What the examples test

The examples cover ordinary use, application types, advanced configuration and
failure recovery. They exercise local HTTP, process lifetimes and PostgreSQL
where the scenario requires them. Compilation alone does not prove timing,
persistence or external-effect guarantees.

The [ecosystem design](../docs/design/design-layer.pdf) describes the composition
contracts. Package designs describe each library's behavior.
