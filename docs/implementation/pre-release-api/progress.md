# Pre-release API cleanup progress

The prior additive implementation was the starting point. The user superseded its compatibility constraints, with a separate Blueprint 2.0 migration requirement. The cleanup is accepted, integrated, and committed locally after user authorization. No publication occurred.

| Assignment                      | State    | Owner                | Acceptance evidence                                                                                                                                                                                                     |
| ------------------------------- | -------- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blueprint inventory and cleanup | accepted | cross_package_review | All 297 baseline declarations classified; released recursion and lightweight aliases retained; migration guide reviewed; final 144 tests pass on each of Erlang and JavaScript.                                         |
| Sinal inventory and cleanup     | accepted | cross_package_review | All 91 baseline declarations classified; direct callback API reviewed; final 50 tests and independent Nix gate pass.                                                                                                    |
| Relay inventory and cleanup     | accepted | relay_config         | All 474 baseline declarations classified; ordinary/advanced/content paths reviewed independently; final 119 tests, negative compiler fixture, frozen schema/checksum checks, 109 conformance checks, and Nix gate pass. |
| LLM Wire inventory and cleanup  | accepted | llm_consistency      | All 307 baseline declarations classified; source reviewed by root and a separate agent; final 147 tests, external compiler probes, and Nix gate pass.                                                                   |
| Consumer integration            | accepted | cross_package_review | All seven loopback scenarios pass in the assembled workspace; executable example runs; no legacy imports remain in active consumers.                                                                                    |
| Final cross-package review      | accepted | root                 | No blocking independent findings; 129 paths integrated after baseline and post-write hash checks; every original package and the pilot pass format, check, build, tests, and diff checks.                               |

Initial source inventory, including implementation-facing public declarations: Blueprint 297; Sinal 91; Relay 474; LLM Wire 307. The audits include functions, constants, types, and aliases. They distinguish implementation exports and newly moved paths from intended application API; moved declarations are not counted as additional caller capabilities.

The original and isolated worktrees matched at the start. Saved file hashes protected the preceding uncommitted work during integration. All package and dependency versions remain unchanged. The pilot adds glisten as a direct dependency at its already locked version for its local fake provider.

Review corrections were completed before acceptance: retained Blueprint recursion and inexpensive aliases; removed Sinal's orphan constructor comment; preserved LLM custom CA behavior and fixed deadline classification; removed Relay's final metadata shortcut and migrated its negative fixture. See [the review](review.md), [contract](contract.md), and [item-by-item acceptance](acceptance.md).

## Committed delivery

| Package        | Commit                                     |
| -------------- | ------------------------------------------ |
| json_blueprint | `ca50b5a915aaa5e38ef68ff70b102f2dd3f2fe67` |
| sinal          | `1c50c93a3a93569eb60a246475261e20430018b7` |
| relay          | `04e0c2059e819a34d39dadfc5436faf65ff0926d` |
| llm_wire       | `485f7fa090a183c2914013186b6cbcac1d46bf67` |

The Oversight delivery commit contains the pilot, review, and acceptance evidence. Relay’s executable dependency pins point to the Blueprint and Sinal commits above; checksum and pin verification passed after the update. Package versions and the frozen protocol checksum are unchanged.
