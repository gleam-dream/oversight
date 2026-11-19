//// A numbered walk through a fixed number of steps that the reader moves by
//// hand or plays on a timer. Both the system walkthrough and the trace use
//// it.
////
//// A run is identified by its epoch. Every start and stop moves the epoch
//// on, so a tick scheduled for an earlier run is recognised and ignored.

import gleam/int
import site/motion.{type Motion}

pub type Run {
  Idle
  Playing
}

pub opaque type Stepper {
  Stepper(at: Int, total: Int, run: Run, epoch: Int)
}

/// A walk of `total` steps, at the first step and not playing.
pub fn new(total: Int) -> Stepper {
  Stepper(at: 1, total: int.max(total, 1), run: Idle, epoch: 0)
}

/// Start over at the first step of a walk of `total` steps, stopping any run.
pub fn restart(stepper: Stepper, total: Int) -> Stepper {
  Stepper(at: 1, total: int.max(total, 1), run: Idle, epoch: stepper.epoch + 1)
}

/// The current step, from 1 to `total`.
pub fn at(stepper: Stepper) -> Int {
  stepper.at
}

pub fn total(stepper: Stepper) -> Int {
  stepper.total
}

pub fn run(stepper: Stepper) -> Run {
  stepper.run
}

pub fn epoch(stepper: Stepper) -> Int {
  stepper.epoch
}

pub fn at_start(stepper: Stepper) -> Bool {
  stepper.at <= 1
}

pub fn at_end(stepper: Stepper) -> Bool {
  stepper.at >= stepper.total
}

/// One step back. A running play carries on from there.
pub fn back(stepper: Stepper) -> Stepper {
  Stepper(..stepper, at: int.max(1, stepper.at - 1))
}

/// One step forward. A running play carries on from there.
pub fn forward(stepper: Stepper) -> Stepper {
  Stepper(..stepper, at: int.min(stepper.total, stepper.at + 1))
}

/// Move to step `n`, kept within the walk.
pub fn scrub(stepper: Stepper, n: Int) -> Stepper {
  Stepper(..stepper, at: int.max(1, int.min(stepper.total, n)))
}

/// Play from the first step. Without motion the walk jumps to its end.
pub fn play(stepper: Stepper, motion: Motion) -> Stepper {
  let epoch = stepper.epoch + 1
  case motion {
    motion.On -> Stepper(..stepper, at: 1, run: Playing, epoch:)
    motion.Off -> Stepper(..stepper, at: stepper.total, run: Idle, epoch:)
  }
}

/// Stop a running play where it is.
pub fn stop(stepper: Stepper) -> Stepper {
  case stepper.run {
    Playing -> Stepper(..stepper, run: Idle, epoch: stepper.epoch + 1)
    Idle -> stepper
  }
}

/// A scheduled tick of the run named by `epoch`. A tick at the last step
/// ends the run; any other tick moves one step on. A tick of an earlier run
/// is refused.
pub fn tick(stepper: Stepper, epoch: Int) -> Result(Stepper, Nil) {
  case stepper.run, epoch == stepper.epoch {
    Playing, True ->
      case stepper.at >= stepper.total {
        True -> Ok(Stepper(..stepper, run: Idle))
        False -> Ok(Stepper(..stepper, at: stepper.at + 1))
      }
    _, _ -> Error(Nil)
  }
}
