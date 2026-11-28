# Booklets

Long-form reading published beside the onboarding course, as PDFs. Each
directory is one booklet, built from `main.typ`; `shared/` holds what every
booklet uses: the theme (`theme.typ`), the drawing vocabulary for cetz figures
(`drawing.typ`) and the code highlighting theme (`beam.tmTheme`).

Build every booklet into `result/<name>.pdf`:

```bash
nix build .#booklets
```

Write one with live rebuilds, from the repository root:

```bash
nix develop .#booklets --command typst watch --root booklets booklets/architecting-resilience/main.typ
```

A new booklet is a new directory with a `main.typ` that starts with
`#show: book.with(title: ..., short-title: ...)`, and an entry in the course's
`onboarding/site/src/site/booklets.gleam`.
