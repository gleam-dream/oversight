//// Real Grind and PostgreSQL composition. Only the model port is scripted.

import fabric
import fabric/invoke
import fabric/model
import fabric/run
import fabric/store
import fabric/sweeper
import fabric_postgres
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import grind
import grind/job
import history_delivery as delivery
import pog

pub fn transactional_history_delivery_survives_both_commit_gaps_test() {
  let app = delivery.start()
  let turn = "retained-turn"

  // A rolled-back acceptance publishes neither application state nor a job.
  let rolled_back =
    pog.transaction(app.db, fn(tx) {
      let assert Ok(_) = delivery.accept(app, tx, "rolled-back")
      Error("rollback acceptance")
    })
  let assert Error(_) = rolled_back
  let assert 0 = delivery.turn_count(app.db, "rolled-back")
  let assert 0 = delivery.job_count(app.db)
  let assert 0 = delivery.model_calls(app.db)

  let assert Ok(admission) =
    pog.transaction(app.db, delivery.accept(app, _, turn))
  let handle = grind.handle(admission)
  let assert delivery.BeforeStart(continue) = delivery.next(app)
  let assert 1 = delivery.turn_count(app.db, turn)
  let assert 1 = delivery.job_count(app.db)
  let assert 0 = delivery.run_count(app.db)
  let assert 0 = delivery.model_calls(app.db)
  process.send(continue, delivery.Continue)

  let assert delivery.ModelCalled(False, messages) = delivery.next(app)
  let assert [
    model.UserMessage("List the observations"),
    model.AssistantMessage(model.AssistantTurn("One observation", [], None)),
    model.UserMessage("Summarize those observations"),
  ] = messages
  let assert delivery.BeforeStart(retry) = delivery.next(app)

  // Force a bounded drain while the model has not replied. Recovery belongs
  // to the registered Fabric sweeper, while Grind still holds delivery.
  let assert Ok(Nil) = store.stop(app.runs)
  let assert Ok(Nil) = store.start(app.runs)
  let assert Ok(sweeper_pid) =
    sweeper.start(
      app.runs,
      [sweeper.agent(app.agent, context: fn(_) { True })],
      every: duration.milliseconds(25),
    )
  process.unlink(sweeper_pid)
  let assert delivery.ModelCalled(True, recovered_messages) = delivery.next(app)
  let assert True = recovered_messages == messages
  process.send(retry, delivery.Continue)

  let assert delivery.BeforeApply(id, apply) = delivery.next(app)
  let duplicate = delivery.invoke_turn(app, turn)
  let assert invoke.Answered = invoke.response_kind(duplicate)
  let assert True = invoke.id(duplicate) == id
  let assert Some("One observation summarized") = invoke.answer(duplicate)
  let assert 0 = delivery.application_count(app.db, turn)
  let assert 2 = delivery.model_calls(app.db)
  let assert Ok(opened) = fabric.open(app.runs, app.agent, True, id)
  let assert Ok(snapshot) = fabric.snapshot(opened)
  let assert run.Finished(run.Completed("One observation summarized")) =
    snapshot.status
  let assert True = snapshot.incarnation > 0
  let assert Ok(generated) = fabric.generated_messages(opened)
  let assert [
    model.AssistantMessage(model.AssistantTurn(
      "One observation summarized",
      [],
      None,
    )),
  ] = generated

  // An application transaction can fail after its write; no applied marker
  // or generated messages become visible until that transaction commits.
  let rollback_apply =
    pog.transaction(app.db, fn(tx) {
      let assert Ok(_) =
        delivery.incorporate(
          tx,
          turn,
          id,
          "One observation summarized",
          generated,
        )
      Error("rollback incorporation")
    })
  let assert Error(_) = rollback_apply
  let assert 0 = delivery.application_count(app.db, turn)
  process.send(apply, delivery.Continue)

  let assert delivery.AfterApply(lost_reply) = delivery.next(app)
  let assert 1 = delivery.application_count(app.db, turn)
  let assert True = delivery.saved_messages(app.db, turn) == generated
  // This is a deterministic caller-reply loss after a real commit, not a
  // PostgreSQL network-fault claim. The next Grind delivery reads the marker.
  process.send(lost_reply, delivery.LoseReply)
  let assert Ok(grind.Succeeded("One observation summarized")) =
    grind.await(app.jobs, handle, within: duration.seconds(10))
  let assert 1 = delivery.application_count(app.db, turn)

  // Pruning was disabled until application incorporation. The marker remains
  // authoritative after the retained Fabric record is deliberately removed.
  let assert Ok(1) =
    fabric_postgres.prune(
      app.backend,
      ended_for: duration.milliseconds(0),
      limit: 10,
    )
  let assert 0 = delivery.run_count(app.db)
  let assert Ok(redelivery) = grind.submit(app.jobs, job.new(app.worker, turn))
  let assert Ok(grind.Succeeded("One observation summarized")) =
    grind.await(
      app.jobs,
      grind.handle(redelivery),
      within: duration.seconds(10),
    )
  let assert 0 = delivery.run_count(app.db)
  let assert 2 = delivery.model_calls(app.db)
  let assert 1 = delivery.application_count(app.db, turn)
  let assert True = delivery.saved_messages(app.db, turn) == generated
  let assert Error(Nil) = process.receive(app.notices, within: 0)
  delivery.stop(app)
}
