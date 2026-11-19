# GitHub Pages deployment and parity checks

Status: done
Category: enhancement

Add a GitHub Actions workflow that builds `onboarding/site/` and deploys it
to GitHub Pages with `actions/upload-pages-artifact` and
`actions/deploy-pages`, on pushes to `main` that touch `onboarding/site/**`,
pinning Gleam and Erlang as `ci.yml` does. Use relative asset URLs so the site
works under a project subpath. Run the Playwright checks from
`onboarding/reference/check/` against the Lustre build and record the
results; then decide what happens to `onboarding/reference/`.

## Comments

AI-assisted contribution. Added `.github/workflows/onboarding-pages.yml`: on
pushes to `main` touching `onboarding/site/**` (or the workflow itself), and by
hand, it runs `gleam test` and `build.sh` inside `nix develop
--no-update-lock-file`, so Gleam, Erlang, Node and esbuild come from the flake
lock exactly as `ci.yml` pins its toolchain, then publishes
`onboarding/site/dist` with `actions/upload-pages-artifact` (v5.0.0) and
`actions/deploy-pages` (v5.0.1), pinned by commit SHA. `actionlint` passes. The
workflow has not run on GitHub yet: the repository's Pages source must be set
to "GitHub Actions" first.

The build uses only relative URLs; served under `/oversight/` over HTTP it
loads and navigates with no failed requests, and it also opens from
`file://`.

### Parity checks (reference vs Lustre build, Chromium 145)

- `tours.py` on all twelve routes: `tours`, `tourClicks`, `free` identical;
  `holes=0`, `errs=0` on both. `freeClicks` is 1–2 lower on most routes and
  varies between runs on both builds (Lustre renders on the next frame, so
  index-based clicks right after "Replay" pick different buttons).
- `zoom.py`: identical on every playground at 1366×768 and 1440×900.
- `still2.py`: identical.
- `mob.py` fails on both builds: it waits for `.tourbar .btn.pri`, which no
  tour bar has. Replaced for this run by a phone check at 390×844: no
  horizontal scroll on any route on either build, no zoom below 760 px, and
  identical screenshots of the process playground.
- Real-time widgets: over two seconds of animation (about 240 frames) the
  page DOM changed 0 times on the otp, foundations and durable-work pages
  while the widgets' own shadow trees changed 1,259, 349 and 70 times.
- `play.py` screenshots of every playground at both sizes were compared by
  the port agents; differences were limited to when the progress segment or a
  live widget was captured.

### Intentional differences

- Motion is remembered only after the reader toggles it (the reference
  stored it on every boot).
- Live widgets restart when the reader comes back to their page (each is a
  component recreated on entry); the reader's settings persist.
- Module 1: the process playground's Reset no longer also resets the
  scheduler playground.
- Module 2: pending supervisor restarts are dropped after a reset, tour Back
  or escalation, instead of reviving children under a supervisor that gave
  up.
- Module 4: the herd chart carries the PRD's "illustrative model" label in
  free play (the reference lab had none).
- Module 5: "Open the repository" opens in a new tab.
- Module 8: the 200-checkout view carries an "illustrative model" label in
  free play; a running saga animation stops where it is when the reader
  leaves or turns motion off.
- Module 9: a denied €650 refund gives its own reason ("refunds over €100
  need a human"); the reference repeated the account-closing reason.
- `aria-pressed` was added to segmented controls and toggles across modules.

### Reference issues kept for parity

- Module 6: the slow-observer button says "50 ms" while the widget and tour
  say 500 ms.
- Module 6: in routed mode with fast observers the forwarder still fills and
  drops at 6 requests/s (one event per 0.3 s hop), contradicting "Nothing
  waits and nothing drops".
- Module 5: the atlas tour says "Call an LLM" lights LLM Wire, but selects
  JSON Blueprint, the first package serving that need.

### Package facts against the current repositories

Checked read-only at each repository's default-branch head (Decisions'
default branch is `first-build`; it has no `main`). The PRD's listed facts
hold except the first item. Content was not changed.

1. `http_gun.lifecycle · http_terminated` (module 10 trace and the PRD): no
   such milestone; `HttpTerminated` encodes as `complete`,
   `locally_cancelled`, `deadline_expired` or `failed`.
