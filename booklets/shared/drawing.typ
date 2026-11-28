// ─────────────────────────────────────────────────────────────
//  Drawing vocabulary shared by every booklet's figures
// ─────────────────────────────────────────────────────────────
#import "@preview/cetz:0.4.2"
#import "theme.typ": *

// ── Shared vocabulary ────────────────────────────────────────

#let S(state) = (
  ok:    (fill: navy-soft, stroke: navy,  text: navy),
  crash: (fill: crash-soft, stroke: crash, text: crash),
  heal:  (fill: heal-soft, stroke: heal,  text: heal),
  off:   (fill: mist,      stroke: slate, text: slate),
  sup:   (fill: gold-soft, stroke: gold,  text: ink),
  dark:  (fill: navy,      stroke: navy,  text: paper),
  ghost: (fill: paper,     stroke: slate, text: slate),
).at(state)

#let stk(state, w: 0.7pt) = {
  let s = S(state)
  if state in ("off", "ghost") { (paint: s.stroke, thickness: w, dash: "densely-dashed") }
  else { (paint: s.stroke, thickness: w) }
}

#let t(body, size: 5.6pt, fill: ink, font: sans, ..args) = text(
  font: font, size: size, fill: fill, number-type: "lining", hyphenate: false, ..args, body)
#let tb(body, size: 5.6pt, fill: ink) = t(body, size: size, fill: fill, font: sans-semi)
#let ti(body, size: 5.6pt, fill: slate) = t(body, size: size, fill: fill, style: "italic")
#let tm(body, size: 5.2pt, fill: navy) = text(font: mono, size: size, fill: fill, body)

#let arrow-mark(c) = (end: "stealth", fill: c, scale: 0.5)

// Worker process: a circle
#let pnode(name, pos, body, state: "ok", r: 0.24, size: 5.4pt) = {
  import cetz.draw: *
  let s = S(state)
  circle(pos, radius: r, fill: s.fill, stroke: stk(state), name: name)
  content(pos, tb(body, size: size, fill: s.text))
}

// Supervisor: a rounded rectangle centred at pos
#let snode(name, pos, body, w: 1.4, h: 0.4, state: "sup", size: 5.4pt) = {
  import cetz.draw: *
  let (x, y) = pos
  let s = S(state)
  rect((x - w / 2, y - h / 2), (x + w / 2, y + h / 2), radius: 0.07,
    fill: s.fill, stroke: stk(state), name: name)
  content(pos, tb(body, size: size, fill: s.text))
}

#let tie(a, b, stroke: 0.55pt + slate.lighten(25%)) = cetz.draw.line(
  a + ".south", b + ".north", stroke: stroke)

#let envelope(pos, w: 0.3, h: 0.2, fill: paper, stroke: 0.5pt + gold) = {
  let paint = fill
  let pen = stroke
  import cetz.draw: *
  let (x, y) = pos
  rect((x - w / 2, y - h / 2), (x + w / 2, y + h / 2), fill: paint, stroke: pen)
  line((x - w / 2, y + h / 2), (x, y - h / 8), (x + w / 2, y + h / 2), stroke: pen)
}

#let padlock(pos, c: crash) = {
  import cetz.draw: *
  let (x, y) = pos
  arc((x, y + 0.06), start: 0deg, stop: 180deg, radius: 0.07, anchor: "origin",
    stroke: 0.7pt + c)
  rect((x - 0.1, y - 0.08), (x + 0.1, y + 0.06), radius: 0.02, fill: c, stroke: none)
}

// Legend swatches (plain Typst, used under figures)
#let sw(state, shape: "circle") = {
  let s = S(state)
  let st = if state in ("off", "ghost") { (paint: s.stroke, thickness: 0.6pt, dash: "densely-dashed") } else { 0.6pt + s.stroke }
  if shape == "rect" { box(width: 10pt, height: 6.5pt, radius: 1.5pt, fill: s.fill, stroke: st, baseline: 1pt) }
  else { box(width: 7.5pt, height: 7.5pt, radius: 3.75pt, fill: s.fill, stroke: st, baseline: 1.3pt) }
}
#let legend(..items) = block(above: 0.8em, {
  set text(font: sans, size: 5.8pt, fill: slate, number-type: "lining")
  items.pos().map(((s, label)) => box[#s#h(3pt)#label]).join(h(11pt))
})

// ═════════════════════════════════════════════════════════════
//  COVER ART
// ═════════════════════════════════════════════════════════════

