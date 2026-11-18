You are working in the Oversight repository of the gleam-dream ecosystem. Your task: rebuild the gleam-dream onboarding site as a Lustre application in `onboarding/site/` and deploy it to GitHub Pages, with behaviour parity to the working reference implementation in `onboarding/reference/`.

Read these first, in order, before writing any code:

1. `AGENTS.md`: repository rules (Nix shell, formatting, validation, the local `issues/` tracker and its labels).
2. `issues/onboarding-site/PRD.md`: the full requirements, content facts, honesty labels, interaction design, visual design and validation.
3. `issues/onboarding-site/issues/01-…` to `04-…`: the work, in order.
4. `onboarding/reference/`: the behaviour oracle. Open `site/index.html` in a browser and click through every module and tour before you start. Module logic is in `src/<Module>.js` plus `src/<Module>.x.js` (tours, real-time widgets, ladder views); markup is in `src/<Module>.html`; the runtime (template engine, router, tours, fit-to-screen, sequence-chart layout, seeded RNG, motion toggle, live animation loop) is in `tools/shell.html`.

How to build it:

- Gleam on the JavaScript target with Lustre 5.x; match the Lustre version already used under `playground/mobile_shells`. Work inside `nix develop`. If the shell lacks something the JavaScript build needs, say what and propose the smallest flake change rather than working around it.
- Model every simulation with custom types (job states, saga steps, decision phases, tour state) and pure update functions, and test them with gleeunit on the JavaScript target. Keep FFI to browser APIs only: `requestAnimationFrame`, `matchMedia`, `localStorage`, scrolling and element measurement.
- The real-time widgets (send vs call mailbox, Sinal pipeline, Grind queue) run on one animation loop and must not re-render the whole application every frame.
- Keep the content, the tour wording and the honesty labels exactly as in the reference unless the PRD says otherwise. No code listings in course content, and no quizzes.
- Re-verify the package facts in the PRD against the current sibling repositories on GitHub, read only. Do not modify any other repository. List every discrepancy you find instead of silently changing content.
- Use the hash routes from the PRD and relative asset URLs, so the site works under a GitHub Pages project subpath.
- Add `.github/workflows/onboarding-pages.yml`: build `onboarding/site/` and deploy with `actions/upload-pages-artifact` and `actions/deploy-pages` on pushes to `main` that touch `onboarding/site/**`, pinning Gleam and Erlang the same way `ci.yml` does.

How to work:

- Go issue by issue, 01 to 04. At the end of each, update its `Status:` line and append a `## Comments` entry that starts with `AI-assisted contribution.` and says what you built and exactly which checks you ran.
- After each issue run `gleam test`, the build, and the relevant Playwright checks from `onboarding/reference/check/` pointed at your build output. For tours, take screenshots at 1366×768 and 1440×900 and compare them with the reference.
- Format changed files with `nix fmt -- PATH...` and run `nix flake check` before you finish.
- Commit per issue with conventional messages in the style of the repository history (for example `feat(onboarding): port the guided tours`). Do not push, change repository settings, or remove `onboarding/reference/` without asking me first. Tell me when the Pages source must be switched to "GitHub Actions" in the repository settings.

Finish with: how to run the site locally, the deploy workflow, a parity report per module (what matches, what differs and why), and the fact discrepancies you found.
