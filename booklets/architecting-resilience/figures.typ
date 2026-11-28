// ─────────────────────────────────────────────────────────────
//  Figures: every diagram, chart, and drawing in the booklet
// ─────────────────────────────────────────────────────────────
#import "@preview/cetz:0.4.2"
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "../shared/theme.typ": *
#import "../shared/drawing.typ": *

#let cover-art() = cetz.canvas(length: 1mm, {
  import cetz.draw: *
  // deterministic star field
  let seed = 7
  for i in range(140) {
    seed = calc.rem(seed * 1103515245 + 12345, 2147483648)
    let x = calc.rem(seed, 1520) / 10
    seed = calc.rem(seed * 1103515245 + 12345, 2147483648)
    let y = calc.rem(seed, 1300) / 10
    seed = calc.rem(seed * 1103515245 + 12345, 2147483648)
    let r = 0.12 + calc.rem(seed, 30) / 100
    circle((x, y), radius: r, fill: paper.transparentize(55% + calc.rem(i, 4) * 10%), stroke: none)
  }
  // the tree
  let glow(p, r, c) = {
    for k in range(4) {
      circle(p, radius: r + (4 - k) * 1.1, fill: c.transparentize(88% + k * 2%), stroke: none)
    }
  }
  let root = (76, 112)
  let l1 = ((38, 84), (76, 84), (114, 84))
  let l2 = (
    ((18, 56), (34, 56), (50, 56)),
    ((66, 56), (86, 56)),
    ((102, 56), (118, 56), (134, 56)),
  )
  let edge-st = 0.5pt + gold.lighten(20%).transparentize(30%)
  for (i, p) in l1.enumerate() {
    line(root, p, stroke: edge-st)
    for q in l2.at(i) { line(p, q, stroke: edge-st) }
  }
  glow(root, 3.2, gold)
  circle(root, radius: 3.2, fill: gold, stroke: none)
  for (i, p) in l1.enumerate() {
    glow(p, 2.4, gold)
    rect((p.at(0) - 2.6, p.at(1) - 2.0), (p.at(0) + 2.6, p.at(1) + 2.0), radius: 0.8, fill: gold.lighten(15%), stroke: none)
    for (j, q) in l2.at(i).enumerate() {
      let crashed = i == 1 and j == 1
      let c = if crashed { crash.lighten(10%) } else { rgb("#9fb6d4") }
      glow(q, 1.8, c)
      circle(q, radius: 1.8, fill: c, stroke: none)
      if crashed {
        // a restart arc beside the crashed child
        arc((q.at(0), q.at(1)), start: 30deg, stop: 300deg, radius: 4.6, anchor: "origin",
          stroke: 0.7pt + heal.lighten(35%), mark: (end: "stealth", fill: heal.lighten(35%), scale: 0.6))
      }
    }
  }
  // orbit hint around root
  circle(root, radius: 9, stroke: (paint: gold.transparentize(60%), thickness: 0.4pt, dash: "dotted"))
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 1 — The process
// ═════════════════════════════════════════════════════════════

#let fig-isolation() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // ── Left: threads sharing memory
  content((2.6, 4.3), tb("Threads · shared memory", size: 6.4pt, fill: crash))
  rect((0.25, 0.25), (4.95, 1.65), radius: 0.12, fill: crash-soft.lighten(30%), stroke: 0.7pt + crash.lighten(30%))
  content((0.45, 0.47), ti("! race · no lock", fill: crash), anchor: "west")
  content((2.6, 0.47), ti("locked · the other waits", fill: crash), anchor: "west")
  let blocks = ((0.7, 1.05), (1.75, 1.05), (2.8, 1.05), (3.85, 1.05))
  for b in blocks {
    rect((b.at(0) - 0.32, b.at(1) - 0.24), (b.at(0) + 0.32, b.at(1) + 0.24), radius: 0.05, fill: paper, stroke: 0.5pt + slate)
  }
  padlock((2.8 + 0.32, 1.05 + 0.3))
  let threads = (0.7, 1.9, 3.1, 4.3)
  let targets = (0, 0, 2, 2)
  for (i, x) in threads.enumerate() {
    rect((x - 0.32, 3.15), (x + 0.32, 3.6), radius: 0.06, fill: navy-soft, stroke: 0.6pt + navy)
    content((x, 3.375), tb("T" + str(i + 1), fill: navy))
    let b = blocks.at(targets.at(i))
    line((x, 3.12), (b.at(0), b.at(1) + 0.28), stroke: 0.55pt + slate, mark: arrow-mark(slate))
  }
  // race spark
  circle((0.7 + 0.32, 1.05 + 0.3), radius: 0.12, fill: crash, stroke: none)
  content((0.7 + 0.32, 1.05 + 0.3), tb("!", size: 5.4pt, fill: paper))
  content((2.6, 3.95), ti("one shared heap, many threads", fill: crash))

  // divider
  line((5.55, 0.2), (5.55, 4.3), stroke: (paint: mist.darken(15%), thickness: 0.5pt, dash: "dotted"))

  // ── Right: BEAM processes, shared nothing
  content((8.8, 4.3), tb("BEAM · shared nothing", size: 6.4pt, fill: heal))
  content((8.8, 3.95), ti("each process owns its memory", fill: heal))
  let cells = ((6.15, 2.25), (9.15, 2.25), (6.15, 0.2), (9.15, 0.2))
  let names = ("<0.110.0>", "<0.111.0>", "<0.112.0>", "<0.113.0>")
  for (i, c) in cells.enumerate() {
    let (x, y) = c
    rect((x, y), (x + 2.3, y + 1.55), radius: 0.12, fill: paper, stroke: 0.7pt + navy)
    content((x + 0.12, y + 1.4), tm(names.at(i), size: 4.8pt), anchor: "north-west")
    // mailbox slots
    for k in range(3) {
      rect((x + 1.25 + k * 0.32, y + 1.12), (x + 1.53 + k * 0.32, y + 1.38), radius: 0.03,
        fill: if k < (i + 1) { gold-soft } else { paper }, stroke: 0.4pt + gold)
    }
    let strips = (("stack", navy-soft), ("heap", heal-soft), ("own GC", mist))
    for (k, (label, fill)) in strips.enumerate() {
      let yy = y + 0.78 - k * 0.27
      rect((x + 0.15, yy), (x + 2.15, yy + 0.22), radius: 0.03, fill: fill, stroke: none)
      content((x + 0.25, yy + 0.11), t(label, size: 4.8pt, fill: ink.lighten(20%)), anchor: "west")
    }
  }
  // messages between cells
  line((8.48, 3.05), (9.12, 3.05), stroke: 0.6pt + gold, mark: arrow-mark(gold))
  envelope((8.8, 3.3))
  line((10.3, 2.22), (10.3, 1.78), stroke: 0.6pt + gold, mark: arrow-mark(gold))
  envelope((10.62, 2.0))
  line((7.3, 1.78), (7.3, 2.22), stroke: 0.6pt + gold, mark: arrow-mark(gold))
  envelope((6.98, 2.0))
  content((8.8, -0.1), ti("messages are copied between heaps", fill: heal), anchor: "north")
  content((2.6, -0.1), ti("state is shared, access must be coordinated", fill: crash), anchor: "north")
})

#let fig-mailbox() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // sender
  circle((0.7, 1.2), radius: 0.55, fill: navy-soft, stroke: 0.8pt + navy, name: "a")
  content((0.7, 1.2), tb("Sender", fill: navy))
  // in-flight message
  line((1.3, 1.2), (3.6, 1.2), stroke: 0.7pt + gold, mark: arrow-mark(gold))
  envelope((2.4, 1.48), w: 0.36, h: 0.24)
  content((2.45, 0.85), tm("send(pid, msg)"), anchor: "north")
  content((2.45, 0.55), ti("returns immediately"), anchor: "north")
  // mailbox tray
  rect((3.75, 0.75), (7.35, 1.65), radius: 0.12, fill: gold-soft.lighten(40%), stroke: 0.7pt + gold)
  content((5.55, 1.95), tb("mailbox · arrival order", fill: gold))
  let msgs = ("m4", "m3", "m2", "m1")
  for (i, m) in msgs.enumerate() {
    let x = 4.25 + i * 0.85
    envelope((x, 1.2), w: 0.5, h: 0.34, fill: if i == 0 { paper } else { gold-soft })
    content((x, 0.92), tm(m, size: 4.8pt, fill: gold.darken(20%)))
  }
  // receiver
  line((7.4, 1.2), (8.55, 1.2), stroke: 0.7pt + navy, mark: arrow-mark(navy))
  circle((9.25, 1.2), radius: 0.65, fill: navy-soft, stroke: 0.8pt + navy)
  content((9.25, 1.32), tb("Receiver", fill: navy))
  content((9.25, 1.06), tm("receive", size: 4.6pt))
  content((9.25, 0.4), ti("one message at a time,"), anchor: "north")
  content((9.25, 0.13), ti("at its own pace"), anchor: "north")
})

