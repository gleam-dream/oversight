//// The "Links, monitors and trapped exits" playground: two processes, A and
//// B, joined one of three ways, and what each sees when the other ends.
//// The names are gleam_erlang's: `process.link`, `process.monitor` and
//// `process.trap_exits`, with the `ExitMessage` and `ProcessDown` messages
//// they deliver.

import gleam/option.{type Option, None, Some}
import site/msc

/// How A is joined to B.
pub type Bond {
  /// A two-way link: an abnormal exit of either kills the other.
  Link
  /// A watches B. One way, and nobody dies of it.
  Monitor
  /// A link, and A traps exits: B's exit signal reaches A as a message.
  TrappedLink
}

pub const bonds = [Link, Monitor, TrappedLink]

/// What the reader makes happen.
pub type Ending {
  BCrashes
  BFinishes
  ACrashes
}

pub type Status {
  Alive
  Crashed
  Finished
  /// Killed by the exit signal of a linked process.
  KilledByLink
}

pub type Pair {
  Pair(
    bond: Bond,
    a: Status,
    b: Status,
    last: Option(Ending),
    events: List(msc.Event),
  )
}

pub fn new() -> Pair {
  Pair(bond: Link, a: Alive, b: Alive, last: None, events: [])
}

/// Choosing a bond starts both processes afresh.
pub fn pick(_pair: Pair, bond: Bond) -> Pair {
  Pair(..new(), bond:)
}

pub fn reset(pair: Pair) -> Pair {
  pick(pair, pair.bond)
}

/// Both processes still run, so something can still happen.
pub fn running(pair: Pair) -> Bool {
  pair.a == Alive && pair.b == Alive
}

pub fn end(pair: Pair, ending: Ending) -> Pair {
  case running(pair) {
    False -> pair
    True -> {
      let #(a, b, events) = case ending, pair.bond {
        BCrashes, Link -> #(KilledByLink, Crashed, [
          msc.Crash(1, "B crashes"),
          msc.send(1, 0, "exit signal · abnormal", msc.Red),
          msc.Crash(0, "A dies too"),
        ])
        BCrashes, Monitor -> #(Alive, Crashed, [
          msc.Crash(1, "B crashes"),
          msc.Message(1, 0, "ProcessDown(Abnormal)", msc.Blue, msc.Dashed),
          msc.Note(0, "A keeps running", msc.Green),
        ])
        BCrashes, TrappedLink -> #(Alive, Crashed, [
          msc.Crash(1, "B crashes"),
          msc.send(1, 0, "ExitMessage(Abnormal)", msc.Amber),
          msc.Note(0, "a message: A can start B again", msc.Green),
        ])
        BFinishes, Link -> #(Alive, Finished, [
          msc.Note(1, "B returns: a normal exit", msc.Grey),
          msc.Message(1, 0, "exit signal · normal", msc.Grey, msc.Dashed),
          msc.Note(0, "ignored: A keeps running", msc.Green),
        ])
        BFinishes, Monitor -> #(Alive, Finished, [
          msc.Note(1, "B returns: a normal exit", msc.Grey),
          msc.Message(1, 0, "ProcessDown(Normal)", msc.Blue, msc.Dashed),
          msc.Note(0, "A keeps running", msc.Green),
        ])
        BFinishes, TrappedLink -> #(Alive, Finished, [
          msc.Note(1, "B returns: a normal exit", msc.Grey),
          msc.send(1, 0, "ExitMessage(Normal)", msc.Amber),
          msc.Note(0, "A keeps running", msc.Green),
        ])
        ACrashes, Link -> #(Crashed, KilledByLink, [
          msc.Crash(0, "A crashes"),
          msc.send(0, 1, "exit signal · abnormal", msc.Red),
          msc.Crash(1, "B dies too"),
        ])
        ACrashes, Monitor -> #(Crashed, Alive, [
          msc.Crash(0, "A crashes"),
          msc.Note(1, "B never knew: only A was watching", msc.Grey),
        ])
        ACrashes, TrappedLink -> #(Crashed, KilledByLink, [
          msc.Crash(0, "A crashes"),
          msc.send(0, 1, "exit signal · abnormal", msc.Red),
          msc.Crash(1, "B dies: only A traps exits"),
        ])
      }
      Pair(..pair, a:, b:, last: Some(ending), events:)
    }
  }
}

pub fn bond_name(bond: Bond) -> String {
  case bond {
    Link -> "Link"
    Monitor -> "Monitor"
    TrappedLink -> "Link + trap exits"
  }
}

pub fn bond_description(bond: Bond) -> String {
  case bond {
    Link ->
      "process.link, or process.spawn, which links the new process to its parent. The two now share a fate: when either exits abnormally, the exit signal kills the other."
    Monitor ->
      "process.monitor: A watches B. When B exits, for any reason, A gets a ProcessDown message and carries on. Nothing travels the other way."
    TrappedLink ->
      "A link, and A has called process.trap_exits(True). Exit signals from B no longer kill A: they arrive as ExitMessage values in A's mailbox. A supervisor is exactly this."
  }
}

pub fn status_label(status: Status) -> String {
  case status {
    Alive -> "running"
    Crashed -> "crashed"
    Finished -> "finished"
    KilledByLink -> "killed by the link"
  }
}

/// What the last ending showed, in one sentence.
pub fn lesson(pair: Pair) -> String {
  case pair.last, pair.bond {
    None, _ -> "Pick a bond, then end one of the processes."
    Some(BCrashes), Link ->
      "A link shares fate: B's abnormal exit killed A, which did nothing wrong."
    Some(BCrashes), Monitor ->
      "A monitor only observes: A learned that B died, and why, and kept running."
    Some(BCrashes), TrappedLink ->
      "Trapping turned a lethal signal into an ordinary message. That is all a supervisor needs to restart a child."
    Some(BFinishes), Link ->
      "A normal exit kills nobody: the link delivers the exit signal, but a process that does not trap exits ignores a normal one."
    Some(BFinishes), _ ->
      "Watchers hear about normal exits too, so they can tell a finished job from a crash."
    Some(ACrashes), Link -> "Links work both ways: A's crash took B down."
    Some(ACrashes), Monitor ->
      "A monitor is one way: A's crash meant nothing to B."
    Some(ACrashes), TrappedLink ->
      "Trapping protects only the process that traps. B was not trapping, so A's crash killed it."
  }
}
