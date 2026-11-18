# Port modules 1 to 11 with their playgrounds

Status: done
Category: enhancement

Port each module's content and playgrounds from `onboarding/reference/src/`
with typed models and pure update functions, including sequence charts, the
ladder views (200 checkouts, 400 recommendations), the idempotency ledger,
the thundering-herd simulation and the telemetry-trace capstone. Real-time
widgets (send vs call mailbox, Sinal pipeline, Grind queue) run on one
`requestAnimationFrame` loop and must not re-render the whole page per frame.
Keep the honesty labels listed in the PRD. Re-verify package facts against
the current repositories. Add gleeunit tests for the pure simulations.

## Comments

AI-assisted contribution. All eleven modules are ported under
`onboarding/site/src/pages/`, each page with its own typed model, pure
simulations in submodules and gleeunit tests. The work ran as eight parallel
ports in separate worktrees (`port/*` branches), squash-merged here.

Per module, the state that matters and the verbs that change it:

- 1 The BEAM: processes `Running(mailbox, handled) | Crashed`, a cart–payment
  link, chart events from domain events; scheduler `Cooperative | Preemptive`
  with a pure slice schedule.
- 2 OTP: a cart actor whose requests derive send or call from the operation;
  supervision tree with `Watching | GaveUp`, child statuses and restarts that
  carry an epoch; the mailbox widget `gd-mailbox` with token states
  `Flying | Queued | Working | Replying | Done` (matched against the reference
  `mbSim` over 2,400 random frames: no mismatch).
- 3 Gleam: loose record judged `ValidByLuck | BugWaiting`, the Disputed
  exhaustiveness demo, the Result railway as `AllOk | FailedAt`, typed versus
  untyped sends.
- 4 Principles: the "did it happen?" break point, curtain, key and ledger;
  the seeded herd with congestion (exact match to the reference draws); LLM
  Wire bounds as `Option(Bound)`.
- 5 Atlas: fifteen package tiles with `IsSelected | BuildsOn | UsesIt |
Unrelated`, need filter `Everything | Serving(Need)`.
- 6 Foundations: the Sinal widget `gd-sinal` with event stages and a handler
  `Serving | WaitingFor`; codec cases `Decoded | Refused`; destination policy
  `admit` returning `Admitted | Refused`.
- 7 Outside world: four flows built from typed options, a pure walk and chart.
- 8 Durable work: all eleven Grind stored states; the queue widget
  `gd-grind-queue` (seeded, matches the reference at 40 and 60 ticks); saga
  step states, outcomes `Completed | Aborted | HeldForReconciliation | Lost`,
  epoch-guarded replay; the 200-checkout ladder loads a case into the saga.
- 9 Agents: Fabric decisions `Allow | Deny | RequireApproval | HandOver`, store
  backends and uncertain effects, the decision point's phases with verbs a
  phase does not offer ignored, and the 400-case ladder loading a case into
  the point.
- 10 Compose: a shared epoch-guarded stepper for the systems walk and the
  trace, the builder as a pure `design(needs)`, the capstone trace with real
  event names and places.
- 11 Field guide: Retrace scrub with strategy and privacy, glossary filter,
  cheat sheet and reading plan.

Real-time widgets are Lustre components on the shared frame loop; pages pass
settings as attributes and commands as sequence numbers, so the page never
re-renders per frame. Shared changes made while integrating: fit to screen
now walks down from 100% before the browser paints (card height is not
monotonic in zoom, so only the reference's walk gives its answer), ignores
measurements taken before a zoom applied, and re-measures when the page view
resizes; pages get an `enter` hook so the herd chart grows on arrival as in
the reference; the agents scatter's `log10` and `toFixed` are pure Gleam,
checked against JavaScript on all 400 dots.

Checks run on the merged build:

- `gleam test`: 220 passed, no failures.
- `bash build.sh`: 496 KB `dist/`.
- `tours.py` on all twelve routes: `tours`, `tourClicks` and `free` equal the
  reference on every route, `holes=0`, `errs=0`. `freeClicks` differs by 1–2
  on most routes and varies between runs on both builds: Lustre renders on
  the next frame, so the script's index-based clicks right after "Replay"
  land on different buttons.
- `zoom.py`: identical to the reference on every playground at 1366×768 and
  1440×900 (worst 65%, the supervision tree at 1366×768).
- `still2.py`: identical (`otp … tokens after 3 s: 12`, `foundations … 2`, no
  play buttons, no errors).
- Each port agent compared `play.py` screenshots of every playground at both
  sizes with the reference; differences were limited to the moment the
  progress segment or a live widget was captured.

Package facts were re-verified read-only against the sibling repositories;
discrepancies are listed in the parity report under issue 04. Content was not
changed for them.