// Log-scale bar charts: memory per unit and practical concurrency
#let chart-footprint() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let log(v) = calc.log(v, base: 10)
  // Panel A — memory per concurrent unit (bytes, log axis 10^3 .. 10^7)
  let x0 = 2.6
  let w = 7.3
  let lo = 3
  let hi = 7.2
  let X(v) = x0 + (log(v) - lo) / (hi - lo) * w
  content((0, 3.75), tb("A · Memory reserved per concurrent unit", size: 6.2pt, fill: navy), anchor: "west")
  let rows = (
    ("BEAM process", "initial heap + stack", 2616, heal, "≈ 2.6 KB"),
    ("OS thread", "default stack reservation", 8388608, crash, "≈ 8 MB"),
  )
  line((x0, 1.6), (x0 + w, 1.6), stroke: 0.5pt + slate)
  for (e, l) in ((3, "1 KB"), (4, "10 KB"), (5, "100 KB"), (6, "1 MB"), (7, "10 MB")) {
    let x = x0 + (e - lo) / (hi - lo) * w
    line((x, 1.6), (x, 1.53), stroke: 0.5pt + slate)
    line((x, 1.62), (x, 3.3), stroke: (paint: mist.darken(5%), thickness: 0.4pt, dash: "dotted"))
    content((x, 1.43), t(l, size: 4.8pt, fill: slate), anchor: "north")
  }
  for (i, (name, sub, v, c, lab)) in rows.enumerate() {
    let y = 3.05 - i * 0.62
    content((x0 - 0.15, y + 0.08), tb(name), anchor: "east")
    content((x0 - 0.15, y - 0.14), ti(sub, size: 4.8pt), anchor: "east")
    rect((x0, y - 0.19), (X(v), y + 0.19), fill: c.transparentize(20%), stroke: none, radius: (east: 0.04))
    content((X(v) + 0.1, y), tb(lab, fill: c), anchor: "west")
  }
  // ratio bracket
  let ya = 3.45
  line((X(2616), ya), (X(8388608), ya), stroke: 0.5pt + gold, mark: (start: "stealth", end: "stealth", fill: gold, scale: 0.4))
  content(((X(2616) + X(8388608)) / 2, ya + 0.14), tb("≈ 3,000 ×", fill: gold), anchor: "south")

  // Panel B — practical concurrency on one machine (log axis 10^0 .. 10^7)
  let yb = 0.75
  content((0, yb), tb("B · Concurrent units practical on one machine", size: 6.2pt, fill: navy), anchor: "west")
  let lo2 = 0
  let hi2 = 7
  let X2(e) = x0 + (e - lo2) / (hi2 - lo2) * w
  let ranges = (
    ("OS threads", 3, 5, crash, "10³ – 10⁵"),
    ("BEAM processes", 5, 6.02, heal, "up to the limit; +P raises it"),
  )
  let ya2 = yb - 1.95
  line((x0, ya2), (x0 + w, ya2), stroke: 0.5pt + slate)
  let ticks = ("1", "10", "100", "1k", "10k", "100k", "1M", "10M")
  for e in range(0, 8) {
    let x = X2(e)
    line((x, ya2), (x, ya2 - 0.07), stroke: 0.5pt + slate)
    line((x, ya2 + 0.02), (x, yb - 0.35), stroke: (paint: mist.darken(5%), thickness: 0.4pt, dash: "dotted"))
    content((x, ya2 - 0.12), t(ticks.at(e), size: 4.8pt, fill: slate), anchor: "north")
  }
  // default +P limit marker
  let xp = X2(log(1048576))
  line((xp, ya2), (xp, yb - 0.35), stroke: (paint: gold, thickness: 0.6pt, dash: "dashed"))
  content((xp - 0.06, yb - 0.38), t("default limit 1,048,576", size: 4.6pt, fill: gold), anchor: "north-east")
  for (i, (name, a, b, c, lab)) in ranges.enumerate() {
    let y = yb - 0.85 - i * 0.55
    content((x0 - 0.15, y), tb(name), anchor: "east")
    rect((X2(a), y - 0.17), (X2(b), y + 0.17), radius: 0.17, fill: c.transparentize(25%), stroke: none)
    content((X2(b) + 0.1, y), ti(lab, fill: c), anchor: "west")
  }
})

#let fig-let-it-crash() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // a "page of code": h = happy-path line, d = defensive line
  let page(x, y, pattern, title, sub, c) = {
    rect((x, y), (x + 3.3, y + 3.6), radius: 0.1, fill: paper, stroke: 0.6pt + mist.darken(20%))
    content((x + 1.65, y + 3.85), tb(title, size: 6.2pt, fill: c))
    for (i, kind) in pattern.clusters().enumerate() {
      let yy = y + 3.3 - i * 0.22
      let (ind, len, fill) = if kind == "h" { (0.25, 2.1, navy.lighten(25%)) }
        else if kind == "d" { (0.55, 1.75, crash.lighten(45%)) }
        else { (0.8, 1.2, crash.lighten(60%)) }
      rect((x + ind, yy - 0.055), (x + ind + len - calc.rem(i * 7, 5) * 0.12, yy + 0.055), radius: 0.05, fill: fill, stroke: none)
    }
    content((x + 1.65, y - 0.22), ti(sub, fill: c), anchor: "north")
  }
  page(0, 0, "hddehdddhdeehdd", "Defensive programming", "the happy path is buried", crash)
  page(4.6, 0, "hhhhhhh", "Let it crash", "the happy path is the code", heal)
  // supervisor beside the clean page
  rect((8.7, 2.3), (10.9, 2.9), radius: 0.08, fill: gold-soft, stroke: 0.7pt + gold)
  content((9.8, 2.6), tb("Supervisor"))
  bezier((8.68, 2.55), (7.95, 1.9), (8.3, 2.55), (8.1, 2.3), stroke: 0.7pt + crash, mark: (start: "stealth", fill: crash, scale: 0.5))
  content((8.6, 1.95), t("exit signal", size: 4.8pt, fill: crash), anchor: "west")
  bezier((9.8, 2.28), (7.95, 0.9), (9.8, 1.2), (8.6, 0.9), stroke: 0.7pt + heal, mark: (end: "stealth", fill: heal, scale: 0.5))
  content((9.25, 1.05), t("restart into a", size: 4.8pt, fill: heal), anchor: "west")
  content((9.25, 0.82), t("known-good state", size: 4.8pt, fill: heal), anchor: "west")
  // legend
  rect((0.1, -0.9), (0.45, -0.8), radius: 0.05, fill: navy.lighten(25%), stroke: none)
  content((0.55, -0.85), t("business logic", size: 5pt, fill: slate), anchor: "west")
  rect((2.2, -0.9), (2.55, -0.8), radius: 0.05, fill: crash.lighten(45%), stroke: none)
  content((2.65, -0.85), t("try / rescue / guard clauses", size: 5pt, fill: slate), anchor: "west")
})

// Three primitives: link, monitor, trap_exit
#let fig-primitives() = {
  let panel(title, body, note) = box(width: 100%, {
    align(center, tb(title, size: 6.4pt, fill: navy))
    v(-2pt)
    align(center, body)
    v(-2pt)
    block(width: 100%, inset: (x: 4pt), align(center, {
      set par(justify: false, leading: 0.45em, first-line-indent: 0pt)
      note
    }))
  })
  let A-B(left-state, right-state, connector, left-label: "A", right-label: "B", left-sup: false) = cetz.canvas(length: 1cm, {
    import cetz.draw: *
    if left-sup {
      snode("a", (0.5, 0.5), left-label, w: 0.95, h: 0.42, state: left-state, size: 5pt)
    } else {
      pnode("a", (0.5, 0.5), left-label, state: left-state, r: 0.3)
    }
    pnode("b", (2.9, 0.5), right-label, state: right-state, r: 0.3)
    connector
    // crash mark on B
    content((2.9, 0.95), tb("× exits", size: 4.8pt, fill: crash), anchor: "south")
  })
  grid(columns: 3, column-gutter: 0pt,
    panel("Link",
      A-B("crash", "crash", {
        import cetz.draw: *
        line((0.82, 0.5), (2.58, 0.5), stroke: 1pt + crash.lighten(20%), mark: (start: "stealth", end: "stealth", fill: crash, scale: 0.5))
        content((1.7, 0.66), tm("spawn_link", size: 4.6pt, fill: crash), anchor: "south")
        content((1.7, 0.3), t("exit signal", size: 4.6pt, fill: crash), anchor: "north")
      }),
      ti("bidirectional · an abnormal exit kills the partner", size: 5.2pt)),
    panel("Monitor",
      A-B("ok", "crash", {
        import cetz.draw: *
        line((0.82, 0.58), (2.58, 0.58), stroke: (paint: navy, thickness: 0.7pt, dash: "dashed"), mark: (end: "stealth", fill: navy, scale: 0.5))
        line((2.6, 0.4), (0.84, 0.4), stroke: 0.7pt + heal, mark: (end: "stealth", fill: heal, scale: 0.5))
        content((1.7, 0.7), tm("Process.monitor", size: 4.6pt), anchor: "south")
        content((1.7, 0.28), tm("{:DOWN, ref, …}", size: 4.6pt, fill: heal), anchor: "north")
      }),
      ti("unidirectional · the observer just gets a message", size: 5.2pt)),
    panel("Trapping exits",
      A-B("sup", "crash", left-label: "trap_exit", left-sup: true, {
        import cetz.draw: *
        line((0.99, 0.5), (2.58, 0.5), stroke: 1pt + gold, mark: (start: "stealth", fill: gold, scale: 0.5))
        content((1.8, 0.66), tm("link", size: 4.6pt, fill: gold), anchor: "south")
        content((1.8, 0.3), tm("{:EXIT, pid, why}", size: 4.6pt, fill: heal), anchor: "north")
      }),
      ti("the signal becomes an ordinary mailbox message", size: 5.2pt)),
  )
}

