# PRD: gleam-dream onboarding site

Status: ready-for-agent
Category: enhancement

## Summary

An interactive onboarding site that takes a new developer from the BEAM to
real systems built with the gleam-dream libraries in about 3½ hours, with no
code: concepts, pictures, guided playgrounds and simulations. The goal is a
mental model the reader can navigate by: what each layer gives them, what
each package owns, and how the packages compose.

The course was first built as a single self-contained HTML page generated
from per-module fragments by a small Python assembler (see "Reference
implementation"). It is rebuilt as a **Lustre** application in
`onboarding/site/` and published with **GitHub Pages**, with behaviour parity
to that reference.

## Audience and success criteria

- New developers joining work on or with gleam-dream. They may know another
  language well but not the BEAM, OTP or Gleam.
- Finishable in 2 to 4 hours without rushing (the course map says about
  3½ hours; module estimates sum to 215 minutes).
- High level only: no implementation details. Module 3 shows short Gleam
  snippets, highlighted, where the data shape or the pattern is the concept:
  custom types, a Result pipeline, a message type and a case expression,
  plus the compiler's real errors. Every snippet compiles (`snippets/` in the
  site). Elsewhere, data shapes (JSON) and event names are shown where they
  are the concept itself.
- After finishing, the reader can: explain processes, messages, links and
  supervision; explain what Gleam's types add; state the seven shared habits
  of the ecosystem; pick packages for a described system; and read a telemetry
  trace.
- Every playground first runs as a guided tour, then unlocks for free play.
- Clear, explicit, concise language. No quizzes (removed on request).

## Learning path

Hash routes are plain names (claude.ai artifacts only pass `#name`; keep this
on GitHub Pages too so links stay stable).

| #   | Route            | Title                        | Min | Playgrounds (tour id)                                                                                                                                                                                                                                                                                                                                                                                             |
| --- | ---------------- | ---------------------------- | --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0   | `#start`         | Course map                   | –   | Six-layer stack (`stack`)                                                                                                                                                                                                                                                                                                                                                                                         |
| 1   | `#beam`          | The BEAM                     | 20  | Process playground + live sequence chart (`proc`); two-core scheduler, cooperative vs preemptive (`sched`)                                                                                                                                                                                                                                                                                                        |
| 2   | `#otp`           | OTP                          | 20  | Actor stepper + call/reply chart (`actor`); **real-time** send vs call mailbox under load (`load`); supervision tree with strategies, restart intensity, escalation + chart (`tree`); where libraries plug into your tree (`plug`)                                                                                                                                                                                |
| 3   | `#gleam`         | Gleam                        | 15  | Impossible states, loose record vs custom type with both types in code, plus the "add Disputed" exhaustiveness demo with the compiler's error (`types`); pattern matching arm by arm: fields, guards, lists, string prefixes, alternatives, and an arm deleted to show exhaustiveness (`match`); Result railway with the `use` pipeline (`rail`); typed Subject vs untyped mailbox with the message type (`msgs`) |
| 4   | `#principles`    | How gleam-dream thinks       | 20  | Seven habits explorer; ownership sorter, library vs your app (`sorter`); "did it happen?" break-the-network simulator with sequence chart and a provider-side idempotency ledger (`happen`); thundering-herd retry simulation (`herd`); define once, use everywhere (`defs`); LLM Wire timeouts (`bounds`)                                                                                                        |
| 5   | `#atlas`         | The package atlas            | 15  | Layered map with need filter, dependency highlighting and detail panel (`atlas`)                                                                                                                                                                                                                                                                                                                                  |
| 6   | `#foundations`   | Foundations                  | 20  | **Real-time** Sinal pipeline, inline vs bounded forwarder (`sinal`); JSON Blueprint codec: encode, decode cases, schema (`codec`); HTTP Gun anatomy (`anatomy`); destination policy (`dest`)                                                                                                                                                                                                                      |
| 7   | `#outside-world` | The outside world            | 20  | Step-through sequence charts for LLM Wire, Relay, Hellhound and Correio with branch options (`flows`)                                                                                                                                                                                                                                                                                                             |
| 8   | `#durable-work`  | Work that outlives a request | 20  | Grind job lifecycle state machine (`grind`); live Grind queue: skip-locked claims, leases, renewer heartbeat, killable workers (`lease`); transactional admission (`tx`); Saga checkout with parallel steps, compensation, hold, crash in local vs durable mode (`saga`); 200 checkouts at once (`sagax`)                                                                                                         |
| 9   | `#agents`        | Agents & people in the loop  | 25  | Fabric policy gate (`gate`); pull the plug: store backends and uncertain effects (`plug`); Decisions point state machine with policy versions v1–v4 (`point`); 400 recommendations scatter, linked back to the single case (`p400`)                                                                                                                                                                               |
| 10  | `#compose`       | Composition studio           | 25  | Ten Oversight apps step by step (`systems`); six composition patterns; system builder with nearest example (`builder`); capstone: the durable checkout as a telemetry trace (`trace`)                                                                                                                                                                                                                             |
| 11  | `#field-guide`   | Field guide                  | 15  | Retrace scrub with replay strategies and privacy (`retrace`); tooling; filterable glossary; cheat sheet; reading plan                                                                                                                                                                                                                                                                                             |

