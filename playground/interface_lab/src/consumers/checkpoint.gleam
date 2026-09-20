// THROWAWAY: Can callers explicitly freeze, encode, decode, and restore a run?
import lab/saga
import lab/saga_checkpoint as checkpoint
import lab/value.{type Value}

pub type CaptureError {
  CannotQuiesce(checkpoint.FreezeError)
  CannotEncode(checkpoint.SnapshotEncodingError)
}

pub type ThawError {
  CannotDecode(checkpoint.SnapshotDecodingError)
  CannotRestore(checkpoint.RestoreError)
}

pub fn freeze_to_value(
  execution: checkpoint.Execution(o, e, u),
) -> Result(Value, CaptureError) {
  case checkpoint.quiesce(execution) {
    Error(error) -> Error(CannotQuiesce(error))
    Ok(ready) ->
      case checkpoint.encode_snapshot(checkpoint.freeze(ready)) {
        Error(error) -> Error(CannotEncode(error))
        Ok(encoded) -> Ok(encoded)
      }
  }
}

pub fn thaw(
  definition: saga.Definition(i, o, e, u),
  encoded: Value,
) -> Result(checkpoint.Restored(o, e, u), ThawError) {
  case checkpoint.decode_snapshot(encoded) {
    Error(error) -> Error(CannotDecode(error))
    Ok(snapshot) ->
      case checkpoint.restore(definition, snapshot) {
        Error(error) -> Error(CannotRestore(error))
        Ok(restored) -> Ok(restored)
      }
  }
}

pub type NextAction {
  Resume
  KeepWaiting
  InspectTerminalResult
  ReconcileEffect
}

pub fn next_action(restored: checkpoint.Restored(o, e, u)) -> NextAction {
  case restored {
    checkpoint.RestoredRunnable(_) -> Resume
    checkpoint.RestoredWaiting(_, _) -> KeepWaiting
    checkpoint.RestoredTerminal(_, _) -> InspectTerminalResult
    checkpoint.RestoredReconciliationRequired(_, _) -> ReconcileEffect
  }
}

// This local runner consumer imports neither Grind nor Fabric.
pub fn start_local(
  definition: saga.Definition(i, o, e, u),
  input: i,
) -> Result(checkpoint.Execution(o, e, u), checkpoint.StartError) {
  checkpoint.start(definition, input)
}