// Sequence: the fault-tolerance kernel at work
#let fig-kernel() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let lanes = ((1.2, "Worker", "#PID<0.210.0>", "ok"), (5.6, "Supervisor", "trap_exit: true", "sup"), (10, "New worker", "#PID<0.233.0>", "heal"))
  for (x, name, sub, st) in lanes {
    let s = S(st)
    rect((x - 0.85, 4.3), (x + 0.85, 4.85), radius: 0.08, fill: s.fill, stroke: 0.7pt + s.stroke)
    content((x, 4.66), tb(name, fill: s.text))
    content((x, 4.44), tm(sub, size: 4.4pt, fill: s.text))
  }
  // lifelines
  line((1.2, 4.3), (1.2, 2.95), stroke: (paint: slate, thickness: 0.5pt, dash: "dashed"))
  line((5.6, 4.3), (5.6, -0.2), stroke: (paint: slate, thickness: 0.5pt, dash: "dashed"))
  line((10, 4.3), (10, 1.05), stroke: (paint: mist.darken(20%), thickness: 0.5pt, dash: "dotted"))
  line((10, 1.05), (10, -0.2), stroke: (paint: slate, thickness: 0.5pt, dash: "dashed"))
  // activation bars
  rect((1.12, 4.1), (1.28, 2.95), fill: navy.lighten(20%), stroke: none)
  rect((5.52, 4.1), (5.68, -0.1), fill: gold.lighten(10%), stroke: none)
  rect((9.92, 1.05), (10.08, -0.1), fill: heal, stroke: none)
  // crash
  content((1.2, 2.82), tb("×", size: 9pt, fill: crash))
  let step(n, pos) = {
    circle(pos, radius: 0.16, fill: gold, stroke: none)
    content(pos, tb(str(n), size: 5pt, fill: paper))
  }
  step(1, (0.6, 2.82))
  content((1.45, 2.9), t("crashes on an unexpected state", size: 5pt, fill: crash), anchor: "west")
  // exit signal
  line((1.3, 2.4), (5.5, 2.4), stroke: 0.8pt + crash, mark: arrow-mark(crash))
  step(2, (1.65, 2.12))
  content((1.9, 2.12), t("exit signal travels across the link", size: 5pt, fill: crash), anchor: "west")
  // message in mailbox
  step(3, (6.05, 2.4))
  rect((6.3, 2.15), (8.95, 2.62), radius: 0.06, fill: gold-soft, stroke: 0.5pt + gold)
  content((7.62, 2.39), tm("{:EXIT, pid, reason}", size: 5pt, fill: ink))
  content((7.62, 2.05), t("arrives as a plain message", size: 4.8pt, fill: slate), anchor: "north")
  // consult
  step(4, (6.05, 1.45))
  content((6.3, 1.45), t("consults child spec + strategy", size: 5pt), anchor: "west")
  // restart
  line((5.7, 0.95), (9.9, 0.95), stroke: 0.8pt + heal, mark: arrow-mark(heal))
  step(5, (7.8, 0.68))
  content((7.8, 1.08), tm("start_link from :start", size: 4.8pt, fill: heal), anchor: "south")
  step(6, (10.45, 0.5))
  content((10.65, 0.5), t("init/1 →", size: 5pt, fill: heal), anchor: "west")
  content((10.65, 0.26), t("known state", size: 5pt, fill: heal), anchor: "west")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 2 — The supervisor and the tree
// ═════════════════════════════════════════════════════════════

#let fig-order() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let chips = ("MyApp.Repo", "Phoenix.PubSub", "MyApp.Cache", "MyAppWeb.Endpoint")
  let row(y, order, c, title, note) = {
    content((0, y + 0.62), tb(title, size: 6.2pt, fill: c), anchor: "west")
    for (i, k) in order.enumerate() {
      let x = 0.05 + i * 2.9
      rect((x, y - 0.24), (x + 2.5, y + 0.24), radius: 0.24, fill: c.transparentize(85%), stroke: 0.6pt + c)
      circle((x + 0.24, y), radius: 0.17, fill: c, stroke: none)
      content((x + 0.24, y), tb(str(k + 1), size: 5pt, fill: paper))
      content((x + 1.42, y), tb(chips.at(k), size: 5pt, fill: ink))
      if i < 3 { line((x + 2.53, y), (x + 2.87, y), stroke: 0.6pt + c, mark: arrow-mark(c)) }
    }
    content((0, y - 0.48), ti(note), anchor: "north-west")
  }
  row(1.65, (0, 1, 2, 3), heal, "Startup · declared order", "each child's start_link returns before the next one starts")
  row(0, (3, 2, 1, 0), crash, "Shutdown · reverse order", "the endpoint stops taking requests before the pool it uses goes away")
})

#let fig-tree() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // application box
  rect((3.9, 4.35), (7.1, 4.85), radius: 0.25, fill: navy, stroke: none, name: "app")
  content((5.5, 4.6), tb("MyApp.Application · start/2", fill: paper))
  snode("root", (5.5, 3.55), "MyApp.Supervisor", w: 2.1)
  line("app.south", "root.north", stroke: 0.7pt + navy, mark: arrow-mark(navy))
  snode("repo", (1.2, 2.35), "Repo", w: 1.0)
  pnode("reg", (3.2, 2.35), "Reg", r: 0.3, size: 4.8pt)
  snode("dyn", (5.5, 2.35), "SessionSup", w: 1.45)
  pnode("cache", (7.6, 2.35), "Cache", r: 0.34, size: 4.6pt)
  snode("web", (9.6, 2.35), "Endpoint", w: 1.3)
  for c in ("repo", "reg", "dyn", "cache", "web") { tie("root", c) }
  for (i, x) in (0.55, 1.2, 1.85).enumerate() {
    pnode("c" + str(i), (x, 1.15), "C" + str(i + 1), r: 0.21)
    tie("repo", "c" + str(i))
  }
  for (i, x) in (4.7, 5.23, 5.76, 6.3).enumerate() {
    pnode("s" + str(i), (x, 1.15), "U" + str(i + 1), r: 0.21)
    tie("dyn", "s" + str(i))
  }
  snode("acc", (9.6, 1.15), "Acceptors", w: 1.2)
  tie("web", "acc")
  for (i, x) in (9.05, 9.6, 10.15).enumerate() {
    pnode("r" + str(i), (x, 0.05), "R", r: 0.18, size: 4.8pt)
    tie("acc", "r" + str(i))
  }
  // annotations
  content((1.2, 0.68), ti("connection pool"), anchor: "north")
  content((5.5, 0.68), ti("one process per user, started at runtime"), anchor: "north")
  content((3.2, 1.85), ti("Registry"), anchor: "north")
  content((7.6, 1.85), ti("GenServer"), anchor: "north")
  content((9.6, -0.28), ti("requests"), anchor: "north")
})

#let fig-blast() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // zones first (background)
  rect((3.35, -0.55), (8.65, 2.62), radius: 0.25, fill: gold.transparentize(90%), stroke: (paint: gold, thickness: 0.5pt, dash: "dashed"))
  rect((3.55, -0.42), (6.3, 1.48), radius: 0.2, fill: crash.transparentize(92%), stroke: (paint: crash.lighten(30%), thickness: 0.5pt, dash: "dashed"))
  circle((4.9, -0.02), radius: 0.36, fill: crash.transparentize(80%), stroke: (paint: crash, thickness: 0.5pt, dash: "dashed"))
  // tree
  snode("root", (4.6, 3.45), "Root Supervisor", w: 1.9)
  snode("data", (1.6, 2.2), "Repo.Supervisor", w: 1.75)
  snode("web", (6, 2.2), "Web.Supervisor", w: 1.7)
  tie("root", "data"); tie("root", "web")
  for (i, x) in (0.8, 1.6, 2.4).enumerate() {
    pnode("c" + str(i), (x, 1.0), "C" + str(i + 1), r: 0.22)
    tie("data", "c" + str(i))
  }
  snode("sess", (4.9, 1.0), "Sessions", w: 1.2)
  snode("ep", (7.45, 1.0), "Endpoint", w: 1.2)
  tie("web", "sess"); tie("web", "ep")
  for (i, (x, st)) in ((4.25, "ok"), (4.9, "crash"), (5.55, "ok")).enumerate() {
    pnode("u" + str(i), (x, -0.02), "U" + str(i + 1), state: st, r: 0.22)
    tie("sess", "u" + str(i))
  }
  pnode("r0", (7.15, -0.02), "R", r: 0.2); pnode("r1", (7.75, -0.02), "R", r: 0.2)
  tie("ep", "r0"); tie("ep", "r1")
  // radius labels
  let tag(n, pos, body, c) = {
    circle(pos, radius: 0.15, fill: c, stroke: none)
    content(pos, tb(str(n), size: 4.8pt, fill: paper))
    content((pos.at(0) + 0.22, pos.at(1)), t(body, size: 5pt, fill: c), anchor: "west")
  }
  tag(1, (9.3, 0), "one process", crash)
  tag(2, (9.3, 1.0), "one subtree", crash.lighten(15%))
  tag(3, (9.3, 2.2), "a whole layer", gold)
  // escalation arrow: runs beneath the leaves, then up the right edge
  bezier((4.9, -0.4), (9.0, 2.5), (6.5, -1.05), (9.05, -0.6), stroke: (paint: slate, thickness: 0.5pt, dash: "dotted"), mark: arrow-mark(slate))
  content((1.6, -0.2), ti("escalates only when a"), anchor: "south")
  content((1.6, -0.45), ti("supervisor exceeds its limit"), anchor: "south")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 3 — Configuration
// ═════════════════════════════════════════════════════════════

#let fig-childspec() = {
  let card(body, fill: paper, stroke: mist.darken(20%)) = box(inset: 5pt, radius: 3pt, fill: fill, stroke: 0.6pt + stroke, body)
  let spec = card(fill: codebg, stroke: gold, align(left, {
    set par(leading: 0.42em, justify: false, first-line-indent: 0pt)
    text(font: mono, size: 5pt, fill: ink)[
      #text(fill: gold.darken(10%))[%]{\
      #h(6pt)id: #text(fill: gold.darken(15%))[MyWorker],\
      #h(6pt)start: {MyWorker, #text(fill: gold.darken(15%))[:start_link], [arg]},\
      #h(6pt)restart: #text(fill: gold.darken(15%))[:permanent],\
      #h(6pt)shutdown: #text(fill: crash)[5000],\
      #h(6pt)type: #text(fill: gold.darken(15%))[:worker]\
      }]
  }))
  diagram(
    spacing: (14pt, 9pt),
    node-inset: 0pt,
    edge-stroke: 0.6pt + slate,
    node((0, 0), card(tm("MyWorker", size: 5.6pt)), name: <a>),
    node((0, 1), card(tm("{MyWorker, arg}", size: 5.6pt)), name: <b>),
    node((0, 2), card(tm("%{id: …, start: …}", size: 5.6pt)), name: <c>),
    node((1, 0.5), card(fill: navy-soft, stroke: navy, tm("MyWorker.child_spec(arg)", size: 5.6pt)), name: <cs>),
    node((2, 1), spec, name: <spec>),
    node((2, 2.3), box(inset: 6pt, radius: 3pt, fill: gold-soft, stroke: 0.7pt + gold, tb("Supervisor")), name: <sup>),
    edge(<a>, <cs>, "-|>", label: t("arg = []", size: 4.8pt, fill: slate), label-side: left),
    edge(<b>, <cs>, "-|>"),
    edge(<cs>, <spec>, "-|>"),
    edge(<c>, <spec>, "-|>", label: t("used as is", size: 4.8pt, fill: slate), label-side: right),
    edge(<spec>, <sup>, "-|>", stroke: 0.7pt + gold),
  )
}

