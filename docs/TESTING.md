# Validation

Run checks from the repository root through its Nix shell. Local checks use
the sibling working trees beside Oversight and record their revisions and dirty
status. Required CI checks use the revisions in `sibling-revisions.txt`.
Tests use scripted services and disposable PostgreSQL; they need no provider
accounts.

```sh
nix develop --command python3 -B scripts/ci.py quality
nix develop --command python3 -B scripts/ci.py application checkout
nix develop --command python3 -B scripts/ci.py application financial_recovery
nix develop --command python3 -B scripts/ci.py experiments
nix develop --command python3 -B scripts/ci.py full
```

The full gate runs quality checks, all nine applications, retained experiments
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

The experiments profile also runs [archive release](../playground/archive_release/README.md),
[instrument replay](../playground/instrument_replay/README.md), and
[erasure campaign](../playground/erasure_campaign/README.md). Each retains its
expected outcomes, native consumer inputs, runner, observed results and limits.
Their runners check compilation before exercising local services; the two
persistence examples use disposable PostgreSQL. Follow each README to run one
experiment independently.

## Sibling access

All nine library repositories are public. CI checks them out with the default
read-only GitHub Actions token; no GitHub App or personal access token is needed.
Tokens are not persisted in Git configuration or passed to the test commands.
Oversight remains private; its visibility does not restrict access to the public
libraries.

Each required CI run reads immutable revisions from `sibling-revisions.txt`.
Change that file deliberately when qualifying a new ecosystem revision set.
The separate weekly compatibility workflow resolves sibling default branches
and records the actual revisions; it does not update pins or replace required
PR evidence. It can also be run manually.

For local reproduction, keep the nine sibling repositories beside Oversight.
The [checkout action](../.github/actions/siblings/action.yml) records their
repository locations; the manifest records the revisions. Use separate clean
checkouts when reproducing that set so existing work remains intact. The local
runner records the trees it actually uses and never changes their revisions.
The Nix lock supplies the toolchain, including Erlang/OTP 28 and PostgreSQL 16.

A passing run with dirty siblings qualifies that workspace. It does not qualify
the manifest's frozen revisions. After coordinated library changes are committed,
update the pins and rerun the affected consumer against those clean revisions
before presenting the set as reproducible release evidence.

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
