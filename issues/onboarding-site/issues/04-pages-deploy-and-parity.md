# GitHub Pages deployment and parity checks

Status: ready-for-agent
Category: enhancement

Add a GitHub Actions workflow that builds `onboarding/site/` and deploys it
to GitHub Pages with `actions/upload-pages-artifact` and
`actions/deploy-pages`, on pushes to `main` that touch `onboarding/site/**`,
pinning Gleam and Erlang as `ci.yml` does. Use relative asset URLs so the site
works under a project subpath. Run the Playwright checks from
`onboarding/reference/check/` against the Lustre build and record the
results; then decide what happens to `onboarding/reference/`.
