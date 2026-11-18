//// Fit to screen: while a playground tours, scale its content so the whole
//// card fits under the app bar, from 100% down to a floor of 60% in steps of
//// 5. The tour bar itself is never scaled.
////
//// A fit belongs to a basis: the step's narration and the viewport size. On
//// a new basis the fit starts settling one step above an estimate and
//// shrinks by 5 per paint until the card fits, then it is settled at the
//// height it fitted with. A settled fit shrinks again if the card outgrows
//// the screen, and grows again only if the card's content clearly shrank.

import gleam/int

pub const floor = 60

pub const full = 100

/// Below this width the site never scales playgrounds.
pub const narrow_width = 760

/// A card padded and bordered while touring: 20px top and bottom, 1px border.
const frame = 42

/// How much a settled card must shrink before it is allowed to grow again.
const slack = 90

pub type Fit {
  Settling(zoom: Int, basis: String)
  Settled(zoom: Int, basis: String, height: Int)
}

pub type Sample {
  /// One touring card measured at the zoom it currently shows.
  Sample(narration: String, height: Int, bar: Int)
}

pub fn basis(narration: String, width: Int, height: Int) -> String {
  narration <> "|" <> int.to_string(width) <> "x" <> int.to_string(height)
}

/// Whether the fit still needs another measurement after the next paint.
pub fn is_settling(fit: Fit) -> Bool {
  case fit {
    Settling(..) -> True
    Settled(..) -> False
  }
}

/// The next fit for one card, given its previous fit (if any), a sample at
/// the zoom it currently shows, and the height available under the app bar.
pub fn next(
  previous: Result(Fit, Nil),
  sample: Sample,
  basis: String,
  available: Int,
) -> Fit {
  let overflows = sample.height > available
  case previous {
    Ok(Settling(zoom:, basis: old)) if old == basis ->
      case overflows && zoom > floor {
        True -> Settling(zoom - 5, basis)
        False -> Settled(zoom, basis, sample.height)
      }
    Ok(Settled(zoom:, basis: old, height:)) if old == basis ->
      case
        overflows && zoom > floor,
        zoom < full && sample.height < height - slack
      {
        True, _ -> Settling(zoom - 5, basis)
        False, True -> start(sample, zoom, basis, available)
        False, False -> Settled(zoom:, basis:, height:)
      }
    Ok(fit) -> start(sample, fit.zoom, basis, available)
    Error(Nil) -> start(sample, full, basis, available)
  }
}

fn start(sample: Sample, shown_at: Int, basis: String, available: Int) -> Fit {
  Settling(int.min(full, estimate(sample, shown_at, available) + 10), basis)
}

/// The largest zoom step at which the card would fit if its scaled content
/// grew in proportion to the zoom. Scaled text wraps less, so the real
/// answer is this or a little more.
pub fn estimate(sample: Sample, shown_at: Int, available: Int) -> Int {
  let content = int.max(sample.height - sample.bar - frame, 0)
  let content_at_full = content * full / int.max(shown_at, 1)
  let room = available - sample.bar - frame
  largest_fitting(full, content_at_full, room)
}

fn largest_fitting(zoom: Int, content_at_full: Int, room: Int) -> Int {
  case zoom <= floor || content_at_full * zoom / full <= room {
    True -> zoom
    False -> largest_fitting(zoom - 5, content_at_full, room)
  }
}
