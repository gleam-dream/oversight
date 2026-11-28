//// The Typst booklets published beside the course. Each one is built from
//// `booklets/<slug>/` at the repository root (`nix build .#booklets`) into
//// the Pages site as `booklets/<slug>.pdf`.

import lustre/attribute.{class}
import lustre/element.{type Element}
import lustre/element/html
import site/ui.{css}

pub type Booklet {
  Booklet(slug: String, title: String)
}

pub const resilience =
  Booklet(slug: "architecting-resilience", title: "Architecting Resilience")

pub const all = [resilience]

/// The booklet's PDF, relative to the course.
pub fn pdf(booklet: Booklet) -> String {
  "booklets/" <> booklet.slug <> ".pdf"
}

/// A "Further reading" card: what the booklet adds to this module, and a
/// link to it.
pub fn card(booklet: Booklet, why: String) -> Element(msg) {
  html.div([class("card"), css("margin-top:32px;max-width:760px")], [
    html.div([class("k"), css("color:#5B5970")], [html.text("Further reading")]),
    html.h3([css("font-size:22px;margin:8px 0")], [html.text(booklet.title)]),
    html.p([class("muted")], [html.text(why)]),
    html.div([class("row"), css("gap:8px;margin-top:12px")], [
      ui.external(pdf(booklet), [class("pill")], [html.text("Read the PDF")]),
    ]),
  ])
}