#let fig-registry() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // ── atom table gauge
  content((1.25, 4.1), tb("Atom table", size: 6.2pt, fill: crash))
  rect((0.55, 0.3), (1.95, 3.75), radius: 0.1, fill: paper, stroke: 0.7pt + slate)
  let fills = 13
  for i in range(fills) {
    let y = 0.4 + i * 0.25
    let c = if i < 4 { navy-soft } else if i < 11 { crash-soft } else { crash.lighten(20%) }
    rect((0.65, y), (1.85, y + 0.19), radius: 0.03, fill: c, stroke: none)
  }
  for (i, l) in ((0, ":ok"), (1, ":error"), (2, ":normal"), (3, "MyApp")) {
    content((1.25, 0.495 + i * 0.25), tm(l, size: 4.4pt), anchor: "center")
  }
  for (i, l) in ((5, ":user_81"), (6, ":user_82"), (7, ":user_83"), (8, ":user_…")) {
    content((1.25, 0.495 + i * 0.25), tm(l, size: 4.4pt, fill: crash), anchor: "center")
  }
  line((0.35, 3.62), (2.15, 3.62), stroke: (paint: crash, thickness: 0.8pt, dash: "dashed"))
  content((2.25, 3.62), t("limit (default 1,048,576)", size: 4.8pt, fill: crash), anchor: "west")
  content((2.25, 3.35), ti("never garbage-collected", fill: crash), anchor: "west")
  content((2.25, 2.5), tm("String.to_atom(\"user_\" <> id)", size: 4.6pt, fill: crash), anchor: "west")
  line((2.2, 2.38), (1.98, 2.15), stroke: 0.5pt + crash, mark: arrow-mark(crash))
  content((2.25, 1.15), ti("when it fills, the whole VM", fill: crash), anchor: "west")
  content((2.25, 0.92), ti("stops — not one process", fill: crash), anchor: "west")

  line((5.85, 0.2), (5.85, 4.2), stroke: (paint: mist.darken(15%), thickness: 0.5pt, dash: "dotted"))

  // ── Registry
  content((8.6, 4.1), tb("Registry", size: 6.2pt, fill: heal))
  let rows = (("\"user:81\"", "#PID<0.411.0>"), ("{:game, 7}", "#PID<0.412.0>"), ("42", "#PID<0.415.0>"), ("\"device:ab\"", "#PID<0.420.0>"))
  rect((6.3, 0.55), (10.0, 3.75), radius: 0.1, fill: paper, stroke: 0.7pt + heal)
  content((7.25, 3.5), t("key · any term", size: 4.8pt, fill: slate))
  content((9.0, 3.5), t("value · pid", size: 4.8pt, fill: slate))
  for (i, (k, v)) in rows.enumerate() {
    let y = 3.0 - i * 0.6
    rect((6.45, y - 0.2), (9.85, y + 0.2), radius: 0.05, fill: if calc.even(i) { heal-soft.lighten(30%) } else { paper }, stroke: none)
    content((7.25, y), tm(k, size: 4.8pt, fill: gold.darken(15%)))
    content((8.1, y), t("→", size: 6pt, fill: heal))
    content((9.0, y), tm(v, size: 4.6pt))
  }
  content((8.15, 0.3), ti("entries vanish when their process dies", fill: heal), anchor: "north")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 4 — Restart strategies
// ═════════════════════════════════════════════════════════════

// one tree: supervisor + four children with given states
#let mini-tree(states, sup-state: "sup") = cetz.canvas(length: 0.82cm, {
  import cetz.draw: *
  snode("s", (1.5, 1.05), "Sup", w: 0.95, h: 0.36, state: sup-state, size: 5pt)
  for (i, st) in states.enumerate() {
    pnode("c" + str(i), (i, 0), ("A", "B", "C", "D").at(i), state: st, r: 0.24, size: 5.2pt)
    tie("s", "c" + str(i))
  }
})

#let fig-strategies() = {
  let head(name, sub) = align(center, {
    tm(name, size: 6.4pt, fill: navy)
    linebreak()
    ti(sub, size: 5pt)
  })
  let rowlabel(n, body) = align(right + horizon, {
    box(width: 10pt, height: 10pt, radius: 5pt, fill: gold, align(center + horizon, tb(str(n), size: 5pt, fill: paper)))
    linebreak()
    t(body, size: 5pt, fill: slate)
  })
  grid(
    columns: (auto, 1fr, 1fr, 1fr), column-gutter: 6pt, row-gutter: 8pt, align: center + horizon,
    [], head(":one_for_one", "independent peers"), head(":one_for_all", "inseparable unit"), head(":rest_for_one", "sequential chain"),
    rowlabel(1, "C crashes"),
    mini-tree(("ok", "ok", "crash", "ok")), mini-tree(("ok", "ok", "crash", "ok")), mini-tree(("ok", "ok", "crash", "ok")),
    rowlabel(2, [supervisor\ terminates]),
    mini-tree(("ok", "ok", "off", "ok")), mini-tree(("off", "off", "off", "off")), mini-tree(("ok", "ok", "off", "off")),
    rowlabel(3, [restarts in\ start order]),
    mini-tree(("ok", "ok", "heal", "ok")), mini-tree(("heal", "heal", "heal", "heal")), mini-tree(("ok", "ok", "heal", "heal")),
  )
  legend((sw("ok"), "untouched"), (sw("crash"), "crashed"), (sw("off"), "terminated by supervisor"), (sw("heal"), "freshly restarted"))
}

#let fig-pipeline() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let chain(y, states, title) = {
    content((0, y + 0.55), t(title, size: 5.4pt, fill: slate), anchor: "west")
    let names = ("A · ingest", "B · transform", "C · load")
    for (i, st) in states.enumerate() {
      let x = 0.9 + i * 3.4
      let s = S(st)
      rect((x - 0.95, y - 0.25), (x + 0.95, y + 0.25), radius: 0.25, fill: s.fill, stroke: stk(st))
      content((x, y), tb(names.at(i), fill: s.text))
      if i < 2 { line((x + 1.0, y), (x + 2.4, y), stroke: 0.6pt + slate, mark: arrow-mark(slate)) }
    }
  }
  chain(1.5, ("heal", "heal", "heal"), [If *A* crashes: A, B and C all restart — B and C depended on A])
  chain(0, ("ok", "ok", "heal"), [If *C* crashes: only C restarts — nothing depends on C])
  content((9.0, 1.5), tm("children: [A, B, C]", size: 5pt), anchor: "west")
  content((9.0, 1.25), ti("order is the spec"), anchor: "west")
})

