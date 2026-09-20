// THROWAWAY: Package event facts keep their own typed boundaries.
import lab/fabric_observations
import lab/grind
import lab/grind_observations
import lab/sinal

pub fn invalid(backend: sinal.Backend) {
  let cancellation =
    grind_observations.cancellation_fact(
      grind.job_id("job-47"),
      grind.JobQueued,
    )
  fabric_observations.emit_accepted(backend, cancellation)
}
