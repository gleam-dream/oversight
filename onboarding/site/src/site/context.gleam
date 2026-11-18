//// What a page needs from the shell to update and render: the motion setting,
//// the reader's progress and the fit-to-screen zoom the shell measured for
//// each touring playground.

import gleam/dict.{type Dict}
import site/fit
import site/motion.{type Motion}
import site/progress.{type Progress}

pub type Context {
  Context(motion: Motion, progress: Progress, zooms: Dict(String, Int))
}

pub fn new(motion: Motion, progress: Progress) -> Context {
  Context(motion:, progress:, zooms: dict.new())
}

/// The zoom for a playground card, by its tour key. 100 means unscaled.
pub fn zoom(context: Context, tour: String) -> Int {
  case dict.get(context.zooms, tour) {
    Ok(zoom) -> zoom
    Error(Nil) -> fit.full
  }
}

pub fn animates(context: Context) -> Bool {
  motion.is_on(context.motion)
}