#let fig-decision() = {
  let q(body) = box(width: 112pt, inset: (x: 7pt, y: 5pt), radius: 3pt, fill: paper, stroke: 0.7pt + navy,
    align(center, { set par(justify: false, leading: 0.45em); t(body, size: 5.8pt, fill: navy) }))
  let r(name, ex, c) = box(width: 104pt, inset: (x: 7pt, y: 4.5pt), radius: 8pt, fill: c.transparentize(85%), stroke: 0.7pt + c,
    align(center, { set par(justify: false, leading: 0.45em); tm(name, size: 6pt, fill: c.darken(10%)); linebreak(); ti(ex, size: 4.9pt) }))
  let yes = t("yes", size: 5pt, fill: heal)
  let no = t("no", size: 5pt, fill: crash)
  diagram(
    spacing: (22pt, 14pt),
    node-inset: 0pt,
    edge-stroke: 0.6pt + slate,
    node((0, 0), q[Does one child need another\ to be alive to do its job?], name: <q1>),
    node((1.4, 0), r(":one_for_one", "web handlers, pool workers", heal), name: <r1>),
    node((0, 1), q[Does one failure leave the\ others' state invalid?], name: <q2>),
    node((1.4, 1), r(":one_for_all", "resource manager + its clients", crash), name: <r2>),
    node((0, 2), q[Do dependencies follow\ the start order?], name: <q3>),
    node((1.4, 2), r(":rest_for_one", "ingest → transform → load", gold), name: <r3>),
    node((0, 3), box(width: 112pt, inset: (x: 7pt, y: 5pt), radius: 3pt, fill: mist, stroke: (paint: slate, thickness: 0.6pt, dash: "dashed"),
      t([Split the group: give each cluster\ of dependents its own supervisor], size: 5.6pt, fill: slate)), name: <split>),
    edge(<q1>, <r1>, "-|>", label: no, label-side: left),
    edge(<q1>, <q2>, "-|>", label: yes, label-side: left),
    edge(<q2>, <r2>, "-|>", label: yes, label-side: left),
    edge(<q2>, <q3>, "-|>", label: no, label-side: left),
    edge(<q3>, <r3>, "-|>", label: yes, label-side: left),
    edge(<q3>, <split>, "-|>", label: no, label-side: left),
  )
}

// ═════════════════════════════════════════════════════════════
//  CHAPTER 5 — Dynamic workloads
// ═════════════════════════════════════════════════════════════

#let chart-dynamic() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let x0 = 0.6
  let y0 = 0.4
  let sx = 1.0
  let sy = 0.55
  // (time, count after event, kind)
  let ev = ((1, 1, "start"), (2, 2, "start"), (3, 3, "start"), (4.6, 3, "crash"), (6, 4, "start"), (7.2, 3, "stop"), (8.2, 4, "start"), (9.2, 5, "start"))
  // axes
  line((x0, y0), (x0 + 10.3 * sx, y0), stroke: 0.5pt + slate, mark: arrow-mark(slate))
  line((x0, y0), (x0, y0 + 5.9 * sy), stroke: 0.5pt + slate, mark: arrow-mark(slate))
  for k in range(0, 6) {
    let y = y0 + k * sy
    content((x0 - 0.1, y), t(str(k), size: 4.8pt, fill: slate), anchor: "east")
    if k > 0 { line((x0, y), (x0 + 10 * sx, y), stroke: (paint: mist, thickness: 0.4pt)) }
  }
  content((x0 - 0.45, y0 + 3.0 * sy), t("children", size: 5pt, fill: slate, ), angle: 90deg)
  content((x0 + 10.3 * sx, y0 - 0.12), t("time →", size: 5pt, fill: slate), anchor: "north-east")
  // step path
  let pts = ((x0, y0),)
  let c = 0
  for (tt, n, k) in ev {
    let x = x0 + tt * sx
    pts.push((x, y0 + c * sy))
    pts.push((x, y0 + n * sy))
    c = n
  }
  pts.push((x0 + 10 * sx, y0 + c * sy))
  line(..pts, (x0 + 10 * sx, y0), close: true, fill: navy.transparentize(90%), stroke: none)
  line(..pts, stroke: 0.9pt + navy)
  // the crash dip
  let xc = x0 + 4.6 * sx
  line((xc, y0 + 3 * sy), (xc + 0.12, y0 + 2 * sy), (xc + 0.24, y0 + 3 * sy), stroke: (paint: crash, thickness: 0.7pt, dash: "dashed"))
  circle((xc + 0.12, y0 + 2 * sy), radius: 0.07, fill: crash, stroke: none)
  // event markers
  for (tt, n, k) in ev {
    let x = x0 + tt * sx
    let y = y0 + n * sy
    if k == "start" {
      circle((x, y), radius: 0.07, fill: heal, stroke: none)
    } else if k == "stop" {
      circle((x, y), radius: 0.07, fill: slate, stroke: none)
    }
  }
  content((x0 + 1 * sx, y0 + 1 * sy + 0.18), tm("start_child", size: 4.6pt, fill: heal), anchor: "south")
  content((xc + 0.12, y0 + 2 * sy - 0.12), t("crash → restarted", size: 4.6pt, fill: crash), anchor: "north")
  content((xc + 0.12, y0 + 2 * sy - 0.35), t("(only that child)", size: 4.6pt, fill: crash), anchor: "north")
  content((x0 + 7.2 * sx + 0.08, y0 + 3 * sy - 0.1), tm("terminate_child", size: 4.6pt, fill: slate), anchor: "north-west")
  content((x0 + 0.5 * sx, y0 + 0.06), ti("empty", size: 4.4pt), anchor: "south")
})

#let chart-tasks() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let x0 = 1.3
  // (row, start, end, outcome)
  let tasks = ((0, 0.2, 2.1, "done"), (1, 0.7, 1.6, "done"), (2, 1.1, 4.2, "crash"), (3, 2.0, 3.0, "done"),
    (4, 2.6, 6.4, "done"), (5, 3.4, 4.4, "crash"), (6, 4.1, 5.3, "done"), (7, 5.6, 8.6, "killed"), (8, 6.3, 7.4, "done"))
  let n = tasks.len()
  for (r, a, b, o) in tasks {
    let y = (n - r) * 0.3
    content((x0 - 0.15, y), tm("Task " + str(r + 1), size: 4.6pt, fill: slate), anchor: "east")
    let c = if o == "done" { heal } else if o == "crash" { crash } else { slate }
    rect((x0 + a, y - 0.09), (x0 + b, y + 0.09), radius: 0.09, fill: c.transparentize(70%), stroke: none)
    if o == "done" {
      circle((x0 + b, y), radius: 0.08, fill: heal, stroke: none)
    } else if o == "crash" {
      content((x0 + b + 0.02, y), tb("×", size: 6.5pt, fill: crash))
      content((x0 + b + 0.2, y), t("removed — not restarted", size: 4.4pt, fill: crash), anchor: "west")
    } else {
      line((x0 + b, y - 0.12), (x0 + b, y + 0.12), stroke: 1pt + slate)
    }
  }
  // supervisor shutdown line
  let xs = x0 + 8.6
  line((xs, 0.05), (xs, n * 0.3 + 0.25), stroke: (paint: gold, thickness: 0.7pt, dash: "dashed"))
  content((xs - 0.08, n * 0.3 + 0.3), t("supervisor shuts down:", size: 4.6pt, fill: gold), anchor: "south-east")
  content((xs - 0.08, 0.02), t("running tasks are terminated", size: 4.6pt, fill: gold), anchor: "north-east")
  line((x0, 0.05), (x0 + 9.4, 0.05), stroke: 0.5pt + slate, mark: arrow-mark(slate))
  content((x0 + 9.4, -0.06), t("time →", size: 5pt, fill: slate), anchor: "north-east")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 6 — Advanced controls
// ═════════════════════════════════════════════════════════════

#let chart-intensity() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let x0 = 0.8
  let sx = 0.98
  let base = 0.6
  let sy = 0.5
  let evts = (1.0, 2.2, 6.9, 7.4, 8.1, 8.6)
  // count of restarts within the trailing 5 s window, at each event
  let counts = evts.map(e => evts.filter(x => x <= e and x > e - 5).len())
  // grid
  for k in range(0, 5) {
    let y = base + k * sy
    line((x0, y), (x0 + 10.2 * sx, y), stroke: (paint: if k == 0 { slate } else { mist }, thickness: 0.4pt))
    content((x0 - 0.1, y), t(str(k), size: 4.8pt, fill: slate), anchor: "east")
  }
  content((x0 - 0.5, base + 2 * sy), t("restarts in last 5 s", size: 4.8pt, fill: slate), angle: 90deg)
  // window
  let wa = x0 + 3.6 * sx
  let wb = x0 + 8.6 * sx
  rect((wa, base), (wb, base + 4.65 * sy), fill: gold.transparentize(88%), stroke: none)
  line((wa, base + 4.75 * sy), (wb, base + 4.75 * sy), stroke: 0.5pt + gold, mark: (start: "stealth", end: "stealth", fill: gold, scale: 0.4))
  content(((wa + wb) / 2, base + 4.85 * sy), tm("max_seconds: 5 · sliding window", size: 4.8pt, fill: gold.darken(10%)), anchor: "south")
  // threshold
  line((x0, base + 3 * sy), (x0 + 8.8 * sx, base + 3 * sy), stroke: (paint: crash, thickness: 0.6pt, dash: "dashed"))
  content((x0 + 0.05, base + 3 * sy + 0.06), tm("max_restarts: 3", size: 4.8pt, fill: crash), anchor: "south-west")
  // bars
  for (i, e) in evts.enumerate() {
    let x = x0 + e * sx
    let n = counts.at(i)
    let c = if n > 3 { crash } else { navy }
    rect((x - 0.14, base), (x + 0.14, base + n * sy), fill: c.transparentize(if n > 3 { 0% } else { 30% }), stroke: none, radius: (north: 0.04))
    content((x, base + n * sy + 0.05), tb(str(n), size: 4.8pt, fill: c), anchor: "south")
  }
  // time axis
  for s in range(0, 11) {
    let x = x0 + s * sx
    line((x, base), (x, base - 0.07), stroke: 0.5pt + slate)
    content((x, base - 0.1), t(str(s) + " s", size: 4.6pt, fill: slate), anchor: "north")
  }
  // outcome annotation
  let xe = x0 + 8.6 * sx
  content((xe + 0.22, base + 4 * sy - 0.08), t("4 > 3: the supervisor stops", size: 4.8pt, fill: crash), anchor: "north-west")
  content((xe + 0.22, base + 4 * sy - 0.32), t("its children and exits", size: 4.8pt, fill: crash), anchor: "north-west")
  content((xe + 0.22, base + 4 * sy - 0.56), t("→ the parent decides", size: 4.8pt, fill: crash), anchor: "north-west")
})

#let fig-restart-matrix() = {
  let cell(on) = if on {
    box(width: 100%, inset: (y: 5pt), radius: 2pt, fill: heal-soft, align(center, tb("↻  restart", size: 6pt, fill: heal)))
  } else {
    box(width: 100%, inset: (y: 5pt), radius: 2pt, fill: mist.lighten(30%), align(center, t("—  remove", size: 6pt, fill: slate)))
  }
  let hd(body, sub) = align(center, { tm(body, size: 5.8pt); linebreak(); ti(sub, size: 4.8pt) })
  block(width: 88%, grid(
    columns: (auto, 1fr, 1fr, 1fr), column-gutter: 4pt, row-gutter: 4pt, align: horizon,
    [], hd(":normal", "finished its job"), hd(":shutdown", [or `{:shutdown, term}`]), hd("anything else", "a genuine crash"),
    align(right, tm(":permanent", size: 6pt) + h(4pt)), cell(true), cell(true), cell(true),
    align(right, tm(":transient", size: 6pt) + h(4pt)), cell(false), cell(false), cell(true),
    align(right, tm(":temporary", size: 6pt) + h(4pt)), cell(false), cell(false), cell(false),
  ))
}

