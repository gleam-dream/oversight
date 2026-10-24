import archive_fixture as fixture
import archive_release/archive
import archive_release/auth
import archive_release/domain
import archive_release/driver
import fabric
import fabric/approvers
import fabric/reviewer
import fabric/run
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit
import gleeunit/should
import hellhound/testing
import json/blueprint/codec
import relay/authorization

pub fn main() {
  gleeunit.main()
}

pub fn ordinary_public_release_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "ordinary", "public minutes")
  let context =
    archive.context(f.db, f.principal, "ordinary", domain.EmbargoOnly)
  let agent =
    driver.build(
      context.document,
      context.principal,
      auth.approvers(f.validator),
    )
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  finished(handle)
  let assert run.Succeeded(raw) = action(handle).state
  codec.decode_json(domain.release_codec(), raw)
  |> should.equal(
    Ok(domain.Release("ordinary", domain.Revision(1), f.principal)),
  )
  archive.releases(f.db, "ordinary")
  |> should.equal([#(1, "public minutes", "archivist")])
}

pub fn configurable_approval_and_reviewer_attribution_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "configured", "public minutes")
  // The same public content now requires approval under the stricter app policy.
  let context =
    archive.context(f.db, f.principal, "configured", domain.EveryRelease)
  let gate =
    auth.approvers(f.validator)
    |> approvers.with_proof_lifetime(run.After(duration.seconds(5)))
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let pending = pending(handle)
  archive.releases(f.db, "configured") |> should.equal([])
  let proof = proof(f, gate, pending)
  let assert Ok(_) = fabric.approve(handle, pending.reference, proof:, context:)
  finished(handle)
  archive.releases(f.db, "configured")
  |> should.equal([#(1, "public minutes", "archivist")])
  let assert [approval] = action(handle).approvals
  let assert Some(answerer) = approval.reviewer
  reviewer.subject(answerer) |> should.equal("archivist")
  reviewer.issuer(answerer) |> should.equal(Some(f.principal.issuer))
  approval.verifier |> should.equal(Some("archive-hellhound"))
}

pub fn stale_approval_does_not_release_replacement_content_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "stale", "embargoed minutes")
  let context = archive.context(f.db, f.principal, "stale", domain.EmbargoOnly)
  let gate = auth.approvers(f.validator)
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let pending = pending(handle)
  archive.execute(
    f.db,
    "UPDATE archive_documents SET revision=2, content='replacement minutes' WHERE id='stale'",
  )
  let current = archive.context(f.db, f.principal, "stale", domain.EmbargoOnly)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, proof(f, gate, pending), current)
  finished(handle)
  action(handle).state |> should.equal(run.Denied("stale document revision"))
  archive.releases(f.db, "stale") |> should.equal([])
}

pub fn revoked_application_permission_wins_over_valid_proof_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "revoked", "embargoed minutes")
  let context =
    archive.context(f.db, f.principal, "revoked", domain.EmbargoOnly)
  let gate = auth.approvers(f.validator)
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let pending = pending(handle)
  archive.execute(
    f.db,
    "DELETE FROM archive_permissions WHERE document='revoked'",
  )
  let current =
    archive.context(f.db, f.principal, "revoked", domain.EmbargoOnly)
  // JWT and approval scope remain valid. The app permission is a separate authority.
  let assert Ok(_) = auth.admit(f.validator, f.token)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, proof(f, gate, pending), current)
  finished(handle)
  action(handle).state |> should.equal(run.Denied("current permission revoked"))
  archive.releases(f.db, "revoked") |> should.equal([])
}

pub fn cancellation_and_admission_refusal_are_distinct_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  let no_scope = fixture.token(f.provider, [])
  let assert Error(authorization.MissingEndpointScope(_)) =
    auth.admit(f.validator, no_scope)
  let forged =
    testing.issue_access_token(
      f.provider,
      testing.access_token("archivist")
        |> testing.with_audiences([auth.audience])
        |> testing.forged(testing.UnsignedToken),
    )
  auth.admit(f.validator, forged)
  |> should.equal(
    Error(authorization.VerificationFailed(authorization.BearerRejected)),
  )
  let other_audience =
    testing.issue_access_token(
      f.provider,
      testing.access_token("archivist")
        |> testing.with_audiences(["https://other.test"]),
    )
  auth.admit(f.validator, other_audience)
  |> should.equal(
    Error(authorization.VerificationFailed(
      authorization.IssuedForAnotherResource,
    )),
  )
  archive.seed(f.db, f.principal, "cancelled", "embargoed minutes")
  let context =
    archive.context(f.db, f.principal, "cancelled", domain.EmbargoOnly)
  let gate = auth.approvers(f.validator)
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let pending = pending(handle)
  let assert Error(approvers.NotAuthorized(_)) =
    approvers.check(gate, no_scope, pending.reference.requirement)
  let assert Ok(_) = fabric.cancel(handle)
  fabric.await(handle, duration.seconds(10))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.approve(handle, pending.reference, proof(f, gate, pending), context)
  |> should.equal(Error(fabric.RunEnded))
  archive.releases(f.db, "cancelled") |> should.equal([])
}

