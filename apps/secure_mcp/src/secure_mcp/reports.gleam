//// The report domain: what a user asks for, the durable job, and its result.
////
//// Every wire type has one Blueprint codec. Relay uses it for the tool
//// contract (JSON Schema for discovery); Grind workers use the same codec
//// through `codec.to_json` and `codec.decoder`, so the two cannot disagree.

import gleam/erlang/process
import gleam/option.{type Option}
import gleam/result
import gleam/string
import grind/worker
import json/blueprint/codec

/// Tool input of `generate_report`. The owner is never taken from the client.
pub type ReportRequest {
  ReportRequest(title: String, period: String)
}

/// The durable job input. `owner` is the authenticated subject.
pub type ReportJob {
  ReportJob(owner: String, title: String, period: String)
}

pub type Report {
  Report(owner: String, title: String, period: String, summary: String)
}

/// Tool output of `generate_report`.
pub type Submitted {
  Submitted(job_id: Int, state: String)
}

/// Tool input of `report_status`.
pub type StatusRequest {
  StatusRequest(job_id: Int)
}

/// Tool output of `report_status`.
pub type ReportStatus {
  ReportStatus(job_id: Int, state: String, report: Option(Report))
}

/// Builds a report. A period of `"never"` is a business failure, so the
/// failure path reaches `report_status` too.
pub fn build(job: ReportJob) -> Result(Report, String) {
  process.sleep(20)
  case job.period {
    "never" -> Error("no data for period")
    period ->
      Ok(Report(
        owner: job.owner,
        title: job.title,
        period:,
        summary: string.uppercase(job.title)
          <> " for "
          <> period
          <> ": 42 rows, prepared for "
          <> job.owner,
      ))
  }
}

// --- Blueprint codecs (Relay tool contracts and Grind workers) --------------

pub fn request_codec() -> codec.Codec(ReportRequest) {
  use title <- codec.field(
    "title",
    codec.string() |> codec.describe("Report title, e.g. Revenue"),
    get: fn(r) { r.title },
  )
  use period <- codec.field(
    "period",
    codec.string() |> codec.describe("Reporting period, e.g. 2026-Q3"),
    get: fn(r) { r.period },
  )
  codec.success(ReportRequest(title:, period:))
}

pub fn submitted_codec() -> codec.Codec(Submitted) {
  use job_id <- codec.field("job_id", codec.int(), get: fn(s) { s.job_id })
  use state <- codec.field("state", codec.string(), get: fn(s) { s.state })
  codec.success(Submitted(job_id:, state:))
}

pub fn status_request_codec() -> codec.Codec(StatusRequest) {
  use job_id <- codec.field("job_id", codec.int(), get: fn(s) { s.job_id })
  codec.success(StatusRequest(job_id:))
}

/// The job's own contract is stricter than the tool's: a report needs a title.
/// Grind enforces it at `submit` (`InvalidInput`), before anything is stored.
pub fn job_input_codec() -> codec.Codec(ReportJob) {
  use owner <- codec.field("owner", codec.string(), get: fn(j) { j.owner })
  use title <- codec.field("title", non_empty(codec.string()), get: fn(j) {
    j.title
  })
  use period <- codec.field("period", codec.string(), get: fn(j) { j.period })
  codec.success(ReportJob(owner:, title:, period:))
}

fn non_empty(inner: codec.Codec(String)) -> codec.Codec(String) {
  let check = fn(text) {
    case text {
      "" -> Error("must not be empty")
      _ -> Ok(text)
    }
  }
  codec.try_map(
    inner,
    decode: check,
    encode: check,
    placeholder: codec.placeholder(inner),
  )
}

pub fn report_codec() -> codec.Codec(Report) {
  use owner <- codec.field("owner", codec.string(), get: fn(r) { r.owner })
  use title <- codec.field("title", codec.string(), get: fn(r) { r.title })
  use period <- codec.field("period", codec.string(), get: fn(r) { r.period })
  use summary <- codec.field("summary", codec.string(), get: fn(r) { r.summary })
  codec.success(Report(owner:, title:, period:, summary:))
}

pub fn status_codec() -> codec.Codec(ReportStatus) {
  use job_id <- codec.field("job_id", codec.int(), get: fn(s) { s.job_id })
  use state <- codec.field("state", codec.string(), get: fn(s) { s.state })
  use report <- codec.optional_field("report", report_codec(), get: fn(s) {
    s.report
  })
  codec.success(ReportStatus(job_id:, state:, report:))
}

// --- Grind codecs, derived from the Blueprint codecs -------------------------

/// The one bridge: a Blueprint codec as a Grind codec. A value the codec
/// cannot encode is rejected with the codec's own message, so Grind fails the
/// submit (`InvalidInput`) or ends the job instead of storing something
/// unreadable.
fn grind(codec: codec.Codec(a)) -> worker.Codec(a) {
  worker.codec(
    fn(value) {
      codec.to_json(codec, value)
      |> result.map_error(codec.describe_encode_error)
    },
    codec.decoder(codec),
  )
}

pub fn job_codec() -> worker.Codec(ReportJob) {
  grind(job_input_codec())
}

pub fn report_json_codec() -> worker.Codec(Report) {
  grind(report_codec())
}

/// The worker's business failure reason, stored so `report_status` can show it.
pub fn report_error_codec() -> worker.Codec(String) {
  grind(codec.string())
}