#let fig-shutdown() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let x0 = 2.4
  let sx = 1.45
  let lane(y, name, sub) = {
    content((x0 - 0.2, y + 0.08), tm(name, size: 5.6pt), anchor: "east")
    content((x0 - 0.2, y - 0.17), ti(sub, size: 4.6pt), anchor: "east")
    line((x0, y), (x0 + 6 * sx, y), stroke: (paint: mist.darken(10%), thickness: 0.5pt))
  }
  let sig(x, y, label, c) = {
    line((x, y + 0.42), (x, y + 0.12), stroke: 0.7pt + c, mark: arrow-mark(c))
    content((x, y + 0.45), tm(label, size: 4.8pt, fill: c), anchor: "south")
  }
  // lane 1: timeout
  let y1 = 2.6
  lane(y1, "shutdown: 5000", "workers' default")
  rect((x0, y1 - 0.12), (x0 + 3.5 * sx, y1 + 0.12), radius: 0.12, fill: heal-soft, stroke: none)
  content((x0 + 1.75 * sx, y1), t("grace period · terminate/2 cleans up", size: 4.8pt, fill: heal))
  sig(x0, y1, ":shutdown", gold)
  sig(x0 + 3.5 * sx, y1, ":kill", crash)
  content((x0 + 3.5 * sx + 0.1, y1 - 0.08), t("only if still alive", size: 4.6pt, fill: crash), anchor: "north-west")
  // lane 2: brutal kill
  let y2 = 1.45
  lane(y2, ":brutal_kill", "no cleanup")
  sig(x0, y2, ":kill", crash)
  content((x0 + 0.15, y2 - 0.12), t("terminated immediately", size: 4.8pt, fill: crash), anchor: "north-west")
  // lane 3: infinity
  let y3 = 0.3
  lane(y3, ":infinity", "supervisors' default")
  rect((x0, y3 - 0.12), (x0 + 5.6 * sx, y3 + 0.12), radius: 0.12, fill: gold-soft, stroke: none)
  line((x0 + 5.6 * sx, y3), (x0 + 6.1 * sx, y3), stroke: (paint: gold, thickness: 0.6pt, dash: "dotted"), mark: arrow-mark(gold))
  content((x0 + 2.8 * sx, y3), t("waits as long as the subtree needs to stop in order", size: 4.8pt, fill: gold.darken(20%)))
  sig(x0, y3, ":shutdown", gold)
  // time scale
  for (s, l) in ((0, "0"), (3.5, "5000 ms")) {
    content((x0 + s * sx, -0.15), t(l, size: 4.6pt, fill: slate), anchor: "north")
  }
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 7 — Best practices
// ═════════════════════════════════════════════════════════════

#let fig-shallow-deep() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // deep
  content((1.55, 4.35), tb("Deep", size: 6.2pt, fill: crash))
  for i in range(5) {
    let y = 3.8 - i * 0.82
    let x = 0.9 + i * 0.33
    snode("d" + str(i), (x, y), "S" + str(i + 1), w: 0.62, h: 0.32, size: 4.8pt, state: if i == 4 { "crash" } else { "sup" })
    pnode("dw" + str(i), (x + 1.0, y - 0.38), "", r: 0.12)
    line("d" + str(i) + ".east", "dw" + str(i) + ".west", stroke: 0.5pt + slate.lighten(25%))
    if i > 0 { tie("d" + str(i - 1), "d" + str(i)) }
  }
  bezier((0.45, 0.5), (0.45, 3.85), (-0.2, 1.6), (-0.2, 2.8), stroke: (paint: crash, thickness: 0.5pt, dash: "dotted"), mark: arrow-mark(crash))
  content((1.6, 0.05), ti("restarts cascade through", fill: crash), anchor: "north")
  content((1.6, -0.2), ti("many layers", fill: crash), anchor: "north")

  line((3.6, -0.2), (3.6, 4.4), stroke: (paint: mist.darken(15%), thickness: 0.5pt, dash: "dotted"))

  // shallow
  content((7.25, 4.35), tb("Wide and shallow", size: 6.2pt, fill: heal))
  snode("r", (7.25, 3.7), "Root", w: 0.9, h: 0.34, size: 5pt)
  let groups = ("Repo", "Accounts", "Sales", "Jobs", "Web")
  for (i, g) in groups.enumerate() {
    let x = 4.35 + i * 1.45
    snode("g" + str(i), (x, 2.45), g, w: 1.2, h: 0.32, size: 4.8pt)
    tie("r", "g" + str(i))
    for j in range(3) {
      let cx = x - 0.4 + j * 0.4
      pnode("w" + str(i) + str(j), (cx, 1.4), "", r: 0.13)
      tie("g" + str(i), "w" + str(i) + str(j))
    }
  }
  content((7.25, 0.75), ti("each branch has one clear purpose", fill: heal), anchor: "north")
  content((7.25, 0.5), ti("and its own restart policy", fill: heal), anchor: "north")
})

#let fig-contexts() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  snode("root", (5.4, 3.3), "MyApp.Supervisor", w: 2.1)
  let kids = (
    ("repo", 0.9, "MyApp.Repo", "sup"),
    ("acc", 3.25, "Accounts.Supervisor", "sup"),
    ("sales", 5.9, "Sales.Supervisor", "sup"),
    ("lib", 8.2, "{Finch, name: …}", "ghost"),
    ("ep", 10.1, "Endpoint", "sup"),
  )
  for (n, x, l, st) in kids {
    snode(n, (x, 2.1), l, w: if n == "repo" or n == "ep" { 1.35 } else { 1.95 }, state: st)
    tie("root", n)
  }
  let leaves(parent, x, labels) = {
    for (i, l) in labels.enumerate() {
      let cx = x + (i - (labels.len() - 1) / 2) * 0.9
      pnode(parent + str(i), (cx, 0.9), l, r: 0.25, size: 4.6pt)
      tie(parent, parent + str(i))
    }
  }
  leaves("acc", 3.25, ("Tok", "Sess"))
  leaves("sales", 5.9, ("Cart", "Price"))
  // domain brackets
  rect((2.0, 0.35), (7.15, 2.55), radius: 0.15, fill: none, stroke: (paint: navy.lighten(30%), thickness: 0.45pt, dash: "dotted"))
  content((4.57, 0.28), ti("contexts own their processes", fill: navy), anchor: "north")
  content((8.2, 1.62), ti("a library's child spec,", fill: slate), anchor: "north")
  content((8.2, 1.38), ti("added by the app", fill: slate), anchor: "north")
})

#let fig-api() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let clients(x0, y0) = {
    for (i, n) in ("Billing", "Reports", "Admin", "Jobs").enumerate() {
      let y = y0 + 1.95 - i * 0.62
      rect((x0, y - 0.2), (x0 + 1.2, y + 0.2), radius: 0.05, fill: paper, stroke: 0.6pt + slate)
      content((x0 + 0.6, y), t(n, size: 5pt))
    }
  }
  // scattered
  content((2.6, 2.8), tb("Scattered calls", size: 6.2pt, fill: crash))
  clients(0, 0)
  circle((4.3, 1.0), radius: 0.62, fill: navy-soft, stroke: 0.7pt + navy)
  content((4.3, 1.1), tb("GenServer", size: 5pt, fill: navy))
  content((4.3, 0.88), t("internals", size: 4.6pt, fill: navy))
  let msgs = (":get_state", "{:put, k, v}", ":get_state", "{:reset}")
  for (i, m) in msgs.enumerate() {
    let y = 1.95 - i * 0.62
    let end = (3.7, 1.0 + (1.5 - i) * 0.22)
    line((1.22, y), end, stroke: 0.55pt + crash.lighten(20%), mark: arrow-mark(crash))
    let mid = (1.22 + (end.at(0) - 1.22) * 0.42, y + (end.at(1) - y) * 0.42)
    content(mid, box(fill: paper, inset: (x: 1.5pt, y: 1pt), tm(m, size: 4.3pt, fill: crash)))
  }

  line((5.45, -0.1), (5.45, 2.9), stroke: (paint: mist.darken(15%), thickness: 0.5pt, dash: "dotted"))

  // encapsulated
  content((8.5, 2.8), tb("One public API", size: 6.2pt, fill: heal))
  clients(5.75, 0)
  rect((7.75, -0.05), (9.3, 2.35), radius: 0.08, fill: heal-soft, stroke: 0.7pt + heal)
  content((8.52, 2.17), tb("MyWorker", size: 5pt, fill: heal))
  for (i, f) in ("get_state/0", "put/2", "reset/0").enumerate() {
    let y = 1.7 - i * 0.55
    rect((7.88, y - 0.17), (9.17, y + 0.17), radius: 0.17, fill: paper, stroke: 0.5pt + heal)
    content((8.52, y), tm(f, size: 4.6pt, fill: heal))
  }
  for i in range(4) {
    let y = 1.95 - i * 0.62
    line((6.97, y), (7.73, 1.2 + (1.5 - i) * 0.25), stroke: 0.55pt + heal, mark: arrow-mark(heal))
  }
  circle((10.4, 1.0), radius: 0.55, fill: navy-soft, stroke: 0.7pt + navy)
  content((10.4, 1.08), tb("process", size: 4.8pt, fill: navy))
  content((10.4, 0.88), t("(hidden)", size: 4.4pt, fill: navy))
  line((9.32, 1.0), (9.83, 1.0), stroke: 0.6pt + navy, mark: arrow-mark(navy))
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 8 — Anti-patterns
// ═════════════════════════════════════════════════════════════

