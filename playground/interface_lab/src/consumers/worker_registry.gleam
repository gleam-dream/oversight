// THROWAWAY: Can application workers be selected by full route and version?
import lab/blueprint
import lab/grind
import lab/grind_registry as worker_registry
import lab/value

type CapturedAdmission {
  NoCapturedAdmission
  HasCapturedAdmission(grind.Admission)
}

type ProbeState {
  ProbeState(admission: CapturedAdmission, handler_calls: Int)
}

@external(erlang, "sinal_scripted_backend", "get")
fn get_probe_state(key: Int, default: ProbeState) -> ProbeState

@external(erlang, "sinal_scripted_backend", "put")
fn put_probe_state(key: Int, state: ProbeState) -> Nil

@external(erlang, "erlang", "unique_integer")
fn fresh_probe_key() -> Int

pub fn probe() -> Nil {
  let route_a = route("tenant-a", "payments")
  let route_b = route("tenant-b", "payments")
  let invoice_id = must_worker_id("invoice")
  let audit_id = must_worker_id("audit")
  let admission_key = fresh_probe_key()
  put_probe_state(admission_key, ProbeState(NoCapturedAdmission, 0))
  let invoice_v1 = invoice_worker(1, admission_key)
  let invoice_v2 = invoice_text_worker()
  let invoice_for_b = tenant_b_invoice_worker()
  let audit = audit_worker()

  // The same logical queue name remains scoped to each owner.
  let registry = worker_registry.new()
  let registry = must_register(registry, route_a, invoice_v1)
  let registry = must_register(registry, route_a, invoice_v2)
  let registry = must_register(registry, route_a, audit)
  let registry = must_register(registry, route_b, invoice_for_b)
  let registrations = worker_registry.registrations(registry)
  let assert 4 = list_length(registrations)
  let assert True =
    contains_registration(
      registrations,
      worker_registry.RegisteredIdentity(route_a, invoice_id, must_version(1)),
    )
  let assert True =
    contains_registration(
      registrations,
      worker_registry.RegisteredIdentity(route_a, audit_id, must_version(1)),
    )
  let assert True =
    contains_registration(
      registrations,
      worker_registry.RegisteredIdentity(route_b, invoice_id, must_version(1)),
    )

  // Registering the same route, name, and version is rejected without running
  // the worker callback.
  let assert Error(worker_registry.DuplicateRegistration(_)) =
    worker_registry.register(registry, route_a, invoice_v1)

  // Exact version and route select the retained canonical typed worker.
  let selected_v1 = must_select(registry, route_a, invoice_id, must_version(1))
  let selected_v2 = must_select(registry, route_a, invoice_id, must_version(2))
  let selected_audit = must_select(registry, route_a, audit_id, must_version(1))
  let selected_tenant_b =
    must_select(registry, route_b, invoice_id, must_version(1))
  let assert Ok(value.Int(8)) =
    worker_registry.invoke(selected_v1, value.Int(7))
  let assert Ok(value.Text("v2:approved")) =
    worker_registry.invoke(selected_v2, value.Text("approved"))
  let assert Ok(value.Bool(True)) =
    worker_registry.invoke(selected_audit, value.Text("active"))
  let assert Ok(value.Int(1007)) =
    worker_registry.invoke(selected_tenant_b, value.Int(7))

  // Direct typed use remains available alongside erased lookup. Submission
  // records the exact admission without running the handler; later selection
  // invokes that captured payload once.
  let assert Ok(17) = grind.invoke(invoice_v1, 16)
  let accepted = admission_queue(route_a, 41, admission_key)
  let assert Ok(handle) = grind.submit(accepted, invoice_v1, 41)
  let assert "worker-job-41" = grind.job_id_value(grind.job_id_of(handle))
  let ProbeState(captured_after_submit, calls_after_submit) =
    get_probe_state(admission_key, ProbeState(NoCapturedAdmission, 0))
  let assert 0 = calls_after_submit
  let assert HasCapturedAdmission(actual_admission) = captured_after_submit
  let assert grind.Admission(
    admitted_route,
    admitted_worker_name,
    admitted_version_number,
    admitted_payload,
    grind.Immediate,
  ) = actual_admission
  let assert True = grind.same_queue_route(admitted_route, route_a)
  let assert "invoice" = admitted_worker_name
  let assert 1 = admitted_version_number
  let admitted_worker_id = must_worker_id(admitted_worker_name)
  let admitted_version = must_version(admitted_version_number)
  let selected_admitted =
    must_select(registry, admitted_route, admitted_worker_id, admitted_version)
  let assert Ok(value.Int(42)) =
    worker_registry.invoke(selected_admitted, admitted_payload)
  let ProbeState(_, calls_after_invoke) =
    get_probe_state(admission_key, ProbeState(NoCapturedAdmission, 0))
  let assert 1 = calls_after_invoke

  // Route, worker, and version failures stay separate, and selection does not
  // invoke the panic decoder retained by this registration.
  let guarded = must_register(registry, route_a, panic_worker("guarded", 1))
  let assert Ok(_) =
    worker_registry.select(
      guarded,
      route_a,
      must_worker_id("guarded"),
      must_version(1),
    )
  let assert Error(worker_registry.DuplicateRegistration(_)) =
    worker_registry.register(guarded, route_a, panic_worker("guarded", 1))
  let assert Error(worker_registry.WorkerVersionNotRegistered(_, _, _)) =
    worker_registry.select(
      guarded,
      route_a,
      must_worker_id("guarded"),
      must_version(2),
    )
  // Successful lookup itself does not decode, despite retaining this panic
  // worker. The opaque selection is intentionally not invoked here.
  let assert Error(worker_registry.RouteNotRegistered(_)) =
    worker_registry.select(
      guarded,
      route("tenant-c", "payments"),
      must_worker_id("guarded"),
      must_version(1),
    )
  let assert Error(worker_registry.WorkerNotRegistered(_, _)) =
    worker_registry.select(
      guarded,
      route_a,
      must_worker_id("absent"),
      must_version(1),
    )

  // Invocation crosses the existing codec boundary and retains its failures.
  let assert Error(grind.WorkerInputDidNotDecode(_)) =
    worker_registry.invoke(selected_v1, value.Text("not an integer"))
  let rejected_business =
    must_register(registry, route_a, business_failure_worker())
  let selected_failure =
    must_select(
      rejected_business,
      route_a,
      must_worker_id("charge"),
      must_version(1),
    )
  let assert Error(grind.WorkerActionFailed(value.Text("declined"))) =
    worker_registry.invoke(selected_failure, value.Int(0))
  let encode_failure_registry =
    must_register(
      worker_registry.new(),
      route_a,
      output_encoding_failure_worker(),
    )
  let encode_failure =
    must_select(
      encode_failure_registry,
      route_a,
      must_worker_id("bounded-result"),
      must_version(1),
    )
  let assert Error(grind.WorkerOutputDidNotEncode(_)) =
    worker_registry.invoke(encode_failure, value.Int(1))
  let error_encoding_registry =
    must_register(
      worker_registry.new(),
      route_a,
      error_encoding_failure_worker(),
    )
  let error_encoding =
    must_select(
      error_encoding_registry,
      route_a,
      must_worker_id("error-encoding"),
      must_version(1),
    )
  let assert Error(grind.WorkerErrorDidNotEncode(_)) =
    worker_registry.invoke(error_encoding, value.Int(1))
  Nil
}