pub fn a_new_driver_resumes_durable_approval_without_duplicate_release_test() {
  use f <- fixture.using
  archive.seed(f.db, f.principal, "restarted", "embargoed minutes")
  let original =
    archive.context(f.db, f.principal, "restarted", domain.EmbargoOnly)
  let #(id, reference) =
    fixture.using_store(f.settings, fn(runs) {
      let agent =
        driver.build(
          original.document,
          original.principal,
          auth.approvers(f.validator),
        )
      let assert Ok(handle) =
        fabric.start(runs, agent, run.new_id(), original, "release", None)
      #(fabric.id(handle), pending(handle).reference)
    })
  archive.releases(f.db, "restarted") |> should.equal([])
  // A new store, agent and approver instance: only the stored reference survives.
  fixture.using_store(f.settings, fn(runs) {
    let gate = auth.approvers(f.validator)
    let context =
      archive.context(f.db, f.principal, "restarted", domain.EmbargoOnly)
    let agent = driver.build(context.document, context.principal, gate)
    let assert Ok(handle) = fabric.open(runs, agent, context, id)
    let waiting = pending(handle)
    waiting.reference |> should.equal(reference)
    let assert Ok(_) =
      fabric.approve(handle, reference, proof(f, gate, waiting), context)
    finished(handle)
    let assert run.Succeeded(_) = action(handle).state
    archive.releases(f.db, "restarted")
    |> should.equal([#(1, "embargoed minutes", "archivist")])
  })
  fixture.using_store(f.settings, fn(runs) {
    let agent =
      driver.build(
        original.document,
        original.principal,
        auth.approvers(f.validator),
      )
    let assert Ok(handle) = fabric.open(runs, agent, original, id)
    finished(handle)
    action(handle).replays |> should.equal(0)
    archive.releases(f.db, "restarted")
    |> should.equal([#(1, "embargoed minutes", "archivist")])
  })
}

pub fn write_boundary_refuses_stale_authority_even_if_caller_reuses_context_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "stale-context", "embargoed minutes")
  let context =
    archive.context(f.db, f.principal, "stale-context", domain.EmbargoOnly)
  let gate = auth.approvers(f.validator)
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let pending = pending(handle)
  archive.execute(
    f.db,
    "DELETE FROM archive_permissions WHERE document='stale-context'",
  )
  // Deliberately violate the app's refresh convention: SQL is the final guard.
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, proof(f, gate, pending), context)
  finished(handle)
  let assert run.ToolFailed(_) = action(handle).state
  archive.releases(f.db, "stale-context") |> should.equal([])
}

fn pending(handle: fabric.Run(archive.Context, String)) -> run.PendingApproval {
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, duration.seconds(10))
  pending
}

fn finished(handle: fabric.Run(archive.Context, String)) -> Nil {
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, duration.seconds(10))
  Nil
}

fn action(handle: fabric.Run(archive.Context, String)) -> run.ActionRecord {
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [action] = snapshot.actions
  action
}

fn proof(
  f: fixture.Fixture,
  gate: approvers.Approvers(String),
  pending: run.PendingApproval,
) -> approvers.Proof {
  let assert Ok(proof) =
    approvers.check(gate, f.token, pending.reference.requirement)
  proof
}

// Adversarial discovery: a valid delegated identity must not replace the requester.
pub fn delayed_release_cannot_substitute_authenticated_requester_test() {
  use f <- fixture.using
  use runs <- fixture.using_store(f.settings)
  archive.seed(f.db, f.principal, "substitution", "embargoed minutes")
  let context =
    archive.context(f.db, f.principal, "substitution", domain.EmbargoOnly)
  let gate = auth.approvers(f.validator)
  let agent = driver.build(context.document, context.principal, gate)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "release", None)
  let waiting = pending(handle)
  let delegate_token =
    testing.issue_access_token(
      f.provider,
      testing.access_token("delegate")
        |> testing.with_audiences([auth.audience])
        |> testing.with_scopes(["archive:release"]),
    )
  let assert Ok(substitute) = auth.admit(f.validator, delegate_token)
  archive.execute(
    f.db,
    "INSERT INTO archive_permissions SELECT issuer, 'delegate', document FROM archive_permissions WHERE document='substitution'",
  )
  let changed =
    archive.context(f.db, substitute, "substitution", domain.EmbargoOnly)
  changed.permission |> should.be_true
  let assert Ok(_) =
    fabric.approve(handle, waiting.reference, proof(f, gate, waiting), changed)
  finished(handle)
  action(handle).state |> should.equal(run.Denied("requester identity changed"))
  archive.releases(f.db, "substitution") |> should.equal([])
}
