//// Plumbing for real-time widgets. Each widget is a Lustre component that
//// owns its simulation and redraws only its own SVG on every frame; the page
//// around it never re-renders for a frame.
////
//// All widgets share one animation-frame loop (in the browser FFI). A widget
//// subscribes when it connects and motion is on, and unsubscribes when it
//// disconnects or motion turns off.
////
//// The page owns what the reader or a tour sets, such as a mode, a rate or
//// pause, and passes it down as attributes. One-off commands such as "reset"
//// or "advance one second" travel as increasing sequence numbers, so a
//// widget acts on each command exactly once.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import site/browser
import site/motion.{type Motion}

/// The widget's subscription to the shared frame loop.
pub type Frames {
  Unsubscribed
  Subscribed(handle: Int)
}

/// Subscribe to frames. `on_frame` receives the seconds since the previous
/// frame (at most 0.05); `subscribed` reports the handle to keep.
pub fn subscribe(
  on_frame: fn(Float) -> msg,
  subscribed: fn(Int) -> msg,
) -> Effect(msg) {
  use dispatch <- effect.from
  let handle = browser.subscribe_frames(fn(dt) { dispatch(on_frame(dt)) })
  dispatch(subscribed(handle))
}

pub fn unsubscribe(frames: Frames) -> Effect(msg) {
  case frames {
    Unsubscribed -> effect.none()
    Subscribed(handle) -> {
      use _ <- effect.from
      browser.unsubscribe_frames(handle)
    }
  }
}

// ATTRIBUTES ------------------------------------------------------------------

pub fn motion_attribute(motion: Motion) -> Attribute(msg) {
  attribute.attribute("motion", motion.encode(motion))
}

/// Decode the `motion` attribute for `component.on_attribute_change`.
pub fn on_motion(to_msg: fn(Motion) -> msg) -> component.Option(msg) {
  component.on_attribute_change("motion", fn(value) {
    case value {
      "on" -> Ok(to_msg(motion.On))
      "off" -> Ok(to_msg(motion.Off))
      _ -> Error(Nil)
    }
  })
}

/// A command counter: the widget runs the command when the number grows.
pub fn sequence_attribute(name: String, sequence: Int) -> Attribute(msg) {
  attribute.attribute(name, int.to_string(sequence))
}

pub fn on_sequence(
  name: String,
  to_msg: fn(Int) -> msg,
) -> component.Option(msg) {
  component.on_attribute_change(name, fn(value) {
    int.parse(value) |> result.map(to_msg)
  })
}

pub fn on_int(name: String, to_msg: fn(Int) -> msg) -> component.Option(msg) {
  on_sequence(name, to_msg)
}

pub fn on_bool(name: String, to_msg: fn(Bool) -> msg) -> component.Option(msg) {
  component.on_attribute_change(name, fn(value) {
    case value {
      "true" -> Ok(to_msg(True))
      "false" -> Ok(to_msg(False))
      _ -> Error(Nil)
    }
  })
}

pub fn bool_attribute(name: String, value: Bool) -> Attribute(msg) {
  attribute.attribute(name, case value {
    True -> "true"
    False -> "false"
  })
}

/// Whether a new sequence number asks for the command again. The first value
/// a widget sees only sets its baseline.
pub fn is_new(seen: Option(Int), sequence: Int) -> #(Bool, Option(Int)) {
  case seen {
    None -> #(False, Some(sequence))
    Some(previous) -> #(sequence > previous, Some(int.max(previous, sequence)))
  }
}
