//// The twelve places a reader can be. The course map is a place but not a
//// module, so it can never be marked done.

import gleam/int
import gleam/list
import gleam/string

pub type Module {
  Beam
  Otp
  Gleam
  Principles
  Atlas
  Foundations
  OutsideWorld
  DurableWork
  Agents
  Compose
  FieldGuide
}

pub type Route {
  CourseMap
  Module(Module)
}

/// Every module in course order.
pub const modules = [
  Beam,
  Otp,
  Gleam,
  Principles,
  Atlas,
  Foundations,
  OutsideWorld,
  DurableWork,
  Agents,
  Compose,
  FieldGuide,
]

pub fn all() -> List(Route) {
  [CourseMap, ..list.map(modules, Module)]
}

/// The stable hash name. Links, storage keys and the URL all use it.
pub fn slug(route: Route) -> String {
  case route {
    CourseMap -> "start"
    Module(module) -> module_slug(module)
  }
}

pub fn module_slug(module: Module) -> String {
  case module {
    Beam -> "beam"
    Otp -> "otp"
    Gleam -> "gleam"
    Principles -> "principles"
    Atlas -> "atlas"
    Foundations -> "foundations"
    OutsideWorld -> "outside-world"
    DurableWork -> "durable-work"
    Agents -> "agents"
    Compose -> "compose"
    FieldGuide -> "field-guide"
  }
}

/// Parse a location hash, with or without its leading `#`.
pub fn parse(hash: String) -> Result(Route, Nil) {
  let name = case string.starts_with(hash, "#") {
    True -> string.drop_start(hash, 1)
    False -> hash
  }
  list.find(all(), fn(route) { slug(route) == name })
}

pub fn parse_module(name: String) -> Result(Module, Nil) {
  list.find(modules, fn(module) { module_slug(module) == name })
}

pub fn href(route: Route) -> String {
  "#" <> slug(route)
}

pub fn title(route: Route) -> String {
  case route {
    CourseMap -> "Course map"
    Module(module) -> module_title(module)
  }
}

pub fn module_title(module: Module) -> String {
  case module {
    Beam -> "The BEAM"
    Otp -> "OTP"
    Gleam -> "Gleam"
    Principles -> "How gleam-dream thinks"
    Atlas -> "The package atlas"
    Foundations -> "Foundations"
    OutsideWorld -> "The outside world"
    DurableWork -> "Work that outlives a request"
    Agents -> "Agents & people in the loop"
    Compose -> "Composition studio"
    FieldGuide -> "Field guide"
  }
}

/// The module's position in the course, from 1 to 11, derived from the
/// course order so a reorder needs one edit.
pub fn number(module: Module) -> Int {
  list.take_while(modules, fn(m) { m != module }) |> list.length |> int.add(1)
}

pub fn minutes(module: Module) -> Int {
  case module {
    Beam -> 20
    Otp -> 20
    Gleam -> 15
    Principles -> 20
    Atlas -> 15
    Foundations -> 20
    OutsideWorld -> 20
    DurableWork -> 20
    Agents -> 25
    Compose -> 25
    FieldGuide -> 15
  }
}

/// The label shown in menus and footers: "3 · Gleam", or "Course map".
pub fn label(route: Route) -> String {
  case route {
    CourseMap -> title(route)
    Module(module) -> int.to_string(number(module)) <> " · " <> title(route)
  }
}

pub fn document_title(route: Route) -> String {
  let place = case route {
    CourseMap -> "Course map"
    Module(module) ->
      "Module "
      <> int.to_string(number(module))
      <> " · "
      <> module_title(module)
  }
  place <> " · gleam-dream onboarding"
}

pub fn previous(module: Module) -> Route {
  case list.take_while(modules, fn(m) { m != module }) |> list.last {
    Ok(before) -> Module(before)
    Error(Nil) -> CourseMap
  }
}

/// The route after a module; after the last module the course wraps to the map.
pub fn next(module: Module) -> Route {
  case list.drop_while(modules, fn(m) { m != module }) {
    [_, after, ..] -> Module(after)
    _ -> CourseMap
  }
}
