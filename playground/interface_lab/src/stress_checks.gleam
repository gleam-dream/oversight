// THROWAWAY: Execute only pure interface composition probes, never runtime stubs.
import consumers/activity_contract
import consumers/approval_context
import consumers/child_attachments
import consumers/claim_ownership
import consumers/collection_codec
import consumers/conditional_graph
import consumers/config_codec
import consumers/derived_catalog
import consumers/execution_ownership
import consumers/foreign_observation
import consumers/login_transactions
import consumers/object_codec
import consumers/offline_pipeline
import consumers/relay_exchanges
import consumers/runtime_schemas
import consumers/scheduled_jobs
import consumers/schema_admission
import consumers/schema_documents
import consumers/schema_generation
import consumers/shared_graph
import consumers/shared_registry
import consumers/span_events
import consumers/standalone_jobs
import consumers/stream_ownership
import consumers/stream_progress
import consumers/tagged_codec
import consumers/tool_turns
import consumers/unified_workflow
import consumers/worker_outcomes

pub fn main() -> Nil {
  activity_contract.probe()
  approval_context.probe()
  child_attachments.probe()
  claim_ownership.probe()
  execution_ownership.probe()
  foreign_observation.probe()
  derived_catalog.probe()
  conditional_graph.probe()
  config_codec.probe()
  collection_codec.probe()
  login_transactions.probe()
  offline_pipeline.probe()
  object_codec.probe()
  relay_exchanges.probe()
  runtime_schemas.probe()
  schema_admission.probe()
  schema_documents.probe()
  schema_generation.probe()
  scheduled_jobs.probe()
  shared_graph.probe()
  shared_registry.probe()
  standalone_jobs.probe()
  span_events.probe()
  stream_progress.probe()
  stream_ownership.probe()
  tagged_codec.probe()
  tool_turns.probe()
  unified_workflow.probe()
  worker_outcomes.probe()
}