Every module ends with a "Carry this forward" sentence and a footer with a
"Mark module N as done" toggle plus previous and next links.

## Content facts and sources

All package facts come from the gleam-dream repositories (READMEs and
source) as they were at authoring time. Re-verify against the current
repositories when porting. Facts that are easy to get wrong:

- Grind: stored states are Queued, Scheduled, Retryable, Executing,
  Succeeded, BusinessFailed, RuntimeFailed, ContractMismatch, Uncertain,
  Discarded and Cancelled. **An abandoned attempt defaults to `HoldUncertain`**;
  `ReplayAfterLeaseExpiry(max_replays)` is opt-in (`worker.with_abandonment`).
  Jobs can be admitted in the caller's `READ COMMITTED` transaction
  (`submit_in`). Each queue has its own coordinator, attempt actors and a lease
  renewer on a reserved connection.
- Fabric: policy decisions are `Allow`, `Deny(reason)`,
  `RequireApproval(requirement)` and `HandOver(reason)`. HandOver ends an
  agent run as `HandedOver` and withdraws calls of the same model reply that
  had not started. A graph run takes no handover; it waits for a signal.
- Decisions: not on Hex; installed from Git. The core is pure and builds for
  Erlang and JavaScript; `decisions_otp` and `decisions_postgres` are separate.
  The policy ladder used in examples (1 in 10 sampled, undo windows, two from
  finance from 500.00) comes from the payout desk and clinic examples.
- Hellhound: pre-production; production needs independent security review.
- LLM Wire default generation timeouts: whole call 600 s, first progress
  180 s, idle gap 60 s.
- Sinal forwarder default capacity: 1,024 events, queued plus executing;
  drops and counts when full. Event names become permanent atoms.
- HTTP Gun: failure evidence is `NotSent` or `MaybeSent`; no automatic
  retries; the default destination policy admits public addresses and permits
  plaintext, and loopback is opt-in.
- Correio delivery outcomes: Accepted, NotSent, Rejected, OutcomeUnknown.
- Relay call outcomes: succeeded, tool refusal, request for more input.
- Telemetry names used in the capstone trace are real:
  `grind.job.admitted|claimed|acknowledged`, `grind.diagnostic.renewal`,
  `saga.run.start|stop`, `saga.step.start|stop`, `saga.step.undo.stop`,
  `http_gun.lifecycle` with milestones `admission_granted`,
  `gun_call_returned`, `response_headers`, `http_terminated`.
