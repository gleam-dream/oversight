// THROWAWAY: Does uncertain admission provide a job handle?
import lab/grind

pub fn invalid(recovery: grind.UniqueRecovery(String, String)) -> grind.JobId {
  grind.job_id_of(recovery)
}
