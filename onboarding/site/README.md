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

Browser checks (Python Playwright) are in `check/` and run against
`dist/index.html`; set `SITE` to another file or an HTTP URL:

```bash
python3 check/tours.py start,beam,otp,gleam,principles,atlas,foundations,outside-world,durable-work,agents,compose,field-guide
```

`zoom.py` reports the fit-to-screen zoom per playground at 1366×768 and
1440×900, `still2.py` checks motion-off mode, `mob.py` takes phone-width
screenshots and `play.py <route> <lab> <ms> <out.png> <w> <h>` plays a tour
and screenshots the viewport. Output goes to `check/out/`.
