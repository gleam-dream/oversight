# Guided tours, fit-to-screen and animated progress

Status: ready-for-agent
Category: enhancement

Port the tour system as a reusable typed component: steps with text, optional
action and duration; Back (reset and replay), Next, Play/Pause, Skip and
Replay; controls inert while touring; segmented progress whose current
segment fills over the step duration while playing; fit-to-screen scaling
(100% down to 60%, re-fit per step, on resize and after fonts load, off below
760 px); scroll the card under the app bar on user actions. Respect Motion
off. Keep the step wording from `onboarding/reference/src/*.x.js`.
