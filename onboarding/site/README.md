# Onboarding site

The gleam-dream onboarding course as a Lustre application on the JavaScript
target, published with GitHub Pages. Requirements:
[issues/onboarding-site/PRD.md](../../issues/onboarding-site/PRD.md).

Build and test from this directory inside `nix develop`:

```bash
nix develop ../.. --command bash build.sh
```

```bash
nix develop ../.. --command gleam test
```

`build.sh` writes a self-contained static site to `dist/`: open
`dist/index.html` in a browser, or serve the directory with any static file
server. Every URL is relative, so the site works under a Pages subpath.

The Gleam code the course shows lives in `snippets/`, a small package that
must compile. `build.sh` regenerates `src/pages/gleam_lang/snippets.gleam`
from its `// region:` blocks. The compiler errors the course shows are
recorded by `snippets/capture.sh` from the deliberately broken variants in
`snippets/broken/`; rerun it after changing a snippet or the Gleam version.
