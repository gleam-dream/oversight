// ─────────────────────────────────────────────────────────────
//  Booklet theme, shared by every booklet
//  Body: EB Garamond · Display/labels: IBM Plex Sans · Code: IBM Plex Mono
// ─────────────────────────────────────────────────────────────

#import "@preview/droplet:0.3.1": dropcap

// Palette ─ ink & paper with three semantic accents
#let ink       = rgb("#1c2431")
#let navy      = rgb("#1f3a5f")
#let navy-soft = rgb("#dfe6ef")
#let crash     = rgb("#c4452c")
#let crash-soft= rgb("#f7e0d8")
#let heal      = rgb("#2f7a5b")
#let heal-soft = rgb("#d9ebe1")
#let gold      = rgb("#b5852a")
#let gold-soft = rgb("#f3e8cf")
#let slate     = rgb("#6b778a")
#let mist      = rgb("#ece7dc")
#let paper     = rgb("#fcfaf5")
#let codebg    = rgb("#f5f1e8")

#let serif     = "EB Garamond 12"
#let initials  = "EB Garamond Initials"
#let sans      = "IBM Plex Sans"
#let sans-med  = "IBM Plex Sans Medm"
#let sans-semi = "IBM Plex Sans SmBld"
#let sans-cond = "IBM Plex Sans Cond SmBld"
#let mono      = "IBM Plex Mono"

#let number-words = ("Zero", "One", "Two", "Three", "Four", "Five", "Six",
  "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve")

// Small tracked sans label, used across the book
#let label-text(body, fill: slate, size: 6.3pt, tracking: 0.18em) = text(
  font: sans-semi, size: size, tracking: tracking, fill: fill, upper(body))

// ── Components ───────────────────────────────────────────────

// Opening paragraph of a chapter, with an ornamented initial
#let opening(body) = dropcap(
  height: 3, gap: 3pt, hanging-indent: 0pt, overhang: 0pt,
  font: initials, fill: navy, body)

// Numbered citation into Works Cited, e.g. #src(56) or #src(66, 69)
#let src(..ns) = super(text(font: sans-semi, fill: gold, size: 0.78em, tracking: 0.02em,
  number-type: "lining", "[" + ns.pos().map(str).join(", ") + "]"))

#let keyidea(title: "Key idea", body) = block(
  width: 100%, breakable: false, above: 1.3em, below: 1.3em,
  inset: (left: 12pt, right: 10pt, y: 9pt),
  fill: gold-soft.lighten(45%),
  stroke: (left: 2.2pt + gold),
  radius: (right: 3pt),
)[
  #label-text(title, fill: gold)
  #v(-0.35em)
  #set text(size: 0.95em)
  #set par(first-line-indent: 0pt)
  #body
]

#let pullquote(body) = block(width: 100%, above: 1.5em, below: 1.5em, inset: (x: 8pt))[
  #set par(justify: false, first-line-indent: 0pt, leading: 0.55em)
  #align(center)[
    #text(font: serif, size: 18pt, fill: gold)[❦]
    #v(-0.6em)
    #text(font: serif, style: "italic", size: 13.2pt, fill: navy, body)
  ]
]

#let capped = state("code-capped", false)
#let codefile(name, body) = block(above: 1.2em, below: 1.3em, breakable: true, {
  block(below: 0pt, sticky: true, inset: (x: 8pt, y: 4pt), fill: navy, radius: (top: 3pt),
    text(font: mono, size: 6.4pt, fill: paper, name))
  capped.update(true)
  body
  capped.update(false)
})

