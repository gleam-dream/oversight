//// Pull the plug: a Fabric run is mid-way through when the VM dies. What
//// survives depends on the store's backend and on whether a tool call was
//// talking to the outside world at that moment.

pub type Store {
  InMemory
  Directory
  Postgres
}

pub const stores = [InMemory, Directory, Postgres]

pub type Flight {
  RefundInFlight
  NothingInFlight
}

pub type Vm {
  Running
  Killed
}

pub type Plug {
  Plug(store: Store, flight: Flight, vm: Vm)
}

/// What the reader sees about the in-flight refund after the VM died.
pub type Refund {
  NotKilledYet
  NothingWasInFlight
  LostWithTheRecord
  MarkedUncertain
}

pub fn new() -> Plug {
  Plug(store: Directory, flight: RefundInFlight, vm: Running)
}

/// Choosing another backend starts the scenario again with a live VM.
pub fn pick_store(plug: Plug, store: Store) -> Plug {
  Plug(..plug, store:, vm: Running)
}

pub fn toggle_flight(plug: Plug) -> Plug {
  let flight = case plug.flight {
    RefundInFlight -> NothingInFlight
    NothingInFlight -> RefundInFlight
  }
  Plug(..plug, flight:, vm: Running)
}

pub fn kill(plug: Plug) -> Plug {
  Plug(..plug, vm: Killed)
}

pub fn store_label(store: Store) -> String {
  case store {
    InMemory -> "In memory"
    Directory -> "Directory"
    Postgres -> "PostgreSQL"
  }
}

pub fn refund(plug: Plug) -> Refund {
  case plug.vm, plug.flight, plug.store {
    Running, _, _ -> NotKilledYet
    Killed, NothingInFlight, _ -> NothingWasInFlight
    Killed, RefundInFlight, InMemory -> LostWithTheRecord
    Killed, RefundInFlight, _ -> MarkedUncertain
  }
}

pub fn record(plug: Plug) -> String {
  case plug.vm, plug.store {
    Running, _ -> "—"
    Killed, InMemory -> "Gone with the VM."
    Killed, Directory -> "Kept on disk."
    Killed, Postgres -> "Kept in PostgreSQL."
  }
}

pub fn after_restart(plug: Plug) -> String {
  case plug.vm, plug.store {
    Running, _ -> "—"
    Killed, InMemory -> "Nothing to recover."
    Killed, _ -> "Recoverable by run id."
  }
}

pub fn refund_text(refund: Refund) -> String {
  case refund {
    NotKilledYet -> "—"
    NothingWasInFlight -> "Nothing was in flight."
    LostWithTheRecord -> "Unknown, and the record is gone too."
    MarkedUncertain -> "Marked uncertain: blocks dependent work."
  }
}

pub fn why(plug: Plug) -> String {
  case plug.vm {
    Running -> "Choose a backend, then kill the VM."
    Killed -> {
      let restart = case plug.store {
        InMemory ->
          "Nothing to reopen. As far as anyone can tell, the run never happened."
        Directory ->
          "recover(run id) takes over, because the old runner is gone. (Survives a restart on one host, not a power cut.)"
        Postgres ->
          "A leased store checks the old owner is gone, then recover takes over. The production choice."
      }
      restart
      <> case refund(plug) {
        MarkedUncertain ->
          " The in-flight refund may have reached the payment provider without a saved result, so Fabric won’t guess: it blocks whatever depends on it until you reconcile. You can declare a tool safe to replay only when repeating it is harmless."
        LostWithTheRecord -> " Reconcile by hand with the payment provider."
        NothingWasInFlight | NotKilledYet -> ""
      }
    }
  }
}
