//// Small view helpers shared by every page.

import lustre/attribute.{type Attribute, attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

/// A raw inline style string, kept verbatim from the reference markup.
pub fn css(style: String) -> Attribute(msg) {
  attribute("style", style)
}

/// A link to an element on the same page. It scrolls without touching the
/// route in the URL, so a reload still lands on the module.
pub fn jump(
  target: String,
  on_jump: fn(String) -> msg,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      attribute.href("#" <> target),
      event.on_click(on_jump(target)) |> event.prevent_default,
      ..attributes
    ],
    children,
  )
}

/// A link that opens outside the course, in a new tab.
pub fn external(
  href: String,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.target("_blank"),
      attribute.rel("noopener"),
      ..attributes
    ],
    children,
  )
}

/// The dark "Carry this forward" block that closes every module.
pub fn carry_forward(text: String) -> Element(msg) {
  html.div([attribute.class("key")], [
    html.div([attribute.class("k")], [html.text("Carry this forward")]),
    html.p([], [html.text(text)]),
  ])
}

/// `aria-pressed` for a toggle button.
pub fn pressed(on: Bool) -> Attribute(msg) {
  attribute("aria-pressed", case on {
    True -> "true"
    False -> "false"
  })
}

/// The `on` class of a selected button, as in segmented controls.
pub fn on_class(base: String, on: Bool) -> Attribute(msg) {
  attribute.class(case on, base {
    True, "" -> "on"
    True, _ -> base <> " on"
    False, _ -> base
  })
}
