//// The "Restart types" playground: one child under a supervisor, its
//// gleam_otp restart type (`supervision.restart`), and whether the child
//// comes back when it ends. The reader fills in the table by trying each
//// combination.

import gleam/list
import gleam/option.{type Option, None, Some}

pub type RestartType {
  Permanent
  Transient
  Temporary
}

pub const restart_types = [Permanent, Transient, Temporary]

/// How the child ends.
pub type Ending {
  /// The actor stops normally: its work is done.
  FinishesNormally
  /// The actor exits abnormally: a panic, a failed assertion, a kill.
  Crashes
}

pub const endings = [FinishesNormally, Crashes]

pub type Fate {
  Restarted
  Removed
}

pub type Trial {
  Trial(restart: RestartType, ending: Ending)
}

pub type Table {
  Table(restart: RestartType, tried: List(Trial), last: Option(Trial))
}

pub fn new() -> Table {
  Table(restart: Permanent, tried: [], last: None)
}

/// What a supervisor does when a child of this type ends this way.
pub fn fate(restart: RestartType, ending: Ending) -> Fate {
  case restart, ending {
    Permanent, _ -> Restarted
    Transient, Crashes -> Restarted
    Transient, FinishesNormally -> Removed
    Temporary, _ -> Removed
  }
}

pub fn pick(table: Table, restart: RestartType) -> Table {
  Table(..table, restart:, last: None)
}

pub fn try(table: Table, ending: Ending) -> Table {
  let trial = Trial(table.restart, ending)
  let tried = case list.contains(table.tried, trial) {
    True -> table.tried
    False -> [trial, ..table.tried]
  }
  Table(..table, tried:, last: Some(trial))
}

pub fn reset(_table: Table) -> Table {
  new()
}

pub fn revealed(table: Table, restart: RestartType, ending: Ending) -> Bool {
  list.contains(table.tried, Trial(restart, ending))
}

pub fn remaining(table: Table) -> Int {
  list.length(restart_types) * list.length(endings) - list.length(table.tried)
}

pub fn restart_name(restart: RestartType) -> String {
  case restart {
    Permanent -> "Permanent"
    Transient -> "Transient"
    Temporary -> "Temporary"
  }
}

pub fn restart_use(restart: RestartType) -> String {
  case restart {
    Permanent ->
      "the default: a service that must always run, such as a pool or a cache"
    Transient -> "a job that may finish, but must be retried if it crashes"
    Temporary ->
      "work whose failure the caller handles, such as one request or one task"
  }
}

pub fn ending_name(ending: Ending) -> String {
  case ending {
    FinishesNormally -> "finishes normally"
    Crashes -> "crashes"
  }
}

pub fn fate_name(fate: Fate) -> String {
  case fate {
    Restarted -> "restarted"
    Removed -> "removed"
  }
}

/// What the last trial showed, in one sentence.
pub fn lesson(table: Table) -> String {
  case table.last {
    None ->
      "Pick a restart type, then end the child. The table fills in as you go."
    Some(Trial(Permanent, FinishesNormally)) ->
      "Permanent means always: even a child that finished its work is started again. A permanent child that keeps finishing will exhaust the restart tolerance."
    Some(Trial(Permanent, Crashes)) ->
      "Permanent: the supervisor starts the child again from its initial state."
    Some(Trial(Transient, FinishesNormally)) ->
      "Transient: a normal exit means the job is done, so the supervisor removes the child."
    Some(Trial(Transient, Crashes)) ->
      "Transient: an abnormal exit means the job did not get done, so the supervisor restarts it."
    Some(Trial(Temporary, _)) ->
      "Temporary: never restarted, however it ends, and not even when a one-for-all or rest-for-one sibling's crash stopped it."
  }
}