2. Module 9 policy ladder (≤ €100 at ≥ 90%, 1 in 10, 10-minute hold, two
   approvals from €500) mixes sources: the Decisions example uses below €100,
   ≥ 95%, 1 in 10, then a 30-minute window instead of sampling; the clinic app
   uses ≥ 90%, 10 minutes and 1 in 5; the payout desk does not sample.
3. The PRD credits "1 in 10" to the payout desk and clinic examples; it comes
   from the Decisions README example.
4. Module 10 failure trace omits `saga.step.compensate.stop` (with the abort
   decision) before the undos.
5. Module 8 uncertain-job actions omit `ConfirmFailure`; the requeue is
   `AuthorizeReplay`.
6. Module 8 says Cancelled means "stopped before it ran"; a running job can
   also end Cancelled.
7. Module 7 Correio `Rejected` is `Temporary | Permanent`; a temporary
   rejection may succeed later.
8. Module 5 draws Decisions depending on Sinal and Grind; only its optional
   `decisions_otp` and `decisions_postgres` packages do.
9. Module 5 "used by" for Sinal and HTTP Gun omits financial recovery.
10. Module 5 Correio shows no dependencies; its optional Postmark adapter uses
    HTTP Gun.
11. Module 7 calls Relay's middle outcome a "tool refusal"; the client type is
    `ToolFailed` (the README says "tool refusal").

### Open

- Switch Pages to "GitHub Actions" and run the workflow once.
- Decide whether `onboarding/reference/` stays as an oracle (then it needs an
  entry in `docs/ORACLE.md`) or is removed.

AI-assisted contribution. Two changes on request after the parity run, so
both now differ from the reference by design:

- A log beside another column (the process log, the job history, the
  decision record) fills the height of its row. While touring it never makes
  the card taller, so fit to screen is unchanged; stacked, it keeps the cap.
- The module 1 scheduler is a real-time widget (`gd-scheduler`) instead of a
  fixed grid. A process is `Asleep(wakes_at) | Ready(since) | Running(core,
since)`; the run queue is derived from the ready processes in arrival
  order; idle cores take its head; a preemptive turn ends when the half-second
  work budget runs out, a cooperative one when the process yields, so G pins
  a core. The simulation starts four seconds into calm running, is seeded and
  steps in fixed 50 ms steps; the widget shows sleepers, the run queue, both
  cores with their budget, a scrolling timeline of slices, and the run queue
  length, longest wait over the last four seconds and core use. The tour keeps
  its four steps with wording adjusted to the moving picture and longer steps;
  with motion off the tour runs the widget ahead and the page offers "Advance
  1 second".

Checks: `gleam test` 227 passed (scheduler invariants: one process per core,
nobody waits while a core idles, first-come queue, a cooperative G never
leaves its core, no preemptive turn outlives the budget, the greedy process
at least doubles waits only without preemption); `tours.py beam` unchanged
(`tours=2 tourClicks=12 free=2`, no holes or errors); `zoom.py` 100% for the
scheduler at both sizes; with motion on the page DOM changed 0 times in two
seconds while the widget changed 1,303 times; with motion off the widget draws
statically, the tour shows waits of 1, 3 and 2 slices, and "Advance 1 second"
works.

AI-assisted contribution. Decision: `onboarding/reference/` is removed rather
than kept as an oracle; it stays in the Git history at `7b4d961`. Its
Playwright checks moved to `onboarding/site/check/` and now default to
`onboarding/site/dist/index.html` (`SITE` still overrides); `mob.py` clicks the
tour bar's Next button (`.tbn`), since the selector it used never matched.
treefmt no longer needs to exclude the reference. The PRD records the
decision. Still open outside this issue: switching the repository's Pages
source to "GitHub Actions" and the first deploy run.

AI-assisted contribution. The Playwright checks were removed too: without the
reference they had nothing to compare against, they never failed on their own,
no gate ran them, and they needed a browser outside the Nix shell. They remain
in the Git history with the reference (`7b4d961`). The PRD's validation now
names the gleeunit tests and the deploy workflow.
