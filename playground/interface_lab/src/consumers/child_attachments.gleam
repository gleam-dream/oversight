// THROWAWAY: Can an independent child be attached with typed, revalidated outcomes?
import lab/blueprint
import lab/saga
import lab/saga_checkpoint as checkpoint
import lab/saga_child_link
import lab/saga_grind
import lab/saga_run_identity as identity
import lab/value

pub type Receipt {
  Receipt(String)
}

pub type ChildError {
  ChildError(String)
}

pub type UndoError {
  UndoError(String)
}

pub fn probe() -> Nil {
  let run_id = identity.run_id("child-71")
  let current_contract =
    contract("checkout-child", 2, "signature-a", #(1, 2, 3, 4))
  let completed =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Text("receipt-71"),
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let owner = owner_with("checkout-owner", run_id, completed)
  let assert Ok(attached) =
    saga_grind.attach_child(owner, current_contract, run_id)
  let link = saga_grind.child_link(attached)
  let link_codec = saga_child_link.codec()
  let assert Ok(link_value) = blueprint.encode(link_codec, link)
  let assert Ok(decoded_link) = blueprint.decode(link_codec, link_value)
  let assert True = decoded_link == link
  let parent_wait =
    checkpoint.ChildWait(must_scoped_step_id(), decoded_link, 12)
  let assert checkpoint.ChildWait(_, checkpointed_link, 12) = parent_wait
  let assert True = checkpointed_link == link

  let claimable =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      11,
      saga_grind.StoredChildCompleted(
        value.Text("receipt-71"),
        saga_grind.StoredCompensationClaimable(1_900_000_000_000),
      ),
    )
  let claimable_owner = owner_with("checkout-owner", run_id, claimable)
  let assert Ok(claimable_handle) =
    saga_grind.attach_child(claimable_owner, current_contract, run_id)
  let assert Ok(saga_grind.ChildCompleted(
    11,
    Receipt("receipt-71"),
    saga_grind.CompensationClaimable(1_900_000_000_000),
  )) = saga_grind.observe_child(claimable_owner, claimable_handle)

  // A fresh deployment rebinds the nongeneric link to its actual typed codecs.
  let fresh_contract =
    contract("checkout-child", 2, "signature-a", #(1, 2, 3, 4))
  let assert Ok(reattached) =
    saga_grind.reattach_child(owner, fresh_contract, decoded_link)
  let assert Ok(saga_grind.ChildCompleted(
    12,
    Receipt("receipt-71"),
    saga_grind.CompensationRequested(saga_grind.CompensationSucceeded),
  )) = saga_grind.observe_child(owner, reattached)

  let queued =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      2,
      saga_grind.StoredChildQueued,
    )
  let queued_owner = owner_with("checkout-owner", run_id, queued)
  let assert Ok(queued_handle) =
    saga_grind.attach_child(queued_owner, current_contract, run_id)
  let assert Ok(saga_grind.ChildQueued(2)) =
    saga_grind.observe_child(queued_owner, queued_handle)

  let running =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      3,
      saga_grind.StoredChildRunning,
    )
  let running_owner = owner_with("checkout-owner", run_id, running)
  let assert Ok(running_handle) =
    saga_grind.attach_child(running_owner, current_contract, run_id)
  let assert Ok(saga_grind.ChildRunning(3)) =
    saga_grind.observe_child(running_owner, running_handle)

  let failed =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      13,
      saga_grind.StoredChildFailed(value.Text("forward-failure"), [
        value.Text("undo-failure"),
      ]),
    )
  let failed_owner = owner_with("checkout-owner", run_id, failed)
  let assert Ok(failed_handle) =
    saga_grind.attach_child(failed_owner, current_contract, run_id)
  let assert Ok(saga_grind.ChildFailed(
    13,
    ChildError("forward-failure"),
    [UndoError("undo-failure")],
  )) = saga_grind.observe_child(failed_owner, failed_handle)

  // Same native result types do not excuse identity, version, signature, or
  // any one of the four independent persisted boundary versions.
  assert_attach_mismatch(
    owner,
    contract("other-definition", 2, "signature-a", #(1, 2, 3, 4)),
    run_id,
    saga_grind.ChildDefinitionIdentityMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 3, "signature-a", #(1, 2, 3, 4)),
    run_id,
    saga_grind.ChildDefinitionVersionMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 2, "signature-b", #(1, 2, 3, 4)),
    run_id,
    saga_grind.ChildSignatureMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 2, "signature-a", #(9, 2, 3, 4)),
    run_id,
    saga_grind.ChildInputCodecVersionMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 2, "signature-a", #(1, 9, 3, 4)),
    run_id,
    saga_grind.ChildOutputCodecVersionMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 2, "signature-a", #(1, 2, 9, 4)),
    run_id,
    saga_grind.ChildErrorCodecVersionMismatch,
  )
  assert_attach_mismatch(
    owner,
    contract("checkout-child", 2, "signature-a", #(1, 2, 3, 9)),
    run_id,
    saga_grind.ChildUndoErrorCodecVersionMismatch,
  )

  let sentinel_contract =
    contract_with_output_codec(
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      sentinel_receipt_codec(),
    )
  let malformed_output =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Null,
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  // Attach itself does not decode terminal bytes; observation revalidates the
  // whole envelope before invoking the retained output decoder.
  let malformed_owner = owner_with("checkout-owner", run_id, malformed_output)
  let assert Ok(malformed_handle) =
    saga_grind.attach_child(malformed_owner, sentinel_contract, run_id)
  let wrong_output_version =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 99, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Null,
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let changed_metadata_owner =
    owner_with("checkout-owner", run_id, wrong_output_version)
  let assert Error(saga_grind.ObservedIncompatible(
    saga_grind.ChildOutputCodecVersionMismatch,
  )) = saga_grind.observe_child(changed_metadata_owner, malformed_handle)

  let corrupt =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Null,
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let corrupt_owner = owner_with("checkout-owner", run_id, corrupt)
  let assert Ok(corrupt_handle) =
    saga_grind.attach_child(corrupt_owner, current_contract, run_id)
  let assert Error(saga_grind.ChildStoredDataCorrupt(saga_grind.OutputCouldNotDecode(
    _,
  ))) = saga_grind.observe_child(corrupt_owner, corrupt_handle)

  let pruned =
    stored(
      "checkout-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      14,
      saga_grind.StoredChildResultUnavailable,
    )
  let pruned_owner = owner_with("checkout-owner", run_id, pruned)
  let assert Ok(pruned_handle) =
    saga_grind.attach_child(pruned_owner, current_contract, run_id)
  let assert Error(saga_grind.ChildResultUnavailable) =
    saga_grind.observe_child(pruned_owner, pruned_handle)

  let other_owner = must_owner("other-owner")
  let other_reader = owner_with_read(other_owner, fn(_, _) { Ok(completed) })
  let assert Error(saga_grind.ChildIncompatible(saga_grind.ChildOwnerMismatch)) =
    saga_grind.reattach_child(other_reader, current_contract, link)

  let wrong_run_record =
    stored(
      "checkout-owner",
      identity.run_id("different-run"),
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Text("receipt-71"),
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let wrong_run_owner = owner_with("checkout-owner", run_id, wrong_run_record)
  let assert Error(saga_grind.ChildIncompatible(
    saga_grind.ChildRunIdentityMismatch,
  )) = saga_grind.attach_child(wrong_run_owner, current_contract, run_id)

  let wrong_owner_record =
    stored(
      "unrelated-owner",
      run_id,
      "checkout-child",
      2,
      "signature-a",
      #(1, 2, 3, 4),
      12,
      saga_grind.StoredChildCompleted(
        value.Text("receipt-71"),
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let wrong_owner_record_reader =
    owner_with("checkout-owner", run_id, wrong_owner_record)
  let assert Error(saga_grind.ChildIncompatible(saga_grind.ChildOwnerMismatch)) =
    saga_grind.attach_child(wrong_owner_record_reader, current_contract, run_id)

  let missing_owner =
    owner_with_read(must_owner("checkout-owner"), fn(_, _) {
      Error(saga_grind.StoredRunMissing)
    })
  let assert Error(saga_grind.ChildRunMissing) =
    saga_grind.attach_child(missing_owner, current_contract, run_id)
  let unavailable_owner =
    owner_with_read(must_owner("checkout-owner"), fn(_, _) {
      Error(saga_grind.OwnerUnavailable)
    })
  let assert Error(saga_grind.ChildOwnerUnavailable) =
    saga_grind.attach_child(unavailable_owner, current_contract, run_id)

  let malformed_link = value.Object([#("owner_id", value.Text(""))])
  let assert Error(_) = blueprint.decode(link_codec, malformed_link)
  let assert value.Object(link_fields) = link_value
  let duplicate_owner =
    value.Object([#("owner_id", value.Text("ambiguous-owner")), ..link_fields])
  let assert Error(_) = blueprint.decode(link_codec, duplicate_owner)
  let unknown_field = value.Object([#("future", value.Null), ..link_fields])
  let assert Error(_) = blueprint.decode(link_codec, unknown_field)
  let nonpositive_version =
    value.Object([
      #("owner_id", value.Text("checkout-owner")),
      #("run_id", value.Text("child-71")),
      #("definition_id", value.Text("checkout-child")),
      #("definition_version", value.Int(2)),
      #("signature", value.Text("signature-a")),
      #("input_version", value.Int(0)),
      #("output_version", value.Int(2)),
      #("error_version", value.Int(3)),
      #("undo_error_version", value.Int(4)),
    ])
  let assert Error(_) = blueprint.decode(link_codec, nonpositive_version)
  Nil
}

fn assert_attach_mismatch(
  owner: saga_grind.DurableOwner,
  contract: saga.ChildContract(String, Receipt, ChildError, UndoError),
  run_id: identity.RunId,
  expected: saga_grind.CompatibilityError,
) -> Nil {
  case saga_grind.attach_child(owner, contract, run_id) {
    Error(actual) -> {
      let assert True = actual == saga_grind.ChildIncompatible(expected)
      Nil
    }
    Ok(_) -> panic as "incompatible child metadata unexpectedly attached"
  }
}

fn contract(
  definition_id: String,
  version: Int,
  signature: String,
  boundary_versions: #(Int, Int, Int, Int),
) -> saga.ChildContract(String, Receipt, ChildError, UndoError) {
  contract_with_output_codec(
    definition_id,
    version,
    signature,
    boundary_versions,
    receipt_codec(),
  )
}

fn contract_with_output_codec(
  definition_id: String,
  version: Int,
  signature: String,
  boundary_versions: #(Int, Int, Int, Int),
  output_codec: blueprint.Codec(Receipt),
) -> saga.ChildContract(String, Receipt, ChildError, UndoError) {
  let activity =
    saga.activity(
      must_step_id("child.forward"),
      must_version(1),
      saga.ActivityContract(
        saga.VersionedCodec(must_version(1), blueprint.text()),
        saga.VersionedCodec(must_version(1), output_codec),
        saga.VersionedCodec(must_version(1), child_error_codec()),
        saga.VersionedCodec(must_version(1), undo_error_codec()),
      ),
      fn(input) { Ok(Receipt(input)) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let definition =
    saga.define(
      must_definition_id(definition_id),
      must_version(version),
      signature,
      activity,
    )
  saga.child_contract(
    definition,
    saga.BoundaryVersions(
      must_version(boundary_versions.0),
      must_version(boundary_versions.1),
      must_version(boundary_versions.2),
      must_version(boundary_versions.3),
    ),
  )
}

fn owner_with(
  owner_name: String,
  run_id: identity.RunId,
  stored: saga_grind.StoredRun,
) -> saga_grind.DurableOwner {
  owner_with_read(must_owner(owner_name), fn(_, requested) {
    case requested == run_id {
      True -> Ok(stored)
      False -> Error(saga_grind.StoredRunMissing)
    }
  })
}

fn owner_with_read(
  owner_id: saga_grind.OwnerId,
  read: fn(saga_grind.OwnerId, identity.RunId) ->
    Result(saga_grind.StoredRun, saga_grind.OwnerReadError),
) -> saga_grind.DurableOwner {
  saga_grind.durable_owner(
    owner_id,
    saga_grind.owner_port(
      read,
      saga_grind.unsupported_submission,
      saga_grind.unsupported_cancellation,
      saga_grind.unsupported_compensation_port(),
    ),
  )
}

fn stored(
  owner_name: String,
  run_id: identity.RunId,
  definition_id: String,
  definition_version: Int,
  signature: String,
  versions: #(Int, Int, Int, Int),
  revision: Int,
  state: saga_grind.StoredChildState,
) -> saga_grind.StoredRun {
  saga_grind.StoredRun(
    owner_name,
    run_id,
    definition_id,
    definition_version,
    signature,
    versions.0,
    versions.1,
    versions.2,
    versions.3,
    revision,
    state,
  )
}

fn receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.imap(blueprint.text(), Receipt, fn(receipt) {
    let Receipt(text) = receipt
    text
  })
}

fn sentinel_receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.new(
    fn(receipt) {
      let Receipt(text) = receipt
      Ok(value.Text(text))
    },
    fn(_) {
      panic as "stored metadata must be checked before the result decoder"
    },
  )
}

fn child_error_codec() -> blueprint.Codec(ChildError) {
  blueprint.imap(blueprint.text(), ChildError, fn(error) {
    let ChildError(text) = error
    text
  })
}

fn undo_error_codec() -> blueprint.Codec(UndoError) {
  blueprint.imap(blueprint.text(), UndoError, fn(error) {
    let UndoError(text) = error
    text
  })
}

fn must_owner(value: String) -> saga_grind.OwnerId {
  let assert Ok(owner) = saga_grind.owner_id(value)
  owner
}

fn must_definition_id(value: String) -> saga.DefinitionId {
  let assert Ok(identity) = saga.definition_id(value)
  identity
}

fn must_step_id(value: String) -> saga.StepId {
  let assert Ok(identity) = saga.step_id(value)
  identity
}

fn must_version(value: Int) -> saga.Version {
  let assert Ok(version) = saga.version(value)
  version
}

fn must_scoped_step_id() -> saga.ScopedStepId {
  let assert Ok(definition_node) = saga.node_id("parent-checkout")
  saga.ScopedStepId(saga.NamedAddress(definition_node), "wait-for-child")
}
