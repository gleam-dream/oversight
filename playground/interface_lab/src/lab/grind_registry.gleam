// THROWAWAY: Can an application register typed workers by route and version?
import lab/grind
import lab/value.{type Value}

pub type RegisteredIdentity {
  RegisteredIdentity(
    route: grind.QueueRoute,
    worker_id: grind.WorkerId,
    worker_version: grind.WorkerVersion,
  )
}

type Entry {
  Entry(
    identity: RegisteredIdentity,
    invoke: fn(Value) -> Result(Value, grind.WorkerFailure),
  )
}

pub opaque type Registry {
  Registry(List(Entry))
}

pub type RegistrationError {
  DuplicateRegistration(RegisteredIdentity)
}

pub type SelectionError {
  RouteNotRegistered(grind.QueueRoute)
  WorkerNotRegistered(grind.QueueRoute, grind.WorkerId)
  WorkerVersionNotRegistered(
    grind.QueueRoute,
    grind.WorkerId,
    grind.WorkerVersion,
  )
}

pub opaque type SelectedWorker {
  SelectedWorker(
    identity: RegisteredIdentity,
    invoke: fn(Value) -> Result(Value, grind.WorkerFailure),
  )
}

type EntrySelection {
  EntryNotFound
  EntrySelected(SelectedWorker)
}

pub fn new() -> Registry {
  Registry([])
}

pub fn register(
  registry: Registry,
  route: grind.QueueRoute,
  worker: grind.Worker(i, o, e),
) -> Result(Registry, RegistrationError) {
  let Registry(entries) = registry
  let #(worker_id, worker_version) = grind.worker_identity(worker)
  let identity = RegisteredIdentity(route, worker_id, worker_version)

  case has_identity(identity, entries) {
    True -> Error(DuplicateRegistration(identity))
    False -> {
      let invoke = fn(input) { grind.invoke_value(worker, input) }
      Ok(Registry(append_entry(entries, Entry(identity, invoke))))
    }
  }
}

pub fn registrations(registry: Registry) -> List(RegisteredIdentity) {
  let Registry(entries) = registry
  identities(entries)
}

pub fn select(
  registry: Registry,
  route: grind.QueueRoute,
  worker_id: grind.WorkerId,
  worker_version: grind.WorkerVersion,
) -> Result(SelectedWorker, SelectionError) {
  let Registry(entries) = registry

  case has_route(route, entries) {
    False -> Error(RouteNotRegistered(route))
    True ->
      case has_worker(route, worker_id, entries) {
        False -> Error(WorkerNotRegistered(route, worker_id))
        True ->
          case selected_entry(route, worker_id, worker_version, entries) {
            EntrySelected(selected) -> Ok(selected)
            EntryNotFound ->
              Error(WorkerVersionNotRegistered(route, worker_id, worker_version))
          }
      }
  }
}

pub fn invoke(
  selected: SelectedWorker,
  input: Value,
) -> Result(Value, grind.WorkerFailure) {
  let SelectedWorker(_, invoke) = selected
  invoke(input)
}

fn has_identity(identity: RegisteredIdentity, entries: List(Entry)) -> Bool {
  case entries {
    [] -> False
    [Entry(candidate, _), ..rest] ->
      case same_identity(identity, candidate) {
        True -> True
        False -> has_identity(identity, rest)
      }
  }
}

fn has_route(route: grind.QueueRoute, entries: List(Entry)) -> Bool {
  case entries {
    [] -> False
    [Entry(RegisteredIdentity(candidate, _, _), _), ..rest] ->
      case grind.same_queue_route(route, candidate) {
        True -> True
        False -> has_route(route, rest)
      }
  }
}

fn has_worker(
  route: grind.QueueRoute,
  worker_id: grind.WorkerId,
  entries: List(Entry),
) -> Bool {
  case entries {
    [] -> False
    [Entry(RegisteredIdentity(candidate_route, candidate_id, _), _), ..rest] ->
      case
        grind.same_queue_route(route, candidate_route)
        && worker_id == candidate_id
      {
        True -> True
        False -> has_worker(route, worker_id, rest)
      }
  }
}

fn selected_entry(
  route: grind.QueueRoute,
  worker_id: grind.WorkerId,
  worker_version: grind.WorkerVersion,
  entries: List(Entry),
) -> EntrySelection {
  case entries {
    [] -> EntryNotFound
    [Entry(identity, invoke), ..rest] ->
      case identity {
        RegisteredIdentity(candidate_route, candidate_id, candidate_version) ->
          case
            grind.same_queue_route(route, candidate_route)
            && worker_id == candidate_id
            && worker_version == candidate_version
          {
            True -> EntrySelected(SelectedWorker(identity, invoke))
            False -> selected_entry(route, worker_id, worker_version, rest)
          }
      }
  }
}

fn identities(entries: List(Entry)) -> List(RegisteredIdentity) {
  case entries {
    [] -> []
    [Entry(identity, _), ..rest] -> [identity, ..identities(rest)]
  }
}

fn append_entry(entries: List(Entry), entry: Entry) -> List(Entry) {
  case entries {
    [] -> [entry]
    [first, ..rest] -> [first, ..append_entry(rest, entry)]
  }
}

fn same_identity(left: RegisteredIdentity, right: RegisteredIdentity) -> Bool {
  case left, right {
    RegisteredIdentity(left_route, left_id, left_version),
      RegisteredIdentity(right_route, right_id, right_version)
    ->
      grind.same_queue_route(left_route, right_route)
      && left_id == right_id
      && left_version == right_version
  }
}
