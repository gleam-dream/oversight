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
