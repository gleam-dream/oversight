//// Fit to screen: while a playground tours, scale its content so the whole
//// card fits under the app bar, from 100% down to a floor of 60% in steps of
//// 5. The tour bar itself is never scaled.
////
//// The fit walks down from 100% and stops at the first zoom at which the
//// card fits, as the reference does. Card height is not monotonic in zoom
//// (a narrower layout can wrap differently), so no shortcut finds the same
//// answer. The shell measures before the browser paints and Lustre renders
//// again within the same frame, so the walk is never visible.
////
//// A fit belongs to a basis: the step's narration and the viewport size. A
//// settled card keeps walking down if it outgrows the screen, and walks
//// again from 100% only if its content clearly shrank since it settled.

import gleam/int

pub const floor = 60

pub const full = 100

/// Below this width the site never scales playgrounds.
pub const narrow_width = 760

/// How much a settled card must shrink before it is fitted afresh.
const slack = 90

pub type Fit {
  /// Showing `zoom` to see whether the card fits there.
  Trying(zoom: Int, basis: String)
  Settled(zoom: Int, basis: String, height: Int)
}

pub type Sample {
  /// One touring card measured at the zoom it showed, `shown`.
  Sample(height: Int, shown: Int)
}

pub fn basis(narration: String, width: Int, height: Int) -> String {
  narration <> "|" <> int.to_string(width) <> "x" <> int.to_string(height)
}

/// Whether the fit still needs another measurement.
pub fn is_settling(fit: Fit) -> Bool {
  case fit {
    Trying(..) -> True
    Settled(..) -> False
  }
}

/// The next fit for one card, given its previous fit (if any), a sample of
/// the card as shown, and the height available under the app bar.
pub fn next(
  previous: Result(Fit, Nil),
  sample: Sample,
  basis: String,
  available: Int,
) -> Fit {
  case previous {
    // A measurement taken before the card showed the fit's zoom says nothing
    // about that zoom: wait for the next one.
    Ok(fit) if fit.basis == basis && sample.shown != fit.zoom -> fit
    Ok(Trying(zoom:, ..) as fit) if fit.basis == basis ->
      try(zoom, basis, sample, available)
    Ok(Settled(zoom:, height:, ..) as fit) if fit.basis == basis ->
      case sample.height > available && zoom > floor {
        True -> Trying(zoom - 5, basis)
        False ->
          case zoom < full && sample.height < height - slack {
            True -> Trying(full, basis)
            False -> fit
          }
      }
    _ ->
      case sample.shown == full {
        True -> try(full, basis, sample, available)
        False -> Trying(full, basis)
      }
  }
}

/// The card was measured at `zoom`: settle there or try the next step down.
fn try(zoom: Int, basis: String, sample: Sample, available: Int) -> Fit {
  case sample.height > available && zoom > floor {
    True -> Trying(zoom - 5, basis)
    False -> Settled(zoom, basis, sample.height)
  }
}