#let antipattern(title: none, pattern, consequence, fix) = {
  let row(mark, color, soft, name, body) = grid(
    columns: (20pt, 1fr), column-gutter: 8pt,
    align(center + top, box(width: 16pt, height: 16pt, radius: 8pt, fill: soft,
      align(center + horizon, text(font: sans-semi, size: 8pt, fill: color, mark)))),
    [#label-text(name, fill: color) #v(-0.4em) #body],
  )
  block(width: 100%, above: 1.2em, below: 1.4em, inset: 11pt, radius: 4pt, breakable: false,
    fill: paper, stroke: 0.6pt + mist.darken(8%))[
    #set par(first-line-indent: 0pt)
    #set text(size: 0.94em)
    #row("×", crash, crash-soft, "The anti-pattern", pattern)
    #v(0.2em)
    #row("!", gold, gold-soft, "The consequences", consequence)
    #v(0.2em)
    #row(text(font: "DejaVu Sans Mono")[✓], heal, heal-soft, "The fix", fix)
  ]
}

// Figure wrapper (diagrams are images)
#let fig(body, caption: none, placement: auto) = figure(
  kind: image, supplement: "Figure", placement: placement,
  block(width: 100%, inset: (y: 4pt), align(center, body)),
  caption: caption)

// ── Template ─────────────────────────────────────────────────