#let fig-bottleneck() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // left: funnel into one GenServer
  content((2.5, 3.35), tb("A stateless GenServer", size: 6.2pt, fill: crash))
  for i in range(8) {
    let y = 2.85 - i * 0.36
    circle((0.25, y), radius: 0.11, fill: navy-soft, stroke: 0.5pt + navy)
    line((0.38, y), (1.75, 1.6), stroke: 0.4pt + slate.lighten(30%))
  }
  // mailbox queue
  for k in range(7) {
    envelope((1.95 + k * 0.33, 1.6), w: 0.26, h: 0.18, fill: gold-soft)
  }
  circle((4.68, 1.6), radius: 0.5, fill: crash-soft, stroke: 0.8pt + crash)
  content((4.68, 1.68), tb("Calculator", size: 4.8pt, fill: crash))
  content((4.68, 1.48), t("1 at a time", size: 4.3pt, fill: crash))
  content((2.95, 1.0), ti("every call waits in one queue", fill: crash), anchor: "north")

  line((5.45, -0.25), (5.45, 3.4), stroke: (paint: mist.darken(15%), thickness: 0.5pt, dash: "dotted"))

  // right: plain module in callers, spread over schedulers
  content((8.55, 3.35), tb("A plain module", size: 6.2pt, fill: heal))
  for s in range(4) {
    let y = 2.6 - s * 0.72
    rect((6.6, y - 0.26), (10.9, y + 0.26), radius: 0.08, fill: heal-soft.lighten(35%), stroke: 0.4pt + heal.lighten(40%))
    content((6.52, y), t("CPU " + str(s + 1), size: 4.6pt, fill: slate), anchor: "east")
    for j in range(3) {
      let x = 7.0 + j * 1.35 + calc.rem(s, 2) * 0.4
      circle((x, y), radius: 0.11, fill: navy-soft, stroke: 0.5pt + navy)
      line((x + 0.13, y), (x + 0.75, y), stroke: 0.5pt + heal, mark: arrow-mark(heal))
      content((x + 0.42, y + 0.16), tm("add/2", size: 3.9pt, fill: heal))
    }
  }
  content((8.75, 0.05), ti("each caller runs the function itself, in parallel", fill: heal), anchor: "north")
})

#let fig-copy() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let heap(x, y, w, h, title, fill, label) = {
    rect((x, y), (x + 2.6, y + 1.25), radius: 0.1, fill: paper, stroke: 0.6pt + navy)
    content((x + 0.1, y + 1.14), tm(title, size: 4.6pt), anchor: "north-west")
    rect((x + 0.15, y + 0.12), (x + 0.15 + w, y + 0.12 + h), radius: 0.04, fill: fill, stroke: none)
    content((x + 0.15 + w / 2, y + 0.12 + h / 2), t(label, size: 4.6pt, fill: ink))
  }
  // heavy
  content((0, 2.95), tb("Sending the whole conn", size: 5.8pt, fill: crash), anchor: "west")
  heap(0, 1.45, 2.3, 0.78, "controller heap", crash-soft, "%Plug.Conn{…}")
  heap(4.6, 1.45, 2.3, 0.78, "task heap", crash-soft, "copy of the conn")
  line((2.65, 1.95), (4.55, 1.95), stroke: 1.6pt + crash.lighten(25%), mark: (end: "stealth", fill: crash.lighten(25%), scale: 0.7))
  content((3.6, 2.12), t("copied byte by byte", size: 4.6pt, fill: crash), anchor: "south")
  // light
  content((0, 1.15), tb("Sending what is needed", size: 5.8pt, fill: heal), anchor: "west")
  heap(0, -0.35, 0.7, 0.3, "controller heap", heal-soft, "id, params")
  heap(4.6, -0.35, 0.7, 0.3, "task heap", heal-soft, "id, params")
  rect((0.15 + 0.85, -0.23), (2.45, 0.55), radius: 0.04, fill: mist.lighten(20%), stroke: none)
  content((1.72, 0.16), t("conn stays here", size: 4.4pt, fill: slate))
  line((2.65, 0.2), (4.55, 0.2), stroke: 0.6pt + heal, mark: arrow-mark(heal))
  content((3.6, 0.34), tm("{user_id, params}", size: 4.6pt, fill: heal), anchor: "south")
  // GC note
  content((7.5, 1.85), ti("cost paid twice:", fill: slate), anchor: "west")
  content((7.5, 1.6), ti("the copy, then garbage", fill: slate), anchor: "west")
  content((7.5, 1.35), ti("collection in the receiver", fill: slate), anchor: "west")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 9 — Real-world use
// ═════════════════════════════════════════════════════════════

#let fig-phoenix() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  snode("ep", (0.9, 1.7), "Endpoint", w: 1.35)
  content((0.9, 1.32), ti("supervised"), anchor: "north")
  // request processes grid
  content((4.9, 3.35), tb("one process per connection or request · temporary", size: 5.4pt, fill: navy))
  for r in range(3) {
    for c in range(9) {
      let x = 2.7 + c * 0.55
      let y = 2.85 - r * 0.42
      let crashed = r == 1 and c == 5
      let st = if crashed { "crash" } else { "ok" }
      circle((x, y), radius: 0.15, fill: S(st).fill, stroke: 0.5pt + S(st).stroke)
      if crashed { content((x, y), tb("×", size: 5pt, fill: crash)) }
    }
  }
  content((5.45 + 1.95, 2.43), t("← only this one dies", size: 4.6pt, fill: crash), anchor: "west")
  // channels
  content((4.9, 1.2), tb("one long-lived process per WebSocket · Channel / LiveView", size: 5.4pt, fill: heal))
  for r in range(2) {
    let y = 0.75 - r * 0.4
    for c in range(3) {
      let x = 2.7 + c * 1.6
      rect((x - 0.15, y - 0.13), (x + 1.3, y + 0.13), radius: 0.13, fill: heal-soft, stroke: 0.5pt + heal)
    }
  }
  line((1.6, 1.85), (2.45, 2.45), stroke: 0.5pt + slate, mark: arrow-mark(slate))
  line((1.6, 1.55), (2.45, 0.6), stroke: 0.5pt + slate, mark: arrow-mark(slate))
})

#let fig-broadway() = {
  let stage(body, sub, c) = box(inset: (x: 6pt, y: 4pt), radius: 3pt, fill: c.transparentize(85%), stroke: 0.7pt + c,
    { set par(justify: false, leading: 0.4em); tb(body, size: 5.6pt, fill: c.darken(15%)); linebreak(); ti(sub, size: 4.6pt) })
  let small(c) = box(width: 12pt, height: 12pt, radius: 6pt, fill: c.transparentize(80%), stroke: 0.6pt + c)
  diagram(
    spacing: (14pt, 9pt),
    node-inset: 0pt,
    edge-stroke: 0.6pt + slate,
    node((0, 1), box(inset: 5pt, radius: 3pt, fill: mist, stroke: 0.6pt + slate, t([Kafka ·\ RabbitMQ ·\ Pub/Sub], size: 5pt)), name: <src>),
    node((1, 1), stage("Producer", "pulls with back-pressure", navy), name: <prod>),
    node((2, 0), small(navy), name: <p1>),
    node((2, 1), small(navy), name: <p2>),
    node((2, 2), small(crash), name: <p3>),
    node((2, -0.62), tb("processors", size: 5pt, fill: navy)),
    node((3, 1), stage("Batchers", "group by size / time", gold), name: <bat>),
    node((4, 1), box(inset: 5pt, radius: 3pt, fill: heal-soft, stroke: 0.6pt + heal, t([database ·\ warehouse], size: 5pt, fill: heal)), name: <sink>),
    node((2, 3), box(inset: (x: 6pt, y: 4pt), radius: 3pt, fill: crash-soft, stroke: (paint: crash, thickness: 0.6pt, dash: "dashed"),
      t("broker DLQ (you configure)", size: 5pt, fill: crash)), name: <dlq>),
    edge(<src>, <prod>, "-|>"),
    edge(<prod>, <p1>, "-|>"), edge(<prod>, <p2>, "-|>"), edge(<prod>, <p3>, "-|>"),
    edge(<p1>, <bat>, "-|>"), edge(<p2>, <bat>, "-|>"), edge(<p3>, <bat>, "-|>"),
    edge(<bat>, <sink>, "-|>", stroke: 0.7pt + heal),
    edge(<p3>, <dlq>, "--|>", stroke: 0.6pt + crash, label: tm("handle_failed/2", size: 4.6pt, fill: crash), label-side: left),
  )
}

#let fig-cluster() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let c = (5.4, 1.85)
  circle(c, radius: 1.25, stroke: (paint: gold, thickness: 0.6pt, dash: "dashed"))
  content(c, tb("hash ring", size: 5pt, fill: gold))
  content((c.at(0), c.at(1) - 0.22), ti("who owns which key?", size: 4.4pt), anchor: "north")
  let nodes = (("node_a", 150deg, "ok"), ("node_b", 30deg, "crash"), ("node_c", 270deg, "ok"))
  let pos = (:)
  for (n, ang, st) in nodes {
    let p = (c.at(0) + 1.25 * calc.cos(ang), c.at(1) + 1.25 * calc.sin(ang))
    circle(p, radius: 0.09, fill: if st == "crash" { crash } else { gold }, stroke: none)
    let bx = (c.at(0) + 3.0 * calc.cos(ang), c.at(1) + 2.0 * calc.sin(ang))
    pos.insert(n, bx)
    let s = S(st)
    rect((bx.at(0) - 1.05, bx.at(1) - 0.55), (bx.at(0) + 1.05, bx.at(1) + 0.55), radius: 0.12,
      fill: if st == "crash" { crash-soft.lighten(30%) } else { paper }, stroke: stk(st))
    content((bx.at(0), bx.at(1) + 0.38), tm(n + "@host", size: 4.8pt, fill: s.text))
    line(p, (bx.at(0) - 0.6 * calc.cos(ang), bx.at(1) - 0.5 * calc.sin(ang)), stroke: 0.4pt + mist.darken(25%))
  }
  // processes inside nodes
  let a = pos.at("node_a")
  for k in range(3) { circle((a.at(0) - 0.55 + k * 0.4, a.at(1) - 0.1), radius: 0.12, fill: navy-soft, stroke: 0.5pt + navy) }
  let b = pos.at("node_b")
  rect((b.at(0) - 0.7, b.at(1) - 0.32), (b.at(0) + 0.7, b.at(1) + 0.1), radius: 0.2, fill: crash-soft, stroke: (paint: crash, thickness: 0.6pt, dash: "dashed"))
  content((b.at(0), b.at(1) - 0.11), tb("Scheduler", size: 4.8pt, fill: crash))
  content((b.at(0) + 0.95, b.at(1) + 0.55), tb("×", size: 10pt, fill: crash))
  content((b.at(0), b.at(1) - 0.75), t("node lost", size: 4.6pt, fill: crash))
  let cc = pos.at("node_c")
  rect((cc.at(0) - 0.7, cc.at(1) - 0.32), (cc.at(0) + 0.7, cc.at(1) + 0.1), radius: 0.2, fill: heal-soft, stroke: 0.7pt + heal)
  content((cc.at(0), cc.at(1) - 0.11), tb("Scheduler", size: 4.8pt, fill: heal))
  // failover arrow
  bezier((b.at(0) + 0.3, b.at(1) - 0.6), (cc.at(0) + 1.1, cc.at(1)), (b.at(0) + 1.6, b.at(1) - 1.6), (cc.at(0) + 2.2, cc.at(1) + 0.6),
    stroke: 0.8pt + heal, mark: arrow-mark(heal))
  content((b.at(0) + 1.45, b.at(1) - 1.75), t("restarted on a healthy node", size: 4.8pt, fill: heal), anchor: "west")
  content((b.at(0) + 1.45, b.at(1) - 1.98), ti("one instance, barring network splits", size: 4.6pt), anchor: "west")
})

