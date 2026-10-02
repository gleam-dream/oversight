//// Live deliveries to the loopback receiver, driven by a manual grind
//// consumer. Needs DATABASE_URL (../scripts/with-postgres.sh gleam test).

import gleam/int
import gleam/list
import gleam/string
import grind/job
import grind/postgres
import grind/queue
import grind/worker
import webhooks/attempt
import webhooks/jobs
import webhooks/receiver
import webhooks/signing
import webhooks/store
import webhooks/subscription
import webhooks/support
import webhooks/telemetry

pub fn common_path_signed_delivery_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()
  let assert Ok(#(sub_id, secret)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/ok"))
  let raw =
    "{\"tenant\":\"ops\",\"type\":\"order.created\",\"id\":\"evt_1\",\"data\":{\"order\":42}}"
  let assert [#(delivery_id, job_id)] = support.publish(svc, raw)
  assert delivery_id == "evt_1:" <> sub_id

  use consumer <- support.with_consumer(svc)
  assert queue.process_one(consumer) == Ok(True)
  assert jobs.outcome(svc.jobs, svc.worker, job_id)
    == Ok(job.SucceededWith(attempt.Receipt(204, attempt.BodyRead(0))))

  // The receiver got one signed request carrying the idempotency key.
  let assert [request] = receiver.received(rx)
  let assert Ok(id) = list.key_find(request.headers, signing.id_header)
  let assert Ok(ts) = list.key_find(request.headers, signing.timestamp_header)
  let assert Ok(signature) =
    list.key_find(request.headers, signing.signature_header)
  let assert Ok(ts) = int.parse(ts)
  assert id == delivery_id
  assert request.body == <<raw:utf8>>
  assert signing.verify(secret, id, ts, request.body, signature)

  // Publishing the same event id again converges on the same job.
  assert support.publish(svc, raw) == [#(delivery_id, job_id)]
  assert queue.process_one(consumer) == Ok(False)

  // Grind defect evidence (WHK-2): the worker cannot re-bind its own
  // succeeded job, because the success ACK nulls error_version.
  let assert Error(postgres.CodecContractMismatch(
    kind: worker.ErrorCodec,
    expected: "delivery-error-v1",
    actual: "none",
  )) = postgres.bind_handle(svc.jobs, svc.worker, job_id)

  // One delivery can be followed across grind, http_gun and the app, but
  // only through the app's own join tables.
  support.settle()
  let names =
    telemetry.trace(svc.collector, delivery_id) |> list.map(fn(l) { l.name })
  assert list.contains(names, "grind.job.admitted")
  assert list.contains(names, "grind.job.claimed")
  assert list.contains(names, "grind.job.acknowledged")
  assert list.contains(names, "http_gun.lifecycle")
  assert list.contains(names, "webhooks.delivery.attempted")
}

pub fn receiver_down_retries_then_exhausts_test() {
  use svc <- support.with_service(support.options())
  // Nothing listens on port 1.
  let assert Ok(_) = support.subscribe(svc, "ops", "http://127.0.0.1:1/hook")
  let assert [#(delivery_id, job_id)] =
    support.publish(
      svc,
      "{\"tenant\":\"ops\",\"type\":\"ping\",\"id\":\"evt_down\",\"data\":null}",
    )
  use consumer <- support.with_consumer(svc)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(False)
  assert jobs.outcome(svc.jobs, svc.worker, job_id)
    == Ok(job.BusinessFailedWithCause(
      attempt.Transport("connection_failed.connection_refused"),
      worker.BudgetExhausted,
    ))
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 3
}

pub fn ssrf_rejected_at_registration_and_at_delivery_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()

  // Registration refuses IP literals outside the public range.
  let assert Error(#(422, _)) =
    support.subscribe(svc, "acme", "https://169.254.169.254/latest/meta-data")
  let assert Error(#(422, _)) =
    support.subscribe(svc, "acme", "https://10.0.0.5/hook")
  let assert Error(#(422, _)) =
    support.subscribe(
      svc,
      "acme",
      "https://127.0.0.1:" <> int.to_string(receiver.port(rx)) <> "/ok",
    )

  // DNS rebinding: the name registers, but its answer includes 10.0.0.7.
  let assert Ok(#(rebind_id, _)) =
    support.subscribe(svc, "acme", "https://rebind.acme.test/hook")
  // A loopback subscription that slipped past registration (inserted
  // directly) is still refused by the public tier's client.
  let assert Ok(Nil) =
    store.insert_subscription(
      svc.db,
      subscription.Subscription(
        id: "sub_sneaky",
        tenant: "acme",
        url: receiver.url(rx, "/ok"),
        secret: "whsec_sneaky",
        status: subscription.Active,
      ),
    )
  // The same loopback URL is fine for the internal tenant.
  let assert Ok(_) = support.subscribe(svc, "ops", receiver.url(rx, "/ok"))

  let acme =
    support.publish(
      svc,
      "{\"tenant\":\"acme\",\"type\":\"invoice.paid\",\"id\":\"evt_a\",\"data\":{}}",
    )
  let ops =
    support.publish(
      svc,
      "{\"tenant\":\"ops\",\"type\":\"invoice.paid\",\"id\":\"evt_o\",\"data\":{}}",
    )
  assert list.length(acme) == 2
  use consumer <- support.with_consumer(svc)
  assert queue.process_available(consumer) == queue.BatchCompleted(1)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(False)

  list.each(acme, fn(entry) {
    assert jobs.outcome(svc.jobs, svc.worker, entry.1)
      == Ok(job.DiscardedWithReason("destination rejected by policy"))
  })
  let assert [#(_, ops_job)] = ops
  let assert Ok(job.SucceededWith(_)) =
    jobs.outcome(svc.jobs, svc.worker, ops_job)
  // Only the internal tenant's request reached the receiver.
  let assert [only] = receiver.received(rx)
  assert string.starts_with(
    list.key_find(only.headers, signing.id_header) |> unwrap_text,
    "evt_o:",
  )
  // Refusal disables the subscription; the next event skips it.
  let assert Ok(subscription.Subscription(
    status: subscription.Disabled("destination rejected by policy"),
    ..,
  )) = store.get_subscription(svc.db, rebind_id)
  assert support.publish(
      svc,
      "{\"tenant\":\"acme\",\"type\":\"invoice.paid\",\"id\":\"evt_b\",\"data\":{}}",
    )
    == []
}

fn unwrap_text(value: Result(String, Nil)) -> String {
  case value {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}
