# Guided tours, fit-to-screen and animated progress

Status: done
Category: enhancement

Port the tour system as a reusable typed component: steps with text, optional
action and duration; Back (reset and replay), Next, Play/Pause, Skip and
Replay; controls inert while touring; segmented progress whose current
segment fills over the step duration while playing; fit-to-screen scaling
(100% down to 60%, re-fit per step, on resize and after fonts load, off below
760 px); scroll the card under the app bar on user actions. Respect Motion
off. Keep the step wording from `onboarding/reference/src/*.x.js`.

## Comments

AI-assisted contribution. The tour system is `site/tour.gleam`, generic over
each page's tour identifiers, model and messages. It landed with the shell
(commit `8188e78`) because the course map's six-layer playground is itself a
tour; this issue verified it.

Model: a tour is `Guided(step, Paused | Playing)` or `Free`, plus an epoch
that every transition bumps. A playing tour schedules its next advance as
`Advance(epoch)`, so an advance scheduled before a pause, click, reset or page
change is stale and ignored. A step is narration plus an optional action that
returns the page's own messages for the current model, so tours drive
playgrounds through the same verbs as their buttons. `tour.plan` is the pure
transition (Next, Back, Play, Pause, Skip, Replay, Advance) and returns the
steps to run, the advance to schedule and whether to bring the card under the
app bar; `tour.update` runs it against a page. Back resets and replays steps 1
to the previous one, as the reference does; Replay resets and runs step 0;
Play from a narrated first step jumps to step 1; playing stops at the last
step without unlocking. Leaving a page or turning motion off pauses its tours.
The tour bar keeps the reference markup and classes: inert controls, hidden
description, `tour-hide` and capped logs come from the shared CSS; the current
segment fills over the step's duration while playing by alternating two
identical keyframes.

Fit to screen (`site/fit.gleam`, measured by the shell after each paint) is
`Settling(zoom)` or `Settled(zoom, height)` under a basis of narration and
viewport size: on a new basis it starts one step above a proportional
estimate and shrinks by 5 per paint until the card fits; a settled card
shrinks again if it overflows and grows only when its content shrinks by more
than 90 px, so it never oscillates. Floor 60%, off below 760 px, re-fitted on
step changes, resize and font loading.

Checks run:

- `gleam test`: 34 passed, including every tour transition, stale advances,
  motion off, pausing on leave and the course-map tour end to end.
- `zoom.py` against the build: course map 80% (1366×768) and 95% (1440×900),
  matching the reference.
- `play.py start 0 5000` at 1366×768 and 1440×900 on both builds: the
  1366×768 screenshots are byte-identical; at 1440×900 14 pixels differ at the
  leading edge of the animated progress segment (timing).
- `tours.py start`: no holes, no errors, tour completes and free play works.

The 33 module tours are verified under issue 03 as the modules are ported.
