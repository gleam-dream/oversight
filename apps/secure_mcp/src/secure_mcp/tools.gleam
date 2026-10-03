//// MCP tools that act for the authenticated principal, backed by Grind jobs.

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import grind.{type Grind}
import grind/job
import grind/worker.{type Worker}
import relay/tool
import secure_mcp/auth.{type Principal}
import secure_mcp/reports.{
  type Report, type ReportJob, ReportJob, ReportStatus, Submitted,
}
import sinal/correlation.{type Correlation}

pub const queue = "reports"

/// Per-request context the `/mcp` mount hands to Relay. Relay's own HTTP
/// listener builds context from `fn() -> context`, which cannot see the
/// request; the mount builds this value after authentication.
pub type McpContext {
  McpContext(correlation: Correlation, principal: Principal)
}

pub type ReportWorker =
  Worker(ReportJob, Report, String)

/// Application errors of the tools. Only the rendered text reaches clients.
pub type ToolError {
  ReportNotFound
  /// Grind's input codec refused the report; the reason names the field.
  InvalidReport(reason: String)
  SubmitFailed
  ReadFailed
}

pub fn report_worker() -> ReportWorker {
  worker.new(
    "reports.generate",
    input: reports.job_codec(),
    output: reports.report_json_codec(),
    perform: reports.build,
  )
  |> worker.with_error_codec(reports.report_error_codec())
  // A report failure is deterministic (no data), so it is not retried.
  |> worker.with_retry_policy(fn(_error, _attempt) { worker.DoNotRetry })
  |> worker.with_queue(queue)
}

pub fn registry(
  jobs: Grind,
  report_worker: ReportWorker,
) -> Result(tool.Registry(McpContext), String) {
  use generate_name <- result.try(
    tool.tool_name("generate_report") |> result.map_error(describe),
  )
  use status_name <- result.try(
    tool.tool_name("report_status") |> result.map_error(describe),
  )
  use generate <- result.try(
    tool.definition(
      generate_name,
      reports.request_codec(),
      reports.submitted_codec(),
    )
    |> result.map_error(describe),
  )
  use status <- result.try(
    tool.definition(
      status_name,
      reports.status_request_codec(),
      reports.status_codec(),
    )
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
        generate_report(jobs, report_worker, call.application, request)
      },
      render,
    ),
    tool.handle_advanced_with_error_renderer(
      status,
      fn(call, request) {
        report_status(jobs, report_worker, call.application, request)
      },
      render,
    ),
  ])
  |> result.map_error(describe)
}

fn generate_report(
  jobs: Grind,
  report_worker: ReportWorker,
  context: McpContext,
  request: reports.ReportRequest,
) -> Result(tool.HandlerResult(reports.Submitted), ToolError) {
  // The request's correlation travels with the job: Grind's admitted, claimed
  // and acknowledged events carry it, so no bridge event is needed.
  let report =
    job.new(
      report_worker,
      ReportJob(
        owner: context.principal.subject,
        title: request.title,
        period: request.period,
      ),
    )
    |> job.with_correlation(context.correlation)
  // A lost reply is settled from the submission's receipt.
  use admission <- result.try(
    case grind.submit(jobs, report) {
      Error(grind.CommitUnknown(pending)) ->
        grind.reconcile_submission(jobs, pending)
      other -> other
    }
    |> result.map_error(submit_failed),
  )
  let job_id = job.id(grind.handle(admission))
  Ok(tool.Complete(Submitted(job_id:, state: "queued"), []))
}

fn submit_failed(
  error: grind.SubmitError(input, output, failure),
) -> ToolError {
  case error {
    grind.InvalidInput(reason) -> InvalidReport(reason)
    grind.PayloadTooLarge(..) -> InvalidReport("the report is too large")
    _ -> SubmitFailed
  }
}

fn report_status(
  jobs: Grind,
  report_worker: ReportWorker,
  context: McpContext,
  request: reports.StatusRequest,
) -> Result(tool.HandlerResult(reports.ReportStatus), ToolError) {
  let job_id = request.job_id
  // Another user's job and a missing job are indistinguishable to the caller,
  // and so is an id that belongs to another worker.
  use handle <- result.try(
    grind.bind(jobs, report_worker, job_id) |> result.map_error(read_failed),
  )
  use owned <- result.try(
    grind.arguments(jobs, handle) |> result.map_error(read_failed),
  )
  use <- guard(owned.owner == context.principal.subject, ReportNotFound)
  use outcome <- result.try(
    grind.outcome(jobs, handle) |> result.map_error(read_failed),
  )
  let status = case outcome {
    grind.Pending(state) -> ReportStatus(job_id, job.state_name(state), None)
    grind.Succeeded(report) -> ReportStatus(job_id, "succeeded", Some(report))
    grind.Failed(grind.Business(reason), _, _) ->
      ReportStatus(job_id, "failed: " <> reason, None)
    grind.Failed(_, _, description) ->
      ReportStatus(job_id, "failed: " <> description, None)
    grind.Discarded(_) -> ReportStatus(job_id, "discarded", None)
    grind.Cancelled(_) -> ReportStatus(job_id, "cancelled", None)
    grind.Uncertain(_) -> ReportStatus(job_id, "needs reconciliation", None)
  }
  Ok(tool.Complete(status, []))
}

fn read_failed(error: grind.ReadError) -> ToolError {
  case grind.read_error_kind(error) {
    grind.NotFound | grind.Mismatch -> ReportNotFound
    _ -> ReadFailed
  }
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
    InvalidReport(reason) -> "The report was refused: " <> reason
    SubmitFailed -> "The report could not be queued; try again."
    ReadFailed -> "The report state could not be read; try again."
  }
}

fn describe(error: a) -> String {
  string.inspect(error)
}
