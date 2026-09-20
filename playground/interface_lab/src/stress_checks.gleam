// THROWAWAY: Execute only pure interface composition probes, never runtime stubs.
import consumers/activity_contract
import consumers/approval_context
import consumers/collection_codec
import consumers/conditional_graph
import consumers/config_codec
import consumers/derived_catalog
import consumers/execution_ownership
import consumers/foreign_observation
import consumers/login_transactions
import consumers/object_codec
import consumers/offline_pipeline
import consumers/scheduled_jobs
import consumers/shared_graph
import consumers/shared_registry
import consumers/standalone_jobs
import consumers/stream_progress
import consumers/tagged_codec
import consumers/tool_turns

pub fn main() -> Nil {
  activity_contract.probe()
  approval_context.probe()
  execution_ownership.probe()
  foreign_observation.probe()
  derived_catalog.probe()
  conditional_graph.probe()
  config_codec.probe()
  collection_codec.probe()
  login_transactions.probe()
  offline_pipeline.probe()
  object_codec.probe()
  scheduled_jobs.probe()
  shared_graph.probe()
  shared_registry.probe()
  standalone_jobs.probe()
  stream_progress.probe()
  tagged_codec.probe()
  tool_turns.probe()
}
