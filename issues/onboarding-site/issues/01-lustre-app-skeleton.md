# Lustre application skeleton, shell and routing

Status: done
Category: enhancement

Create `onboarding/site/` as a Gleam project on the JavaScript target with
Lustre. Port the app shell from `onboarding/reference/tools/shell.html`:
app bar (brand, progress, Motion toggle, module menu), hash routing for the
twelve routes in the PRD, in-page anchor scrolling, done-marking with
`localStorage`, footer navigation, and the visual design tokens. Port the
course map (`#start`) with its six-layer stack.

Done when the course map and empty module pages render, routing and
done-marking work, and the visual design matches the reference.

## Comments

AI-assisted contribution. Built `onboarding/site/`, a Gleam project on the
JavaScript target with Lustre 5.7.1 (`playground/mobile_shells` does not exist
and nothing else in the repository uses Lustre, so the latest 5.x was chosen).
`build.sh` compiles it and bundles one minified script with esbuild into
`dist/` beside `index.html` and `style.css`; every URL is relative. The dev
shell gained `nodejs` (JavaScript tests) and `esbuild`, and treefmt now skips
`onboarding/reference/**` so the oracle stays verbatim.

State model, from the reader's flow: a `Route` is `CourseMap | Module(Module)`
with eleven module variants, so the course map can never be marked done; the
hash is the only source of route truth. `Progress` is a set of modules stored
as the reference's `{"<slug>": 1}` object under the same key, decoded at the
boundary (unknown keys dropped). `Motion` is `On | Off`, starting from the
remembered choice or the system's reduced-motion setting. The menu is
`MenuClosed | MenuOpen`. Every page keeps its own model for the whole visit;
leaving a page pauses its tours. Fit-to-screen zooms are observed facts the
shell owns, keyed by playground. Browser access is one FFI module: storage,
`matchMedia`, location, timers, scrolling, measurement and the shared
animation-frame loop.

Ported: app bar (brand, progress bar and count, Motion toggle with
`aria-pressed`, module menu), hash routing with document titles, scroll to top
and focus on navigation, the module footer (done toggle, previous and next
cards, source line), the visual design tokens and shared CSS, and the course
map with its six-layer stack. The eleven modules are stubs with the final page
interface. In-page anchors are links whose click scrolls without changing the
hash (`ui.jump`), so a reload still lands on the module.

Intentional difference: the reference writes the motion setting on every
boot; the port stores it only when the reader toggles it, so the system
setting keeps applying until the reader chooses.

Checks run:

- `nix develop --command gleam test` in `onboarding/site`: 34 passed (routes,
  progress storage, motion, fit, tour transitions, course-map tour).
- `nix develop --command bash build.sh`: 104 KB script.
- `SITE=file://…/site/dist/index.html python3 tours.py start` (Playwright
  1.58, Chromium 145): `tours=1 tourClicks=7 free=1 freeClicks=6 holes=0
errs=0`, the same as the reference.
- `zoom.py`: course map 80% at 1366×768 and 95% at 1440×900, the same as the
  reference.
- Screenshots of the course map top and the stack playground at 1440×900 are
  byte-identical to the reference.
- A scripted shell check: titles, footer, done toggle and storage, menu
  open/close on navigation, motion toggle, persistence across reload, footer
  hidden on the course map; no page errors.
