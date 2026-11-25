//// Live deliveries to the loopback receiver; due jobs run on demand with
//// `grind/testing.drain`. Needs DATABASE_URL
//// (../scripts/with-postgres.sh gleam test).

import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import grind
import grind/job
import http_gun/error
import pog
import webhooks/attempt
import webhooks/delivery
import webhooks/receiver
import webhooks/service
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
  receiver.trust(rx, "/ok", secret)
  let raw =
    "{\"type\":\"order.created\",\"id\":\"evt_1\",\"data\":{\"order\":42}}"
  let assert [#(delivery_id, job_id)] = support.publish(svc, "ops", raw)
  assert delivery_id == "evt_1:" <> sub_id

  assert support.drain(svc) == Ok(1)
  assert support.outcome(svc, job_id)
    == Ok(grind.Succeeded(attempt.Receipt(204, attempt.BodyRead(0))))

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
  assert request.verdict == receiver.Processed(204)

  // The delivery id is the receiver's idempotency key: a captured copy of
  // the delivery, replayed byte for byte, is acknowledged without running
  // the endpoint again.
  assert support.post(receiver.port(rx), "/ok", request.headers, request.body)
    == 204
  let assert [_, replayed] = receiver.received(rx)
  assert replayed.verdict == receiver.Duplicate

  // Publishing the same event id again converges on the same job.
  assert support.publish(svc, "ops", raw) == [#(delivery_id, job_id)]
  assert support.drain(svc) == Ok(0)

  // The worker itself, error codec included, re-binds its own
  // succeeded job; `await` returns at once for a finished job.
  let assert Ok(handle) = grind.bind(svc.jobs, svc.worker, job_id)
  assert grind.await(svc.jobs, handle, within: duration.seconds(1))
    == Ok(grind.Succeeded(attempt.Receipt(204, attempt.BodyRead(0))))
  // The delivery row was written in the job's transaction.
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.job_id == job_id && row.attempts == 1

  // One delivery is followed across grind, http_gun and the app by
  // its correlation alone, in emit order: claim, request, attempt, ack.
  // `submit_in` emits no `admitted` event; the commit is the app's.
  support.settle()
  let names =
    telemetry.trace(svc.collector, delivery_id)
    |> list.map(fn(l) { l.name })
    |> list.filter(fn(name) { name != "grind.diag.renewal" })
    |> list.unique
  assert names
    == [
      "grind.job.claimed", "http_gun.lifecycle", "webhooks.delivery.attempted",
      "grind.job.acknowledged",
    ]
}

pub fn receiver_down_retries_then_exhausts_test() {
  use svc <- support.with_service(support.options())
  // Nothing listens on port 1.
  let assert Ok(_) = support.subscribe(svc, "ops", "http://127.0.0.1:1/hook")
  let assert [#(delivery_id, job_id)] =
    support.publish(
      svc,
      "ops",
      "{\"type\":\"ping\",\"id\":\"evt_down\",\"data\":null}",
    )
  assert support.drain(svc) == Ok(3)
  // The typed http_gun failure survives the job's error codec.
  let assert Ok(grind.Failed(
    grind.Business(attempt.Http(failure)),
    Some(job.BudgetExhausted),
    _,
  )) = support.outcome(svc, job_id)
  assert error.name(failure) == "connection_failed.connection_refused"
  assert error.evidence(failure) == error.NotSent
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 3
}

/// A receiver that always answers 429 is snoozed `max_snoozes` times
/// (read from the job's context), then each 429 uses an attempt, so the
/// delivery ends instead of snoozing forever.
pub fn always_throttled_receiver_stops_test() {
  let options = support.options()
  let plan =
    delivery.Plan(
      ..options.plan,
      snooze: attempt.SnoozePolicy(..attempt.default_snooze(), max_snoozes: 2),
    )
  use svc <- support.with_service(service.Options(..options, plan:))
  let rx = receiver.start()
  let assert Ok(#(_, secret)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/throttled"))
  receiver.trust(rx, "/throttled", secret)
  let assert [#(delivery_id, job_id)] =
    support.publish(
      svc,
      "ops",
      "{\"type\":\"ping\",\"id\":\"evt_429\",\"data\":null}",
    )
  // 2 snoozes, then 3 attempts.
  assert support.drain(svc) == Ok(5)
  assert support.outcome(svc, job_id)
    == Ok(grind.Failed(
      grind.Business(attempt.RateLimited),
      Some(job.BudgetExhausted),
      "worker returned an application error",
    ))
  // Every attempt was verified and ran the endpoint; none was a duplicate.
  assert list.map(receiver.received(rx), fn(r) { r.verdict })
    == list.repeat(receiver.Processed(429), 5)
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 5
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
  let assert Ok(#(_, secret)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/ok"))
  receiver.trust(rx, "/ok", secret)

  let acme =
    support.publish(
      svc,
      "acme",
      "{\"type\":\"invoice.paid\",\"id\":\"evt_a\",\"data\":{}}",
    )
  let ops =
    support.publish(
      svc,
      "ops",
      "{\"type\":\"invoice.paid\",\"id\":\"evt_o\",\"data\":{}}",
    )
  assert list.length(acme) == 2
  assert support.drain(svc) == Ok(3)

  list.each(acme, fn(entry) {
    assert support.outcome(svc, entry.1)
      == Ok(grind.Discarded("destination rejected by policy"))
  })
  let assert [#(_, ops_job)] = ops
  let assert Ok(grind.Succeeded(_)) = support.outcome(svc, ops_job)
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
      "acme",
      "{\"type\":\"invoice.paid\",\"id\":\"evt_b\",\"data\":{}}",
    )
    == []
}

/// Makes every update of `table` whose row `id` names fail, the way a
/// database fault would. Returns the function that removes the fault.
fn refuse_update(db: pog.Connection, table: String, id: String) -> fn() -> Nil {
  let run = fn(sql) {
    let assert Ok(_) = pog.query(sql) |> pog.execute(db)
    Nil
  }
  run(
    "CREATE FUNCTION refuse_update() RETURNS trigger AS $$
     BEGIN RAISE EXCEPTION 'store fault'; END $$ LANGUAGE plpgsql",
  )
  run("CREATE TRIGGER refuse_update BEFORE UPDATE ON " <> table <> "
     FOR EACH ROW WHEN (OLD.id = '" <> id <> "')
     EXECUTE FUNCTION refuse_update()")
  fn() {
    run("DROP TRIGGER refuse_update ON " <> table)
    run("DROP FUNCTION refuse_update()")
  }
}

/// A delivery whose attempt cannot be recorded does not settle: the
/// tenant's delivery record would show no attempt for a delivery Grind
/// calls done. The next attempt sends again, the receiver acknowledges the
/// duplicate by its delivery id, and the record shows that one attempt.
pub fn unrecorded_attempt_does_not_settle_the_delivery_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()
  let assert Ok(#(_, secret)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/ok"))
  receiver.trust(rx, "/ok", secret)
  let assert [#(delivery_id, job_id)] =
    support.publish(
      svc,
      "ops",
      "{\"type\":\"ping\",\"id\":\"evt_unrecorded\",\"data\":null}",
    )
  let restore = refuse_update(svc.db, "webhook_deliveries", delivery_id)
  assert support.drain_up_to(svc, 1) == Ok(1)
  let outcome = support.outcome(svc, job_id)
  restore()
  let assert Ok(grind.Pending(_)) = outcome

  assert support.drain(svc) == Ok(1)
  assert support.outcome(svc, job_id)
    == Ok(grind.Succeeded(attempt.Receipt(204, attempt.BodyRead(0))))
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 1
  let assert [_, again] = receiver.received(rx)
  assert again.verdict == receiver.Duplicate
}

/// A gone endpoint whose subscription cannot be disabled does not discard
/// the delivery: the subscription would keep receiving. The attempt's
/// record and the disablement commit together, once.
pub fn undisabled_gone_endpoint_does_not_discard_the_delivery_test() {
  use svc <- support.with_service(support.options())
  let rx = receiver.start()
  let assert Ok(#(sub_id, secret)) =
    support.subscribe(svc, "ops", receiver.url(rx, "/gone"))
  receiver.trust(rx, "/gone", secret)
  let assert [#(delivery_id, job_id)] =
    support.publish(
      svc,
      "ops",
      "{\"type\":\"ping\",\"id\":\"evt_undisabled\",\"data\":null}",
    )
  let restore = refuse_update(svc.db, "webhook_subscriptions", sub_id)
  assert support.drain_up_to(svc, 1) == Ok(1)
  let outcome = support.outcome(svc, job_id)
  let subscribed = store.get_subscription(svc.db, sub_id)
  restore()
  let assert Ok(grind.Pending(_)) = outcome
  let assert Ok(subscription.Subscription(status: subscription.Active, ..)) =
    subscribed

  assert support.drain(svc) == Ok(1)
  let assert Ok(grind.Discarded(_)) = support.outcome(svc, job_id)
  let assert Ok(subscription.Subscription(status: subscription.Disabled(_), ..)) =
    store.get_subscription(svc.db, sub_id)
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 1
}

fn unwrap_text(value: Result(String, Nil)) -> String {
  case value {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}
