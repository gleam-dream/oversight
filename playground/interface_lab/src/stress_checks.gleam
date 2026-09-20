// THROWAWAY: Execute only pure interface composition probes, never runtime stubs.
import consumers/approval_context
import consumers/config_codec
import consumers/derived_catalog
import consumers/foreign_observation
import consumers/offline_pipeline
import consumers/shared_graph
import consumers/shared_registry
import consumers/standalone_jobs
import consumers/tool_turns

pub fn main() -> Nil {
  approval_context.probe()
  foreign_observation.probe()
  derived_catalog.probe()
  config_codec.probe()
  offline_pipeline.probe()
  shared_graph.probe()
  shared_registry.probe()
  standalone_jobs.probe()
  tool_turns.probe()
}
