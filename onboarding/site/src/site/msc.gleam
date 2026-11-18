//// Message sequence charts. Lanes are participants, time flows down, and
//// each event is a message, a note, a crash or a lost message. The newest
//// event draws in. Layout is a pure function of the chart description.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{attribute, class}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import site/ui.{css}

// DESCRIPTION -----------------------------------------------------------------

pub type Colour {
  Ink
  Red
  Green
  Pink
  Blue
  Amber
  Grey
}

pub type Line {
  Solid
  Dashed
}

pub type Event {
  /// A message between two lanes; from a lane to itself it curls back.
  Message(from: Int, to: Int, label: String, colour: Colour, line: Line)
  /// A message that never arrives: half an arrow and a lightning bolt.
  Lost(from: Int, to: Int, label: String, colour: Colour)
  Note(at: Int, label: String, colour: Colour)
  /// A process dies: a red cross on its lane.
  Crash(at: Int, label: String)
}

pub type Chart {
  Chart(
    /// Unique on the page; arrowhead markers are named after it.
    id: String,
    lanes: List(String),
    events: List(Event),
    /// How many events have happened; later ones show faintly.
    upto: Option(Int),
    lane_gap: Int,
    row: Int,
    right_pad: Int,
    numbers: Bool,
    active: Option(Int),
    highlight_last: Bool,
    animate_last: Bool,
    aria: String,
  )
}

/// A chart with the reference defaults: 170 between lanes, 40 per row.
pub fn chart(id: String, lanes: List(String), events: List(Event)) -> Chart {
  Chart(
    id:,
    lanes:,
    events:,
    upto: None,
    lane_gap: 170,
    row: 40,
    right_pad: 130,
    numbers: False,
    active: None,
    highlight_last: True,
    animate_last: True,
    aria: "Message sequence chart",
  )
}

/// A message on a solid line.
pub fn send(from: Int, to: Int, label: String, colour: Colour) -> Event {
  Message(from:, to:, label:, colour:, line: Solid)
}

// LAYOUT ----------------------------------------------------------------------

const pad = 90

const top = 52

pub type LaneShape {
  LaneShape(x: Int, label: String, active: Bool)
}

