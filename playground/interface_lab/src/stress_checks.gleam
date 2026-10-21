// THROWAWAY: Execute interface probes and explicit test adapters, never unfinished runtime stubs.
import consumers/activity_contract
import consumers/activity_recovery
import consumers/agent_policy
import consumers/approval_context
import consumers/child_admission
import consumers/child_attachments
import consumers/child_compensation
import consumers/claim_ownership
import consumers/collection_codec
import consumers/conditional_graph
import consumers/config_codec
import consumers/derived_catalog
import consumers/enum_codec
import consumers/execution_ownership
import consumers/local_execution
import consumers/login_consumption
import consumers/login_transactions
import consumers/modern_relay
import consumers/object_codec
import consumers/offline_pipeline
import consumers/provider_structured
import consumers/queue_configuration
import consumers/relay_exchanges
import consumers/resource_authorization
import consumers/runtime_schemas
import consumers/scheduled_jobs
import consumers/schema_admission
import consumers/schema_documents
import consumers/schema_generation
import consumers/session_custody
import consumers/shared_graph
import consumers/shared_registry
import consumers/standalone_jobs
import consumers/stream_ownership
import consumers/stream_progress
import consumers/tagged_codec
import consumers/tool_turns
import consumers/unified_workflow
import consumers/unique_jobs
import consumers/verified_login
import consumers/worker_outcomes
import consumers/worker_registry

import consumers/session_refresh

pub fn main() -> Nil {
  activity_contract.probe()
  activity_recovery.probe()
  agent_policy.probe()
  approval_context.probe()
  child_admission.probe()
  child_attachments.probe()
  child_compensation.probe()
  claim_ownership.probe()
  enum_codec.probe()
  execution_ownership.probe()
  derived_catalog.probe()
  conditional_graph.probe()
  config_codec.probe()
  collection_codec.probe()
  local_execution.probe()
  login_consumption.probe()
  login_transactions.probe()
  offline_pipeline.probe()
  modern_relay.probe()
  object_codec.probe()
  provider_structured.probe()
  queue_configuration.probe()
  relay_exchanges.probe()
  resource_authorization.probe()
  runtime_schemas.probe()
  schema_admission.probe()
  schema_documents.probe()
  schema_generation.probe()
  scheduled_jobs.probe()
  session_custody.probe()
  shared_graph.probe()
  shared_registry.probe()
  standalone_jobs.probe()
  stream_progress.probe()
  stream_ownership.probe()
  tagged_codec.probe()
  tool_turns.probe()
  unified_workflow.probe()
  unique_jobs.probe()
  verified_login.probe()
  worker_outcomes.probe()
  worker_registry.probe()
  session_refresh.probe()
}
