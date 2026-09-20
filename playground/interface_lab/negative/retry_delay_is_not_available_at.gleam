// THROWAWAY: Relative retry duration is not an absolute job schedule.
import lab/grind
import lab/saga

pub fn invalid(
  at: grind.AvailableAt,
) -> saga.RecoveryDecision(Int, String, Nil) {
  saga.RetryAfter(at, saga.CompensateOnCancel)
}