pub type ArrowShape {
  ArrowShape(
    d: String,
    label: String,
    label_x: Float,
    label_y: Int,
    anchor: String,
    colour: Colour,
    opacity: Float,
    marker: Bool,
    dashed: Bool,
    width: Int,
    fresh: Bool,
    lost: Option(#(Float, Int)),
    number: Option(#(String, Int)),
  )
}

pub type Layout {
  Layout(
    width: Int,
    height: Int,
    line_end: Int,
    lanes: List(LaneShape),
    arrows: List(ArrowShape),
  )
}

pub fn layout(chart: Chart) -> Layout {
  let count = list.length(chart.lanes)
  let width = pad * 2 + chart.lane_gap * { count - 1 } + chart.right_pad
  let x = fn(lane) { pad + lane * chart.lane_gap }
  let total = list.length(chart.events)
  let upto = option.unwrap(chart.upto, total)
  let height = top + 26 + int.max(total, 1) * chart.row + 10
  let arrows =
    list.index_map(chart.events, fn(event, i) {
      arrow(chart, event, i, upto, x)
    })
  Layout(
    width:,
    height:,
    line_end: height - 6,
    lanes: list.index_map(chart.lanes, fn(label, i) {
      LaneShape(x: x(i), label:, active: chart.active == Some(i))
    }),
    arrows:,
  )
}

fn arrow(
  chart: Chart,
  event: Event,
  i: Int,
  upto: Int,
  x: fn(Int) -> Int,
) -> ArrowShape {
  let y = top + 26 + i * chart.row
  let opacity = case i < upto {
    True ->
      case i == upto - 1 && chart.highlight_last {
        True -> 1.0
        False -> 0.85
      }
    False -> 0.12
  }
  let last = i == upto - 1 && chart.animate_last
  let numbering = case chart.numbers {
    True -> Some(#(int.to_string(i + 1), y + 4))
    False -> None
  }
  let n = int.to_string
  let base =
    ArrowShape(
      d: "",
      label: "",
      label_x: 0.0,
      label_y: y - 8,
      anchor: "middle",
      colour: Ink,
      opacity:,
      marker: False,
      dashed: False,
      width: 2,
      fresh: last,
      lost: None,
      number: numbering,
    )
  case event {
    Crash(at:, label:) -> {
      let f = x(at)
      ArrowShape(
        ..base,
        d: "M"
          <> n(f - 9)
          <> " "
          <> n(y - 9)
          <> " L"
          <> n(f + 9)
          <> " "
          <> n(y + 9)
          <> " M"
          <> n(f + 9)
          <> " "
          <> n(y - 9)
          <> " L"
          <> n(f - 9)
          <> " "
          <> n(y + 9),
        label:,
        label_x: int.to_float(f + 16),
        label_y: y + 5,
        anchor: "start",
        colour: Red,
        width: 3,
      )
    }
    Note(at:, label:, colour:) -> {
      let f = x(at)
      ArrowShape(
        ..base,
        d: "M" <> n(f - 5) <> " " <> n(y) <> " L" <> n(f + 5) <> " " <> n(y),
        label:,
        label_x: int.to_float(f + 14),
        label_y: y + 5,
        anchor: "start",
        colour:,
      )
    }
    Lost(from:, to:, label:, colour:) -> {
      let f = x(from)
      let mid = int.to_float(f + x(to)) /. 2.0
      ArrowShape(
        ..base,
        d: "M" <> n(f) <> " " <> n(y) <> " L" <> number(mid) <> " " <> n(y),
        label:,
        label_x: mid,
        colour:,
        lost: Some(#(mid +. 8.0, y)),
      )
    }
    Message(from:, to:, label:, colour:, line:) if from == to -> {
      let f = x(from)
      ArrowShape(
        ..base,
        d: "M"
          <> n(f)
          <> " "
          <> n(y - 8)
          <> " C"
          <> n(f + 46)
          <> " "
          <> n(y - 8)
          <> " "
          <> n(f + 46)
          <> " "
          <> n(y + 10)
          <> " "
          <> n(f + 4)
          <> " "
          <> n(y + 10),
        label:,
        label_x: int.to_float(f + 54),
        label_y: y + 5,
        anchor: "start",
        colour:,
        marker: True,
        dashed: line == Dashed,
      )
    }
    Message(from:, to:, label:, colour:, line:) -> {
      let f = x(from)
      let t = x(to)
      let dir = case t > f {
        True -> 1
        False -> -1
      }
      ArrowShape(
        ..base,
        d: "M" <> n(f) <> " " <> n(y) <> " L" <> n(t - dir * 6) <> " " <> n(y),
        label:,
        label_x: int.to_float(f + t) /. 2.0,
        colour:,
        marker: True,
        dashed: line == Dashed,
      )
    }
  }
}

/// Numbers as the reference prints them: integers without a decimal point.
fn number(x: Float) -> String {
  case float.floor(x) == x {
    True -> int.to_string(float.truncate(x))
    False -> float.to_string(x)
  }
}

// VIEW ------------------------------------------------------------------------

const colours = [Ink, Red, Green, Pink, Blue, Amber, Grey]

pub fn hex(colour: Colour) -> String {
  case colour {
    Ink -> "#17162B"
    Red -> "#B42318"
    Green -> "#15803D"
    Pink -> "#B0186E"
    Blue -> "#1D4ED8"
    Amber -> "#B45309"
    Grey -> "#8A8698"
  }
}

fn name(colour: Colour) -> String {
  case colour {
    Ink -> "ink"
    Red -> "red"
    Green -> "green"
    Pink -> "pink"
    Blue -> "blue"
    Amber -> "amber"
    Grey -> "grey"
  }
}

pub fn view(chart: Chart) -> Element(msg) {
  let shape = layout(chart)
  let w = int.to_string(shape.width)
  html.div([css("overflow-x:auto")], [
    svg.svg(
      [
        attribute("viewBox", "0 0 " <> w <> " " <> int.to_string(shape.height)),
        attribute("width", "100%"),
        css(
          "min-width:540px;max-width:" <> w <> "px;display:block;margin:0 auto",
        ),
        attribute.role("img"),
        attribute.aria_label(chart.aria),
      ],
      [
        svg.defs([], list.map(colours, marker(chart.id, _))),
        element.fragment(list.map(shape.lanes, lane(_, shape.line_end))),
        element.fragment(list.map(shape.arrows, draw(chart.id, _))),
      ],
    ),
  ])
}

fn marker(id: String, colour: Colour) -> Element(msg) {
  svg.marker(
    [
      attribute.id("mk-" <> id <> "-" <> name(colour)),
      attribute("viewBox", "0 0 10 10"),
      attribute("refX", "8"),
      attribute("refY", "5"),
      attribute("markerWidth", "7"),
      attribute("markerHeight", "7"),
      attribute("orient", "auto-start-reverse"),
    ],
    [
      svg.path([
        attribute("d", "M0,0 L10,5 L0,10 z"),
        attribute("fill", hex(colour)),
      ]),
    ],
  )
}

fn lane(l: LaneShape, line_end: Int) -> Element(msg) {
  let x = int.to_string(l.x)
  element.fragment([
    svg.rect([
      attribute("x", int.to_string(l.x - 70)),
      attribute("y", "6"),
      attribute("width", "140"),
      attribute("height", "30"),
      attribute("rx", "8"),
      attribute("fill", case l.active {
        True -> "#17162B"
        False -> "#F1EEE8"
      }),
    ]),
    svg.text(
      [
        attribute("x", x),
        attribute("y", "26"),
        attribute("text-anchor", "middle"),
        class("msc-h"),
        css(case l.active {
          True -> "fill:#FFFFFF"
          False -> "fill:#17162B"
        }),
      ],
      l.label,
    ),
    svg.line([
      attribute("x1", x),
      attribute("y1", "38"),
      attribute("x2", x),
      attribute("y2", int.to_string(line_end)),
      attribute("stroke", "#D5D1C8"),
      attribute("stroke-width", "2"),
      attribute("stroke-dasharray", "4 5"),
    ]),
  ])
}

fn draw(id: String, a: ArrowShape) -> Element(msg) {
  let colour = hex(a.colour)
  let solid = !a.dashed && a.width == 2
  svg.g(
    [
      attribute("opacity", number(a.opacity)),
      case a.fresh {
        True -> class("msc-new")
        False -> attribute.none()
      },
    ],
    [
      svg.path([
        case solid {
          True -> class("solid")
          False -> attribute.none()
        },
        case solid {
          True -> attribute("pathLength", "1")
          False -> attribute.none()
        },
        attribute("d", a.d),
        attribute("stroke", colour),
        attribute("stroke-width", int.to_string(a.width)),
        attribute("fill", "none"),
        case a.dashed {
          True -> attribute("stroke-dasharray", "6 5")
          False -> attribute.none()
        },
        case a.marker && a.lost == None {
          True ->
            attribute(
              "marker-end",
              "url(#mk-" <> id <> "-" <> name(a.colour) <> ")",
            )
          False -> attribute.none()
        },
      ]),
      case a.lost {
        Some(#(cx, cy)) ->
          svg.text(
            [
              attribute("x", number(cx)),
              attribute("y", int.to_string(cy)),
              attribute("fill", "#B42318"),
              css("font:700 18px Inter,sans-serif"),
              attribute("dy", "6"),
            ],
            "⚡",
          )
        None -> element.none()
      },
      svg.text(
        [
          attribute("x", number(a.label_x)),
          attribute("y", int.to_string(a.label_y)),
          attribute("text-anchor", a.anchor),
          class("msc-l"),
          attribute("fill", colour),
        ],
        a.label,
      ),
      case a.number {
        Some(#(label, y)) ->
          svg.text(
            [
              attribute("x", "26"),
              attribute("y", int.to_string(y)),
              class("msc-l"),
              attribute("fill", "#8A8698"),
            ],
            label,
          )
        None -> element.none()
      },
    ],
  )
}
