//// MCP tools that act for the authenticated principal, backed by Grind jobs.

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grind/job
import grind/postgres
import grind/worker.{type Worker}
import relay/tool
import secure_mcp/auth.{type Principal}
import secure_mcp/reports.{
  type Report, type ReportJob, ReportJob, ReportStatus, Submitted,
}
import secure_mcp/telemetry

pub const queue = "reports"

/// Per-request context the `/mcp` mount hands to Relay. Relay's own HTTP
/// listener builds context from `fn() -> context`, which cannot see the
/// request; the mount builds this value after authentication.
pub type McpContext {
  McpContext(request_id: Int, principal: Principal)
}

pub type ReportWorker =
  Worker(ReportJob, Report, String)

/// Application errors of the tools. Only the rendered text reaches clients.
pub type ToolError {
  ReportNotFound
  SubmitFailed
  ReadFailed
}

pub fn report_worker() -> Result(ReportWorker, String) {
  use input <- result.try(reports.job_codec() |> result.map_error(describe))
  use output <- result.try(
    reports.report_json_codec() |> result.map_error(describe),
  )
  use error <- result.try(
    reports.report_error_codec() |> result.map_error(describe),
  )
  // A report failure is deterministic (no data), so it is not retried.
  worker.define_with_error_codec(
    "reports.generate",
    "v1",
    input,
    output,
    error,
    reports.build,
  )
  |> result.map(worker.with_retry_policy(
    _,
    worker.retry_policy(fn(_failure, _context) { worker.DoNotRetry }),
  ))
  |> result.map_error(describe)
}

pub fn registry(
  database: postgres.Database,
  report_worker: ReportWorker,
) -> Result(tool.Registry(McpContext), String) {
  use generate_name <- result.try(
    tool.tool_name("generate_report") |> result.map_error(describe),
  )
  use status_name <- result.try(
    tool.tool_name("report_status") |> result.map_error(describe),
  )
  use request_codec <- result.try(
    reports.request_codec() |> result.map_error(describe),
  )
  use submitted_codec <- result.try(
    reports.submitted_codec() |> result.map_error(describe),
  )
  use status_codec <- result.try(
    reports.status_codec() |> result.map_error(describe),
  )
  use generate <- result.try(
    tool.definition(generate_name, request_codec, submitted_codec)
    |> result.map_error(describe),
  )
  use status <- result.try(
    tool.definition(status_name, reports.status_request_codec(), status_codec)
    |> result.map_error(describe),
  )
  let generate =
    generate
    |> tool.with_description(
      "Queue a report for the signed-in user; returns a job id.",
    )
  let status =
    status
    |> tool.with_description(
      "Read the state and result of one of your own report jobs.",
    )
    |> tool.with_annotations(
      tool.empty_annotations() |> tool.with_read_only_hint(Some(True)),
    )
  tool.registry([
    tool.handle_advanced_with_error_renderer(
      generate,
      fn(call, request) {
        generate_report(database, report_worker, call.application, request)
      },
      render,
    ),
    tool.handle_advanced_with_error_renderer(
      status,
      fn(call, request) {
        report_status(database, report_worker, call.application, request)
      },
      render,
    ),
  ])
  |> result.map_error(describe)
}

fn generate_report(
  database: postgres.Database,
  report_worker: ReportWorker,
  context: McpContext,
  request: reports.ReportRequest,
) -> Result(tool.HandlerResult(reports.Submitted), ToolError) {
  let job =
    ReportJob(
      owner: context.principal.subject,
      title: request.title,
      period: request.period,
    )
  use handle <- result.try(
    postgres.submit(database, queue, report_worker, job)
    |> result.replace_error(SubmitFailed),
  )
  let job_id = job.id_value(handle)
  telemetry.report_submitted(context.request_id, job_id)
  Ok(tool.Complete(Submitted(job_id:, state: "queued"), []))
}

fn report_status(
  database: postgres.Database,
  report_worker: ReportWorker,
  context: McpContext,
  request: reports.StatusRequest,
) -> Result(tool.HandlerResult(reports.ReportStatus), ToolError) {
  let job_id = request.job_id
  // Another user's job and a missing job are indistinguishable to the caller.
  use handle <- result.try(
    postgres.bind_handle(database, report_worker, job_id)
    |> result.replace_error(ReportNotFound),
  )
  use owned <- result.try(
    postgres.arguments(database, handle)
    |> result.replace_error(ReportNotFound),
  )
  use <- guard(owned.owner == context.principal.subject, ReportNotFound)
  use outcome <- result.try(
    postgres.outcome(database, handle) |> result.replace_error(ReadFailed),
  )
  let status = case outcome {
    job.Pending(state) -> ReportStatus(job_id, state_name(state), None)
    job.SucceededWith(report) -> ReportStatus(job_id, "succeeded", Some(report))
    job.BusinessFailedWith(reason) | job.BusinessFailedWithCause(reason, _) ->
      ReportStatus(job_id, "failed: " <> reason, None)
    job.DiscardedWithReason(_) -> ReportStatus(job_id, "discarded", None)
    job.CancelledWithReason(_) -> ReportStatus(job_id, "cancelled", None)
    job.FailedOperationally(reason)
    | job.FailedOperationallyWithCause(reason, _) ->
      ReportStatus(job_id, "failed: " <> reason, None)
    job.ReconciliationRequired(_) ->
      ReportStatus(job_id, "needs reconciliation", None)
  }
  Ok(tool.Complete(status, []))
}

fn guard(
  condition: Bool,
  error: ToolError,
  next: fn() -> Result(a, ToolError),
) -> Result(a, ToolError) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

fn render(error: ToolError) -> String {
  case error {
    ReportNotFound -> "No such report job for this user."
    SubmitFailed -> "The report could not be queued; try again."
    ReadFailed -> "The report state could not be read; try again."
  }
}

// GLUE (SMCP-9): `job.state_to_stored` is `@internal`, so the app names states.
fn state_name(state: job.State) -> String {
  case state {
    job.Queued -> "queued"
    job.Scheduled -> "scheduled"
    job.Retryable -> "retryable"
    job.Executing -> "executing"
    job.Succeeded -> "succeeded"
    job.BusinessFailed -> "business_failed"
    job.RuntimeFailed -> "runtime_failed"
    job.ContractMismatch -> "contract_mismatch"
    job.Uncertain -> "uncertain"
    job.Discarded -> "discarded"
    job.Cancelled -> "cancelled"
  }
}

fn describe(error: a) -> String {
  string.inspect(error)
}
