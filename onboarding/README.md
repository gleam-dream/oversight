# Onboarding site

An interactive onboarding course for the gleam-dream ecosystem, from the BEAM
to composed systems. The requirements and full context are in
[issues/onboarding-site/PRD.md](../issues/onboarding-site/PRD.md).

- `reference/` holds the working reference implementation: open
  `reference/site/index.html` in a browser. Rebuild it with
  `python3 reference/tools/site.py`. Browser checks are in `reference/check/`; set `SITE` to a file or HTTP
  URL to point them at another build.
- `site/` holds the Lustre application deployed to GitHub Pages; see its
  README to build and test it.
