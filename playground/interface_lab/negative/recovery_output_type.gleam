// THROWAWAY: Recovery output retains the original activity output type.
import lab/saga

pub fn invalid() -> saga.RecoveryDecision(Int, String, Nil) {
  saga.UseOutput("wrong output", saga.Uncompensated)
}
