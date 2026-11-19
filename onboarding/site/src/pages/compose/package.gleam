//// The twelve gleam-dream packages as the composition studio names and
//// colours them, plus the application that joins them.

pub type Package {
  Sinal
  Blueprint
  HttpGun
  LlmWire
  Relay
  Hellhound
  Correio
  Grind
  Saga
  Fabric
  Decisions
  Retrace
}

/// The packages in the order the studio lists them.
pub const all = [
  Sinal,
  Blueprint,
  HttpGun,
  LlmWire,
  Relay,
  Hellhound,
  Correio,
  Grind,
  Saga,
  Fabric,
  Decisions,
  Retrace,
]

/// Who does a step of a system: a package, or the application's own code.
pub type Actor {
  YourApp
  Uses(Package)
}

pub type Style {
  Style(name: String, bg: String, fg: String)
}

pub fn style(actor: Actor) -> Style {
  case actor {
    YourApp -> Style("Your app", "#F1EEE8", "#17162B")
    Uses(Sinal) -> Style("Sinal", "#DDF3F0", "#0B4A45")
    Uses(Blueprint) -> Style("JSON Blueprint", "#DDF3F0", "#0B4A45")
    Uses(HttpGun) -> Style("HTTP Gun", "#E0E9FD", "#163A8A")
    Uses(LlmWire) -> Style("LLM Wire", "#EEE7FD", "#3B1785")
    Uses(Relay) -> Style("Relay", "#EEE7FD", "#3B1785")
    Uses(Hellhound) -> Style("Hellhound", "#EEE7FD", "#3B1785")
    Uses(Correio) -> Style("Correio", "#EEE7FD", "#3B1785")
    Uses(Grind) -> Style("Grind", "#FDF0DC", "#6B3404")
    Uses(Saga) -> Style("Saga", "#FDF0DC", "#6B3404")
    Uses(Fabric) -> Style("Fabric", "#FCE7F3", "#5E0B3A")
    Uses(Decisions) -> Style("Decisions", "#FCE7F3", "#5E0B3A")
    Uses(Retrace) -> Style("Retrace", "#E2F4E7", "#0E4D25")
  }
}

pub fn package_style(package: Package) -> Style {
  style(Uses(package))
}
