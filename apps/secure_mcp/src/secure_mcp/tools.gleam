//// MCP tools that act for the authenticated principal, backed by Grind jobs.

import gleam/option.{type Option, None, Some}
import gleam/result
import grind.{type Grind}
import grind/job
import grind/worker.{type Worker}
import relay/tool
import secure_mcp/auth.{type Principal}
import secure_mcp/reports.{
  type Report, type ReportJob, type ReportRequest, type ReportStatus,
  type StatusRequest, type Submitted, ReportJob, ReportStatus, Submitted,
}
import sinal/correlation.{type Correlation}

pub const queue = "reports"

pub type ReportWorker =
  Worker(ReportJob, Report, String)

/// Application errors of the tools. Only the rendered text reaches clients.
pub type ReportError {
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

/// The tool definitions; an MCP client calls them with the same values.
pub fn generate_definition() -> tool.Definition(ReportRequest, Submitted) {
  tool.define(
    "generate_report",
    reports.request_codec(),
    reports.submitted_codec(),
  )
  |> tool.with_description(
    "Queue a report for the signed-in user; returns a job id.",
  )
}

pub fn status_definition() -> tool.Definition(StatusRequest, ReportStatus) {
  tool.define(
    "report_status",
    reports.status_request_codec(),
    reports.status_codec(),
  )
  |> tool.with_description(
    "Read the state and result of one of your own report jobs.",
  )
  |> tool.with_read_only_hint(True)
}

/// The tools bound to Grind. The context is the principal Relay admitted;
/// the request's correlation comes from the call.
pub fn tools(
  jobs: Grind,
  report_worker: ReportWorker,
) -> List(tool.Tool(Principal)) {
  [
    tool.handle_call(generate_definition(), fn(call, request) {
      generate_report(
        jobs,
        report_worker,
        tool.context(call),
        tool.correlation(call),
        request,
      )
      |> reply
    }),
    tool.handle_call(status_definition(), fn(call, request) {
      report_status(jobs, report_worker, tool.context(call), request) |> reply
    }),
  ]
}

fn reply(
  result: Result(output, ReportError),
) -> Result(tool.Reply(output), tool.ToolError) {
  result |> result.map(tool.complete) |> result.map_error(render)
}

fn generate_report(
  jobs: Grind,
  report_worker: ReportWorker,
  principal: Principal,
  correlation: Option(Correlation),
  request: ReportRequest,
) -> Result(Submitted, ReportError) {
  // The request's correlation travels with the job: Grind's admitted, claimed
  // and acknowledged events carry it, so no bridge event is needed.
  let report =
    job.new(
      report_worker,
      ReportJob(
        owner: principal.subject,
        title: request.title,
        period: request.period,
      ),
    )
  let report = case correlation {
    Some(correlation) -> job.with_correlation(report, correlation)
    None -> report
  }
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
  Ok(Submitted(job_id:, state: "queued"))
}

fn submit_failed(
  error: grind.SubmitError(input, output, failure),
) -> ReportError {
  case error {
    grind.InvalidInput(reason) -> InvalidReport(reason)
    grind.PayloadTooLarge(..) -> InvalidReport("the report is too large")
    _ -> SubmitFailed
  }
}

fn report_status(
  jobs: Grind,
  report_worker: ReportWorker,
  principal: Principal,
  request: StatusRequest,
) -> Result(ReportStatus, ReportError) {
  let job_id = request.job_id
  // Another user's job and a missing job are indistinguishable to the caller,
  // and so is an id that belongs to another worker.
  use handle <- result.try(
    grind.bind(jobs, report_worker, job_id) |> result.map_error(read_failed),
  )
  use owned <- result.try(
    grind.arguments(jobs, handle) |> result.map_error(read_failed),
  )
  use <- guard(owned.owner == principal.subject, ReportNotFound)
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
  Ok(status)
}

fn read_failed(error: grind.ReadError) -> ReportError {
  case grind.read_error_kind(error) {
    grind.NotFound | grind.Mismatch -> ReportNotFound
    _ -> ReadFailed
  }
}

fn guard(
  condition: Bool,
  error: ReportError,
  next: fn() -> Result(a, ReportError),
) -> Result(a, ReportError) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

fn render(error: ReportError) -> tool.ToolError {
  tool.error_message(case error {
    ReportNotFound -> "No such report job for this user."
    InvalidReport(reason) -> "The report was refused: " <> reason
    SubmitFailed -> "The report could not be queued; try again."
    ReadFailed -> "The report state could not be read; try again."
  })
}
