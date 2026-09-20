// THROWAWAY: Does a receipt retain its native undo-error codec type?
import lab/saga_grind

pub fn invalid(
  receipt: saga_grind.DurableCompensationReceipt(Int),
) -> saga_grind.DurableCompensationReceipt(String) {
  receipt
}
