# Publish booklets as PDFs beside the course

<a id="adr-0045"></a>

Recorded on 2026-11-28.

## Decision

Long-form reading for the onboarding course is written as Typst booklets under
`booklets/`, one directory per booklet, sharing a theme in `booklets/shared/`.
Each booklet builds to one PDF. `nix build .#booklets` builds every booklet
offline, with Typst, its packages and the fonts from the pinned nixpkgs. The
Pages workflow publishes each booklet at `booklets/<slug>.pdf` beside the
course.

The course links a booklet and never embeds it. A module whose subject a
booklet covers in depth shows a "Further reading" card linking the PDF, and
the field guide's reading plan lists every booklet.

## Rationale and consequences

A web edition from Typst's experimental HTML export was tried and dropped.
Unchanged, the export lost every figure, the headings, the contents and the
reference list without an error. A theme that branched on the target recovered
them, with figures as inline SVG, but the page weighed about 2.6 MB against a
0.7 MB PDF, the export is marked as unstable, and every component needed a
second form to maintain. A PDF keeps one output to check.

Linking keeps the course and the booklets independent. The course is a Lustre
application with its own design and no code outside module 3; a booklet is a
long document with its own typography, and may use another language's code.
The modules carry the ideas, translated to gleam_otp and checked against it;
the booklet is there for a reader who wants the depth.