#let book(title: none, short-title: none, body) = {
  set document(title: title, author: "")

  set page(
    width: 152mm, height: 222mm,
    margin: (inside: 19mm, outside: 16mm, top: 21mm, bottom: 22mm),
    fill: paper,
    header: context {
      let p = here().page()
      let starts = query(heading.where(level: 1)).filter(h => h.location().page() == p)
      if starts.len() > 0 { return }
      let before = query(heading.where(level: 1).before(here()))
      if before.len() == 0 { return }
      let current = before.last()
      set text(font: sans, size: 6.2pt, fill: slate, tracking: 0.14em)
      if calc.even(p) {
        align(left, upper(short-title))
      } else {
        align(right, text(font: serif, size: 8.5pt, style: "italic", tracking: 0pt, current.body))
      }
      v(-1pt)
      line(length: 100%, stroke: 0.35pt + mist.darken(10%))
    },
    footer: context {
      let p = here().page()
      set text(font: sans-med, size: 7pt, fill: slate)
      let n = counter(page).display("1")
      if calc.even(p) { align(left, n) } else { align(right, n) }
    },
  )

  set text(font: serif, size: 10.8pt, fill: ink, lang: "en", hyphenate: true,
    number-type: "old-style", costs: (hyphenation: 80%, widow: 120%, orphan: 120%))
  set par(justify: true, leading: 0.64em, spacing: 0.64em,
    first-line-indent: (amount: 1.15em, all: false))

  show strong: it => text(fill: navy, smallcaps(it.body))
  show emph: set text(style: "italic")
  show link: set text(fill: navy)

  // Lists
  set list(indent: 0.4em, body-indent: 0.6em, spacing: 0.55em,
    marker: text(fill: gold, size: 0.8em, baseline: -0.1em)[◆])
  set enum(indent: 0.2em, body-indent: 0.6em, spacing: 0.65em,
    numbering: n => text(font: sans-semi, size: 0.78em, fill: gold, str(n) + "."))

  show list: set block(above: 0.8em, below: 0.9em)
  show enum: set block(above: 0.8em, below: 0.9em)
  show figure.where(kind: table): set align(left)

  // Code
  show raw: set text(font: mono)
  show raw.where(block: false): it => box(
    fill: mist.lighten(25%), inset: (x: 2.2pt), outset: (y: 2.2pt), radius: 1.6pt,
    text(size: 0.82em, number-type: "lining", it))
  set raw(theme: "beam.tmTheme")
  show raw.where(block: true): it => {
    set text(size: 7pt, number-type: "lining")
    set par(justify: false, leading: 0.62em, first-line-indent: 0pt)
    context { let c = capped.get()
    block(width: 100%, fill: codebg, inset: (left: 6pt, right: 9pt, y: 8pt),
      radius: if c { (bottom: 3pt, top-right: 3pt) } else { 3pt }, stroke: (left: 2pt + gold),
      above: if c { 0pt } else { 1.2em }, below: if c { 0pt } else { 1.3em }, breakable: true, {
        show raw.line: l => {
          box(width: 1.5em, align(right, text(fill: slate.lighten(35%), size: 0.86em, str(l.number))))
          h(1em)
          l.body
        }
        it
      }) }
  }

  // Tables
  set table(
    stroke: (x, y) => if y == 0 { none } else { (top: 0.4pt + mist.darken(12%)) },
    fill: (x, y) => if y == 0 { navy } else if calc.even(y) { mist.lighten(55%) } else { none },
    inset: (x: 5pt, y: 5pt),
    align: left + top,
  )
  show table: set text(font: sans, size: 6.8pt, number-type: "lining")
  show table: set par(justify: false, first-line-indent: 0pt, leading: 0.5em)
  show table.cell.where(y: 0): set text(fill: paper, font: sans-semi, size: 6.4pt, tracking: 0.06em)
  show table.cell: it => { show raw: r => text(fill: navy, r); it }

  // Figures
  set figure(gap: 0.9em,
    numbering: (..n) => numbering("1.1", counter(heading).get().first(), n.pos().first()))
  show figure: set block(breakable: false, above: 1.6em, below: 1.6em)
  show figure.caption: it => context {
    set par(justify: false, first-line-indent: 0pt, leading: 0.5em)
    block(width: 92%, text(font: sans, size: 6.9pt, fill: slate)[
      #text(font: sans-semi, fill: gold, tracking: 0.08em)[#upper(it.supplement) #it.counter.display(it.numbering)]
      #h(0.5em) #it.body])
  }
  show figure.where(kind: table): set figure.caption(position: top)

  // Headings
  set heading(numbering: "1.1")
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    counter(figure.where(kind: image)).update(0)
    counter(figure.where(kind: table)).update(0)
    set par(first-line-indent: 0pt, justify: false)
    v(10mm)
    block(width: 100%, height: 52mm, breakable: false, {
      if it.numbering != none {
        let n = counter(heading).get().first()
        place(top + right, dx: 2mm, dy: -10mm,
          text(font: serif, size: 120pt, fill: mist, number-type: "lining", str(n)))
        label-text("Chapter " + number-words.at(n), fill: gold, size: 6.8pt, tracking: 0.32em)
      } else {
        label-text("Coda", fill: gold, size: 6.8pt, tracking: 0.32em)
      }
      v(5mm)
      block(width: 82%, text(font: serif, size: 23pt, fill: navy, hyphenate: false,
        it.body))
      v(3mm)
      line(length: 16mm, stroke: 1.2pt + gold)
    })
  }
  show heading.where(level: 2): it => {
    set par(first-line-indent: 0pt, justify: false)
    block(above: 1.9em, below: 0.9em, sticky: true, {
      if it.numbering != none {
        text(font: sans-semi, size: 7.2pt, fill: gold, counter(heading).display("1.1"))
        h(0.7em)
      }
      text(font: sans-semi, size: 8.6pt, fill: navy, tracking: 0.02em, it.body)
    })
  }
  show heading.where(level: 3): it => block(above: 1.4em, below: 0.7em, sticky: true,
    text(font: serif, style: "italic", size: 11.5pt, fill: navy, it.body))

  // Outline
  show outline.entry.where(level: 1): it => {
    v(1.05em, weak: true)
    link(it.element.location(), grid(columns: (2.4em, 1fr, auto), align: (left, left, right),
      text(font: sans-semi, size: 7.5pt, fill: gold, baseline: -0.5pt, if it.prefix() != none { it.prefix() }),
      text(font: serif, size: 11pt, fill: navy, it.body()),
      text(font: sans-med, size: 7.5pt, fill: slate, it.page())))
  }
  show outline.entry.where(level: 2): it => {
    v(0.42em, weak: true)
    link(it.element.location(), grid(columns: (2.4em, 2.4em, 1fr, auto), align: (left, left, left, right),
      [],
      text(font: sans, size: 6.3pt, fill: slate, baseline: -0.5pt, it.prefix()),
      text(font: serif, size: 9pt, fill: ink, it.body() + box(width: 1fr, repeat(text(fill: mist.darken(25%))[#h(2.5pt).]))),
      text(font: sans, size: 6.8pt, fill: slate, h(3pt) + it.page())))
  }

  body
}
