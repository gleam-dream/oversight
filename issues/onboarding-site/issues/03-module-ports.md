# Port modules 1 to 11 with their playgrounds

Status: ready-for-agent
Category: enhancement

Port each module's content and playgrounds from `onboarding/reference/src/`
with typed models and pure update functions, including sequence charts, the
ladder views (200 checkouts, 400 recommendations), the idempotency ledger,
the thundering-herd simulation and the telemetry-trace capstone. Real-time
widgets (send vs call mailbox, Sinal pipeline, Grind queue) run on one
`requestAnimationFrame` loop and must not re-render the whole page per frame.
Keep the honesty labels listed in the PRD. Re-verify package facts against
the current repositories. Add gleeunit tests for the pure simulations.
