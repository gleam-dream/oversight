// THROWAWAY: Does a conflict prove compatibility with a native worker result?
import lab/grind

pub fn invalid(conflict: grind.Conflict) -> grind.JobId {
  grind.job_id_of(conflict)
}