// ═════════════════════════════════════════════════════════════
//  CHAPTER 10 — Landscape
// ═════════════════════════════════════════════════════════════

#let fig-breaker() = {
  let st(name, sub, c) = box(width: 58pt, inset: (y: 6pt), radius: 13pt, fill: c.transparentize(85%), stroke: 0.8pt + c,
    align(center, { set par(leading: 0.4em, justify: false); tb(name, size: 6.2pt, fill: c.darken(10%)); linebreak(); ti(sub, size: 4.6pt) }))
  let l(body, c: slate) = t(body, size: 4.9pt, fill: c)
  box(inset: (x: 10pt, top: 14pt, bottom: 8pt), radius: 5pt, stroke: (paint: gold, thickness: 0.6pt, dash: "dashed"), {
    place(top + left, dx: -2pt, dy: -11pt, t("inside a GenServer, under a supervisor", size: 4.9pt, fill: gold, style: "italic"))
    diagram(
      spacing: (46pt, 26pt),
      node-inset: 0pt,
      edge-stroke: 0.6pt + slate,
      node((0, 0), st("Closed", "calls flow through", heal), name: <closed>),
      node((2, 0), st("Open", "fail fast, no call", crash), name: <open>),
      node((1, 1), st("Half-open", "one trial call", gold), name: <half>),
      edge(<closed>, <open>, "-|>", label: l("failures ≥ threshold", c: crash), label-side: left, bend: 18deg),
      edge(<open>, <half>, "-|>", label: l("after timeout"), label-side: right, bend: -10deg),
      edge(<half>, <closed>, "-|>", label: l("trial succeeds", c: heal), label-side: left, bend: 12deg),
      edge(<half>, <open>, "-|>", label: l("trial fails", c: crash), label-side: right, bend: -45deg),
      edge(<closed>, <closed>, "-|>", bend: 130deg, loop-angle: 180deg, label: l("success"), label-side: left),
    )
  })
}

#let fig-layers() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let c = (2.6, 2.3)
  let rings = (
    (2.25, rgb("#e6ebf2"), navy.lighten(35%), "Kubernetes · pod", "container restarted"),
    (1.65, gold-soft.lighten(25%), gold, "BEAM VM · application", "root supervisor exits"),
    (1.05, heal-soft, heal, "supervisor subtree", "siblings restarted"),
    (0.48, navy-soft, navy, "process", "restarted in place"),
  )
  for (r, f, s, _, _) in rings { circle(c, radius: r, fill: f, stroke: 0.6pt + s) }
  content(c, tb("×", size: 7pt, fill: crash))
  // leaders and labels
  for (i, (r, f, s, name, sub)) in rings.rev().enumerate() {
    let ang = 18deg + i * 0deg
    let y = c.at(1) + 1.35 - i * 0.9
    let p = (c.at(0) + r * calc.cos(25deg), c.at(1) + r * calc.sin(25deg) - (i - 1.5) * 0.0)
    let edge-pt = (c.at(0) + r, c.at(1) + (1.5 - i) * 0.0)
    let anchor-pt = (c.at(0) + r * 0.92, c.at(1) + 0.9 - i * 0.6)
    let target = (6.0, y)
    circle(anchor-pt, radius: 0.05, fill: s, stroke: none)
    line(anchor-pt, (5.85, y), stroke: 0.4pt + s)
    content((6.0, y + 0.1), tb(name, size: 5.6pt, fill: s.darken(10%)), anchor: "west")
    content((6.0, y - 0.15), ti(sub, size: 4.8pt), anchor: "west")
  }
  // external dependency with breaker at the boundary
  rect((9.4, -0.1), (11.2, 0.5), radius: 0.1, fill: mist, stroke: 0.6pt + slate)
  content((10.3, 0.2), t("external API", size: 5pt, fill: slate))
  line((2.75, 2.0), (2.75, 0.2), (9.38, 0.2), stroke: (paint: slate, thickness: 0.5pt, dash: "dashed"))
  rect((8.45, 0.06), (8.95, 0.34), radius: 0.14, fill: gold, stroke: none)
  content((8.7, 0.2), tb("CB", size: 4.6pt, fill: paper))
  content((8.7, -0.05), ti("circuit breaker", size: 4.4pt), anchor: "north")
})

#let chart-recovery() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  // log10 seconds from -6 (1 µs) to 2 (100 s)
  let x0 = 3.0
  let w = 8.0
  let lo = -6
  let hi = 2
  let X(e) = x0 + (e - lo) / (hi - lo) * w
  let rows = (
    ("Process restart", "OTP supervisor", -5.6, -4.3, navy),
    ("Subtree restart", "OTP supervisor", -4.2, -2.3, heal),
    ("VM / app reboot", "release start", -0.5, 1.0, gold),
    ("Container restarted", "Kubernetes kubelet", 0.8, 2.0, crash),
  )
  for (i, (name, who, a, b, c)) in rows.enumerate() {
    let y = 2.4 - i * 0.56
    content((x0 - 0.15, y + 0.08), tb(name), anchor: "east")
    content((x0 - 0.15, y - 0.15), ti(who, size: 4.6pt), anchor: "east")
    rect((X(a), y - 0.16), (X(b), y + 0.16), radius: 0.16, fill: c.transparentize(25%), stroke: none)
  }
  let ya = 0.45
  line((x0, ya), (x0 + w, ya), stroke: 0.5pt + slate)
  for (e, l) in ((-6, "1 µs"), (-5, "10 µs"), (-4, "100 µs"), (-3, "1 ms"), (-2, "10 ms"), (-1, "100 ms"), (0, "1 s"), (1, "10 s"), (2, "100 s")) {
    let x = X(e)
    line((x, ya), (x, ya - 0.07), stroke: 0.5pt + slate)
    line((x, ya + 0.02), (x, 2.75), stroke: (paint: mist.darken(5%), thickness: 0.4pt, dash: "dotted"))
    content((x, ya - 0.11), t(l, size: 4.6pt, fill: slate), anchor: "north")
  }
  content((x0 + w / 2, 3.0), ti("in-VM recovery is several orders of magnitude cheaper — and finer-grained", size: 5pt, fill: navy))
})

#let fig-escalation() = {
  let step(body, c, dash: false) = box(width: 112pt, inset: (x: 6pt, y: 4.5pt), radius: 3pt,
    fill: c.transparentize(87%), stroke: if dash { (paint: c, thickness: 0.6pt, dash: "dashed") } else { 0.6pt + c },
    align(center, { set par(leading: 0.4em, justify: false); t(body, size: 5.4pt, fill: c.darken(20%)) }))
  let note(body, c: slate) = t(body, size: 4.9pt, fill: c, style: "italic")
  diagram(
    spacing: (18pt, 11pt),
    node-inset: 0pt,
    edge-stroke: 0.6pt + slate,
    node((0, 0), step([A worker crashes], crash), name: <a>),
    node((0, 1), step([Its supervisor restarts it], heal), name: <b>),
    node((1.15, 1), note([transient fault:\ healed here, in µs], c: heal), name: <bn>),
    node((0, 2), step([Crashes keep coming: more than\ `max_restarts` in `max_seconds`], gold), name: <c>),
    node((0, 3), step([The supervisor gives up and exits], gold), name: <d>),
    node((0, 4), step([Low intensity above ⇒ escalation\ reaches the root supervisor], gold), name: <e>),
    node((0, 5), step([Root exits; a `:permanent`\ application stops the VM], navy), name: <f>),
    node((0, 6), step([The OS process exits], navy), name: <g>),
    node((0, 7), step([Kubernetes restarts the container], navy, dash: true), name: <h>),
    edge(<a>, <b>, "-|>"),
    edge(<b>, <bn>, "..", stroke: 0.5pt + heal),
    edge(<b>, <c>, "-|>"),
    edge(<c>, <d>, "-|>"),
    edge(<d>, <e>, "-|>"),
    edge(<e>, <f>, "-|>"),
    edge(<f>, <g>, "-|>"),
    edge(<g>, <h>, "-|>"),
    node((1.15, 3.5), note([inside the VM:\ OTP escalates], c: gold)),
    node((1.15, 6.5), note([outside the VM:\ the orchestrator acts], c: navy)),
  )
}

// Decorative section ornament
#let ornament() = align(center, block(above: 1.4em, below: 1.4em,
  text(fill: gold, size: 9pt, font: serif)[◆ #h(6pt) ◆ #h(6pt) ◆]))
