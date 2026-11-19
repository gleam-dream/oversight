# Gleam module: compiled snippets and pattern matching

Status: done
Category: enhancement

Show readers the Gleam behind module 3's playgrounds: the data structures as
highlighted code beside each playground, and pattern matching as its own
playground, including exhaustiveness. Every snippet the site shows must
compile, so a change to Gleam or to a snippet fails the build instead of
leaving stale code on the page.

## Comments

AI-assisted contribution. Built:

- `onboarding/site/snippets/`, a small Gleam package (Erlang target) holding
  every snippet the course shows between `// region:` markers, with a test
  that pins what `describe` returns for each sample value. `capture.sh`
  records the compiler's real output for the deliberately broken variants in
  `snippets/broken/` (an `Order` with `Disputed` added, the `describe`
  function without its `Paid(items: [])` arm, and a `"hello"` sent to the
  cart). `generate.py` writes the regions and recorded outputs into
  `src/pages/gleam_lang/snippets.gleam`; `build.sh` compiles the package and
  regenerates it, and the Pages workflow runs the snippet tests, recaptures
  and fails if the committed files are stale. The workflow now also runs its
  checks (not the deploy) on pull requests that touch the site.
- `site/code.gleam`, a small Gleam tokenizer (keywords, types and
  constructors, functions, field labels, strings, numbers, comments,
  operators) rendered as spans, with line marks for playgrounds that point at
  code, and the compiler's output with its error line in red. No highlighting
  library.
- Module 3: the loose record and the `Order` type under each side of
  "impossible states" (the selected variant's line lit); the real
  inexhaustive-patterns error once Disputed is added; the `checkout`
  pipeline under the Result railway, with the failing step's line red and the
  skipped ones faded; the `CartMessage` type and, after sending `"hello"`, the
  real type-mismatch error.
- A new playground, "Pattern matching, arm by arm" (tour `match`, eight
  steps): pick a value and the case expression shows each arm tried from the
  top (passed over, guard false, matched, not reached), what the matching arm
  binds and what `describe` returns. Deleting the `Paid(items: [])` arm makes
  the program not compile, for every value, and shows the compiler naming the
  missing pattern. The model (`pages/gleam_lang/matching.gleam`) is pure and
  tested against the same answers as the compiled function.

Checks run: `gleam test` in `onboarding/site/snippets` (1 passed) and in
`onboarding/site` (289 passed); `bash build.sh`; `actionlint` on the
workflow; the old Playwright tour check on the gleam, beam and start routes
(all tours reach free play, no holes, no page errors); zoom at 1366×768 is
75% or more for every Gleam playground and 90% or more at 1440×900;
screenshots of every Gleam playground in its new states.
