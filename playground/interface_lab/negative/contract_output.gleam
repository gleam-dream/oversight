import consumers/activity_contract
import lab/saga

pub fn invalid(id: saga.StepId, version: saga.Version) {
  saga.activity(
    id,
    version,
    activity_contract.contract(),
    fn(_: String) { Ok("wrong output") },
    saga.Uncompensated,
  )
}