- Example-app package sets come from each app's `gleam.toml` in this repository.
- A process copy does not keep sharing, so a value holding codecs or
  closures (a Grind worker, a Fabric agent, a Relay tool list) costs its flat
  size each time it moves, and a test should bound it. JSON Blueprint's codec
  practice guide states the rule for any such value and how to test it
  (module 6's "Mind the copy" note).

Honesty labels that must stay visible in the port:

- The capstone trace order is reconstructed from the checkout design, not
  recorded from a live run.
- The 400-recommendation scatter, the 200-checkout view and the
  thundering-herd simulation are illustrative models (seeded randomness).
  The herd model includes congestion: an overloaded service serves fewer
  requests (capacity drops when arrivals exceed twice capacity).
- The live Sinal widget uses a forwarder of 12 slots for visibility and says
  the real default is 1,024.

## Interaction design

### Guided tours (every playground)

- A playground opens in **tour mode**: a compact dark bar at the top shows
  `n/total`, the narration, Back, Play/Pause (only when motion is on) and
  Next ("Finish and unlock" on the last step), with segmented progress and a
  "Skip tour · unlock controls" link.
- Each step is `{ text, action?, ms? }`. Moving to a step runs its action
  against the playground's own handlers. Back resets and replays actions up
  to the previous step. Play advances every `ms` (default 3600).
- While touring, the playground's controls are inert (pointer events off),
  its description paragraph is hidden, secondary text marked `tour-hide` is
  hidden, and logs are capped.
- **Progress animation**: segments before the current one are full. While
  playing, the current segment fills linearly over that step's `ms` and
  restarts on every step. Paused, the current segment shows full.
- **Fit to screen**: while touring, the playground is scaled so the whole
  card (tour bar plus content) fits below the app bar, from 100% down to a
  floor of 60%, re-fitted on every step, on resize and after fonts load. Off
  below 760 px width. Next, Back, Play and Replay scroll the card to sit just
  under the app bar. Measured with the reference: at 1440×900 every
  playground fits at 75% or more; at 1366×768 most are 80–100%, the worst
  65%.
- After the tour, a light "Free play" bar offers "Replay the guided tour".
- The tour scripts for all 35 tours live in each page's `script` function
  under `onboarding/site/src/pages/`, with the reference's wording.

### Real-time widgets (GenStage-explainer style)

Driven by one `requestAnimationFrame` loop that updates only the widget's
SVG, never the whole page. Tokens move continuously between stations.

- **Send vs call** (`#otp`): four request processes, one actor at 4 msg/s
  (250 ms service), travel 0.4 s each way. Send mode emits at the slider rate
  (1–12/s) and the mailbox grows without bound (counters: sent, handled,
  waiting, oldest wait; a memory bar). Call mode lets each of the four callers
  have one outstanding call; replies travel back in green and throughput
  self-limits to the actor's pace.
- **Sinal pipeline** (`#foundations`): request handler, forwarder (12 slots),
  observer (fast 50 ms or slow 500 ms). Inline: the handler blocks while the
  observer runs (turns red; "handler blocked" seconds). Routed: the handler
  never waits; when the forwarder is full, new events fall off in red and are
  counted. Rate slider 1–20/s, burst of 30, pause and reset.
- **Grind queue** (`#durable-work`): 14 rows, three workers, lease 15 ticks,
  renewal every 5 ticks on a 220 ms tick; skip-locked claims logged; 8%
  handler failure → retry with backoff; killed worker's lease drains red and
  then the job is held as Uncertain (default) or replayed (toggle).

### Sequence charts

Lanes are participants; time flows down; events are messages (arrow), notes,
crashes (red X) or lost messages (half arrow with a lightning bolt). The
newest arrow draws in. Live charts are capped to their latest 9–10 events so
heights stay bounded. Used in modules 1, 2, 4, 7 and 10.

### Ladder of abstraction

One concrete case, then many: the 200-checkout grid and the 400-dot scatter.
Clicking a square or dot loads that exact case into the single-case
playground above and scrolls to it.

### Motion

A "Motion: on/off" toggle in the app bar defaults to the OS
reduced-motion setting and is remembered. Off: no auto-play, no
transitions or animations, live widgets draw statically and offer
"Advance 1 second", and animated runs jump to their final state.

### Progress

"Mark module N as done" per module, a progress bar in the app bar and done
markers in the module menu and on the course map, stored in `localStorage`
(wrapped in try/catch; the site works without it).

## Visual design

- Fonts: Space Grotesk (headings), Inter (body), JetBrains Mono (labels and
  kickers), from Google Fonts.
- Ground `#FAF8F4`, card `#FFFFFF`, ink `#17162B`, muted `#5B5970`, line
  `#E4E0D8`, accent magenta `#B0186E`.
- Layer tints (background / ink): BEAM `#2B2862` dark; OTP `#DCD9FF` /
  `#241F6B`; Gleam `#F9D7F0` / `#4A1340`; Foundations `#DDF3F0` / `#0B4A45`;
  Transport `#E0E9FD` / `#163A8A`; Outside world `#EEE7FD` / `#3B1785`;
  Durable work `#FDF0DC` / `#6B3404`; Agents & oversight `#FCE7F3` /
  `#5E0B3A`; Inspection `#E2F4E7` / `#0E4D25`; Tooling `#EDEFF3` / `#3B4452`.
- Status colours: success `#15803D` on `#E2F4E7`, failure `#B42318` on
  `#FDECEA`, uncertain `#5C4300` on `#FFF1C2`.
- Components: kicker, card, lab (playground card, radius 24), segmented
  control, pill buttons (min height 44, 36 small), dark "Carry this forward"
  key block, log panel, box. No emoji in UI; icons are inline SVG.
- Accessibility: real buttons and links, `aria-pressed` on toggles,
  `aria-live` on tour narration, `role="img"` with labels on charts,
  4.5:1 text contrast, works at phone width.

## Reference implementation

The single-page reference the port was built against lived in
`onboarding/reference/` until parity was verified (issue 04) and was then
removed; it remains in the Git history at commit `7b4d961`, with the
Playwright checks used to compare the two builds.

## Requirements for the Lustre port

1. A Gleam project targeting JavaScript with Lustre (the repository already
   uses Lustre 5.x under `playground/mobile_shells`), placed at
   `onboarding/site/`.
2. One single-page application with the twelve routes above and hash
   routing, including in-page anchors that scroll without changing the route.
3. Typed models per module: custom types for every simulation state (job
   states, saga step states, decision-point phases, tour state) instead of
   strings, in the spirit of module 3.
4. Pure update functions for simulations, separated from rendering and
   effects, so they can be unit tested on the JavaScript target with gleeunit
   (step a simulation, assert counts and states).
5. Timers and animation through Lustre effects and a small FFI for
   `requestAnimationFrame`, `matchMedia`, `localStorage`, scrolling and
   measurement. Real-time widgets must not re-render the whole page per
   frame: keep them as isolated components, or render them imperatively
   through FFI into a container Lustre does not manage.
6. Parity with the reference for content, tour scripts, playground
   behaviour, motion handling, progress storage, accessibility and visual
   design. Where the port intentionally differs, record why.
7. Static build output deployable to GitHub Pages under a project subpath:
   relative asset URLs, no server routing.
8. A GitHub Actions workflow that builds the site and deploys it to Pages on
   pushes to `main` touching `onboarding/site/**`, using the official
   `actions/upload-pages-artifact` and `actions/deploy-pages` actions. Pin
   Gleam and Erlang the way `ci.yml` does.
9. Keep the reference until parity is verified; then decide whether to keep
   it as an oracle or remove it.

## Validation

- gleeunit tests on the JavaScript target for the pure simulations, the tour
  engine, fit to screen and every tour end to end
  (`nix develop ../.. --command gleam test` in `onboarding/site/`).
- The Pages workflow runs the tests and the build before every deploy.
- Parity with the reference was verified once, with its Playwright checks,
  before the reference was removed; issue 04 records the results.

## Decision history

- Built first as a Design canvas, then rebuilt as one self-contained site.
- Quizzes removed in favour of guided tours and done-marking.
- Module 3 gained compiled, highlighted Gleam snippets of its data shapes and
  a pattern-matching playground, on request: seeing the types themselves
  helps readers who are new to Gleam.
- Added after research into interactive explainers (Andrea Leopardi's
  Broadway and GenStage posts, Sam Rose's essays, The Secret Lives of Data,
  Bret Victor's "Up and Down the Ladder of Abstraction", Visualixir, Stripe's
  idempotency writing, Temporal's replay walkthrough): guided-first tours,
  sequence charts, live simulations, ladder views, an idempotency ledger, a
  trace capstone and a motion toggle.
- Tours redesigned to fit a laptop screen with continuous progress; GenStage-
  style real-time widgets added.
- The sibling library repositories were read only; nothing outside this
  repository was changed.
- Rebuilt in Lustre with behaviour parity to the reference, verified with the
  reference's own browser checks; the reference was then removed rather than
  kept as an oracle.

## Inspiration links

- https://andrealeopardi.com/posts/broadway-visual-explainer/
- https://andrealeopardi.com/posts/genstage-demand-visualized/
- https://samwho.dev/ and https://encore.dev/blog/queueing
- http://thesecretlivesofdata.com/raft/
- http://worrydream.com/LadderOfAbstraction/
- https://github.com/koudelka/visualixir
- https://stripe.com/blog/idempotency and https://brandur.org/idempotency-keys
- https://docs.temporal.io/encyclopedia/event-history

## Open questions

- Final public URL and whether Pages serves from this repository or a
  dedicated one.
- Whether the site needs a "last verified against" stamp per package so
  content staleness is visible.
