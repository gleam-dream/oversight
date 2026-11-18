//// Module page: not ported yet.

import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import site/context.{type Context}
import site/route
import site/tour

pub type TourId

pub type Model {
  Model(tours: tour.Tours(TourId))
}

pub type Msg {
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(tours: tour.new())
}

pub fn update(
  model: Model,
  msg: Msg,
  _context: Context,
) -> #(Model, Effect(Msg)) {
  case msg {
    Tour(..) -> #(model, effect.none())
  }
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(tours: tour.pause_all(model.tours))
}

/// Register this page's real-time widget components, if it has any.
pub fn register() -> Result(Nil, lustre.Error) {
  Ok(Nil)
}

pub fn view(_model: Model, _context: Context) -> Element(Msg) {
  html.header([class("wrap")], [
    html.h1([], [html.text(route.module_title(route.Otp))]),
  ])
}
