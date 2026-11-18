# Lustre application skeleton, shell and routing

Status: ready-for-agent
Category: enhancement

Create `onboarding/site/` as a Gleam project on the JavaScript target with
Lustre. Port the app shell from `onboarding/reference/tools/shell.html`:
app bar (brand, progress, Motion toggle, module menu), hash routing for the
twelve routes in the PRD, in-page anchor scrolling, done-marking with
`localStorage`, footer navigation, and the visual design tokens. Port the
course map (`#start`) with its six-layer stack.

Done when the course map and empty module pages render, routing and
done-marking work, and the visual design matches the reference.