fn invoice_worker(
  version: Int,
  counter_key: Int,
) -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id("invoice"),
    must_version(version),
    blueprint.int(),
    blueprint.int(),
    blueprint.text(),
    fn(amount) {
      case amount {
        41 -> {
          let ProbeState(admission, calls) =
            get_probe_state(counter_key, ProbeState(NoCapturedAdmission, 0))
          put_probe_state(counter_key, ProbeState(admission, calls + 1))
          Ok(42)
        }
        _ -> Ok(amount + 1)
      }
    },
  )
}

fn invoice_text_worker() -> grind.Worker(String, String, String) {
  grind.worker(
    must_worker_id("invoice"),
    must_version(2),
    blueprint.text(),
    blueprint.text(),
    blueprint.text(),
    fn(status) { Ok("v2:" <> status) },
  )
}

fn tenant_b_invoice_worker() -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id("invoice"),
    must_version(1),
    blueprint.int(),
    blueprint.int(),
    blueprint.text(),
    fn(amount) { Ok(amount + 1000) },
  )
}

fn audit_worker() -> grind.Worker(String, Bool, String) {
  grind.worker(
    must_worker_id("audit"),
    must_version(1),
    blueprint.text(),
    blueprint.bool(),
    blueprint.text(),
    fn(status) { Ok(status == "active") },
  )
}

