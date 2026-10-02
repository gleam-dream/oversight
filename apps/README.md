# Composition apps

Eight small but complete applications that combine the gleam-dream packages
with each other and with common Gleam ecosystem pieces (`wisp`, `mist`, `pog`,
`gleam_otp`). Each app answers one question: _do these packages compose
through their public APIs without the application fighting them?_

The apps are evidence, not products. External services (LLM providers, the
OpenID provider, payment and partner APIs) are scripted locally. Each app
records its friction in its own `FEEDBACK.md`; the cross-package synthesis
is in [docs/composition/FEEDBACK.md](../docs/composition/FEEDBACK.md), and
the per-package API cards that preceded the apps are in
[docs/composition/scan/](../docs/composition/scan/).

## Catalog

| App                               | What it does                                                                                                                         | Packages                                                             | Seams under test                                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| [checkout](checkout/)             | Order API: reserve stock, charge a payment provider, book shipment as a compensating saga; receipts and crash recovery through jobs. | saga, grind, http_gun, sinal + wisp, mist, pog                       | saga steps over HTTP errors; Postgres saga storage; jobs inserted in the app's transaction; one shared `pog` pool        |
| [webhooks](webhooks/)             | Durable outbound webhooks to tenant-supplied URLs with HMAC signing, retries and SSRF protection.                                    | grind, http_gun, sinal + wisp, mist, pog                             | http_gun failure classes → grind retry/snooze/discard; per-tenant destination policy; cassettes inside worker tests      |
| [extractor](extractor/)           | Batch document extraction: fetch with bounded streaming, extract typed records with structured output on several providers.          | grind, http_gun, llm_wire, json_blueprint, sinal + pog               | llm_wire retry advice → grind backoff; one or two HTTP clients with different policies; provider portability             |
| [support_desk](support_desk/)     | Support agent with typed tools; refunds need approval and then run as a compensating saga.                                           | fabric, llm_wire, http_gun, json_blueprint, saga, sinal              | fabric `Uncertain` vs saga unknown effects; approval gate; typed agent output; telemetry correlation agent → saga → HTTP |
| [tool_hub](tool_hub/)             | MCP in both directions: an agent uses tools discovered from a Relay server, and an agent is exposed as a Relay tool.                 | relay, fabric, llm_wire, json_blueprint, http_gun, sinal             | one tool definition across relay, fabric and llm_wire; dynamic schemas; cancellation and errors across MCP → agent       |
| [secure_mcp](secure_mcp/)         | MCP server whose tools act for a signed-in user; browser login and bearer-token checks; long tool work runs as jobs.                 | relay, warden, grind, json_blueprint, sinal + wisp, mist, pog        | relay authorization with warden tokens; mounting MCP inside a wisp app; tool → job → result                              |
| [sso_portal](sso_portal/)         | Web portal with OIDC login, Postgres-backed sessions, calls to a protected API with refresh on expiry.                               | warden, http_gun, sinal + wisp, mist, pog                            | warden in an ordinary web app; durable session custody; token reuse over http_gun; gleam_http interop                    |
| [research_agent](research_agent/) | Long-running agent driven by jobs that survives restarts, then publishes its result through a durable saga.                          | fabric, grind, saga, llm_wire, http_gun, json_blueprint, sinal + pog | conversation persistence codecs; fabric vs grind vs saga durability ownership; cancellation; crash recovery              |

Coverage: sinal is in every app; json_blueprint in 5; http_gun in 7; grind in
5; llm_wire and fabric in 4 and 3; saga in 3; relay and warden in 2 each. The
existing [ecosystem pilot](../playground/ecosystem_pilot/) already covers the
Relay → LLM Wire tool path, so these apps do not repeat it.

## Ground rules

- Use public imports only. Never edit a package to make an app work. When an
  app needs glue, write it in the app and record it as feedback: the glue is
  the evidence.
- Use sibling path dependencies (`../../../<package>`), so every app tracks the
  current package heads.
- Script external services on loopback, or use `http_gun` cassettes. No
  network access, real keys or paid calls.
- Every app has a runnable `main`, tests for the common path, at least one
  advanced configuration and its failure paths, and a `telemetry` module that
  attaches to every package's Sinal events it uses.
- Every app writes `FEEDBACK.md` in the format below.

## Running

From the app directory, inside the oversight dev shell (`nix develop`):

```sh
gleam test
gleam run
```

Apps that need Postgres wrap the command with the disposable cluster script,
which exports `DATABASE_URL`:

```sh
../scripts/with-postgres.sh gleam test
```

## Feedback format

Each `FEEDBACK.md` opens with the verdict (does the combination work, and how
much glue it took), then lists findings. A finding has:

- **Id and title**, e.g. `CHK-3 Saga step errors cannot carry http_gun failure classes`.
- **Packages** involved and **kind**: `composition`, `ergonomics`,
  `extensibility`, `flexibility`, `ecosystem-interop`, `defect`, or `docs`.
- **Severity**: `blocker` (needed a workaround that defeats the package's
  purpose), `major` (substantial glue or a footgun), `minor`, or `nit`.
- **Evidence**: app `file:line` for the glue and package `file:line` for the
  cause.
- **Proposal**: the smallest public-API change that removes the friction,
  and which package owns it.

It closes with **What worked well**, because features that composed cleanly
are as important to keep as the friction is to remove.
