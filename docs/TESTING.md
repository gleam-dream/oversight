# Validation

Run checks from the repository root through its Nix shell. The full gate uses
the sibling checkouts listed in `sibling-revisions.txt`. Tests use scripted
services and disposable PostgreSQL; they need no provider accounts.

```sh
nix develop --command python3 -B scripts/ci.py quality
nix develop --command python3 -B scripts/ci.py application checkout
nix develop --command python3 -B scripts/ci.py experiments
nix develop --command python3 -B scripts/ci.py full
```

The full gate runs quality checks, all eight applications, retained experiments
and the design gate. CI divides the same commands into jobs. Its final `CI`
status requires every mandatory job to succeed; failures, cancellations and
unexpected skips cannot satisfy it.

| Obligation and design owner                                                                                           | Check                                                                                   | Profile and owner                | Evidence and limit                                                             |
| --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------ |
| Reproducible authored files; [design maintenance](design/design.typ#design-maintenance-and-rendering)                 | `nix flake check`, actionlint, ShellCheck, Ruff                                         | Quality; repository tooling      | Command logs; formatting and selected static rules                             |
| Warning-free executable consumers; [caller contracts](design/design.typ#caller-contracts)                             | Gleam warnings-as-errors and separate Erlang `-Werror` compilation                      | Each application; consumer owner | Compiler diagnostics; no claim about dependency warnings                       |
| Local protocol, recovery and storage behavior; [composition applications](design/design.typ#composition-applications) | Each application's `gleam test`, through the disposable database wrapper where required | Each application; consumer owner | Test logs and PostgreSQL logs; named scenarios only                            |
| Bounded compiler/oracle evidence; [experiments](design/design.typ#experiments-and-acceptance-evidence)                | Retained experiment runners and protocol-pilot tests                                    | Experiments; experiment owner    | Positive controls, intended negative diagnostics and scoped oracle comparisons |
| Render freshness and vocabulary integrity; [design maintenance](design/design.typ#design-maintenance-and-rendering)   | `nix run .#design-gate-check -- docs/design .`                                          | Full and CI; design owner        | Mechanical design checks; semantic fidelity requires review                    |
| CI must report failures                                                                                               | `scripts/test_ci.py`                                                                    | Quality; repository tooling      | Rejected job states, bad pins, native warning and failed-command controls      |

Application discovery is checked against the runner's inventory. Adding an
application requires adding it to the runner and declaring whether it needs
PostgreSQL. CI derives its application matrix from that inventory.
Handwritten Erlang in application source and tests is compiled
strictly after its Gleam dependency build.

The interface laboratory and HTTP declaration probe intentionally contain
unfinished runtime declarations. Their own compiler checkers remain the
acceptance boundary; they are not warning-free production packages. Frozen
upstream inputs and captured evidence are not rewritten by linting.

## Private sibling access

Create a GitHub App with repository contents read access, install it on the
eight private sibling repositories, and configure these Oversight settings:

- Repository variable `SIBLINGS_APP_CLIENT_ID`: the App client ID.
- Repository secret `SIBLINGS_APP_PRIVATE_KEY`: the App's private key.

Alternatively, configure `SIBLINGS_READ_TOKEN` as a repository secret containing
a read-only token restricted to the necessary repositories. This takes
precedence over the App. JSON Blueprint is public and uses ordinary checkout.
Tokens are not persisted in Git configuration or passed to the test commands.
Missing access configuration fails before sibling checkout.

Each required run reads immutable revisions from `sibling-revisions.txt`.
Change that file deliberately when qualifying a new ecosystem revision set.
The separate weekly compatibility workflow resolves sibling default branches
and records the actual revisions; it does not update pins or replace required
PR evidence. It can also be run manually.

## Results and release evidence

The runner writes command logs, exit codes, durations, source revisions and
toolchain identity under `.artifacts/ci/`. CI uploads these on success or
failure. Database logs survive cluster cleanup when the gate supplies
`OVERSIGHT_PG_LOG_DIR`. Missing services and failed tests remain failures.

The applications have no stable library-performance benchmark. Their test
durations are operational diagnostics, not throughput or latency claims.
Package benchmark jobs belong to the package that owns each workload.

Oversight publishes no library artifact. Release qualification uses these
composition results alongside each library's package validation. Workflows do
not publish packages or modify repository settings. Making `CI` a required
merge check is a separate GitHub branch-protection setting.
