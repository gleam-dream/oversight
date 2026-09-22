# Integration pilot progress

The API ergonomics consumer is implemented in the isolated Oversight worktree.
It uses one admitted Relay inventory definition for registration, typed calls,
codec access, and its application-owned LLM declaration adapter. The configured
LLM session owns continuation settings; Relay uses composable local HTTP
configuration; Sinal uses `observe` with explicit detach.

The original five real transport scenarios remain, and generic and explicitly rendered JSON-text
application-error scenarios bring the suite to seven. The prior five-scenario
report and its conclusions are superseded by [REPORT.md](REPORT.md).

The observed package Git heads remain Blueprint `d3f0708`, Sinal `dd09933`,
Relay `098417b`, LLM Wire `cdfb38a`, and Oversight `8db2b00`; the exercised API
changes are uncommitted additions on those baselines. Pilot format, check, run,
and test gates pass locally, with `gleam run` printing
`A-100 has 7 Ada Lovelace notebooks.` and `gleam test` passing 7 tests.