fn panic_worker(name: String, version: Int) -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id(name),
    must_version(version),
    blueprint.new(fn(number) { Ok(value.Int(number)) }, fn(_) {
      panic as "selection must not decode worker input"
    }),
    blueprint.int(),
    blueprint.text(),
    fn(_) { panic as "selection must not invoke worker handler" },
  )
}

fn business_failure_worker() -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id("charge"),
    must_version(1),
    blueprint.int(),
    blueprint.int(),
    blueprint.text(),
    fn(_) { Error("declined") },
  )
}

fn output_encoding_failure_worker() -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id("bounded-result"),
    must_version(1),
    blueprint.int(),
    blueprint.new(
      fn(number) {
        case number >= 0 {
          True -> Ok(value.Int(number))
          False -> Error(blueprint.CannotEncode("negative result"))
        }
      },
      fn(raw) {
        case raw {
          value.Int(number) -> Ok(number)
          _ -> Error(blueprint.CannotDecode("expected integer"))
        }
      },
    ),
    blueprint.text(),
    fn(_) { Ok(-1) },
  )
}

fn error_encoding_failure_worker() -> grind.Worker(Int, Int, String) {
  grind.worker(
    must_worker_id("error-encoding"),
    must_version(1),
    blueprint.int(),
    blueprint.int(),
    blueprint.new(
      fn(_) { Error(blueprint.CannotEncode("domain error encoding failed")) },
      fn(raw) {
        case raw {
          value.Text(message) -> Ok(message)
          _ -> Error(blueprint.CannotDecode("expected text"))
        }
      },
    ),
    fn(_) { Error("domain failure") },
  )
}

fn admission_queue(
  route: grind.QueueRoute,
  expected_input: Int,
  state_key: Int,
) -> grind.Queue {
  grind.queue(route, fn(admission) {
    case admission {
      grind.Admission(
        actual_route,
        "invoice",
        1,
        value.Int(actual_input),
        grind.Immediate,
      ) ->
        case
          grind.same_queue_route(actual_route, route)
          && actual_input == expected_input
        {
          True -> {
            let ProbeState(_, handler_calls) =
              get_probe_state(state_key, ProbeState(NoCapturedAdmission, 0))
            put_probe_state(
              state_key,
              ProbeState(HasCapturedAdmission(admission), handler_calls),
            )
            Ok(grind.job_id("worker-job-41"))
          }
          False -> Error(grind.AdmissionRejected(value.Text("wrong admission")))
        }
      _ -> Error(grind.AdmissionRejected(value.Text("unexpected admission")))
    }
  })
}

fn must_register(
  registry: worker_registry.Registry,
  route: grind.QueueRoute,
  worker: grind.Worker(i, o, e),
) -> worker_registry.Registry {
  let assert Ok(updated) = worker_registry.register(registry, route, worker)
  updated
}

fn must_select(
  registry: worker_registry.Registry,
  route: grind.QueueRoute,
  worker_id: grind.WorkerId,
  version: grind.WorkerVersion,
) -> worker_registry.SelectedWorker {
  let assert Ok(selected) =
    worker_registry.select(registry, route, worker_id, version)
  selected
}

fn contains_registration(
  registrations: List(worker_registry.RegisteredIdentity),
  expected: worker_registry.RegisteredIdentity,
) -> Bool {
  case registrations {
    [] -> False
    [candidate, ..rest] ->
      case candidate == expected {
        True -> True
        False -> contains_registration(rest, expected)
      }
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn route(owner_value: String, queue_value: String) -> grind.QueueRoute {
  let assert Ok(owner) = grind.queue_owner(owner_value)
  let assert Ok(queue_name) = grind.queue_name(queue_value)
  grind.queue_route(owner, queue_name)
}

fn must_worker_id(name: String) -> grind.WorkerId {
  let assert Ok(id) = grind.worker_id(name)
  id
}

fn must_version(version: Int) -> grind.WorkerVersion {
  let assert Ok(worker_version) = grind.worker_version(version)
  worker_version
}
