//// The report domain: what a user asks for, the durable job, and its result.
////
//// One `Report` value crosses two packages. Relay needs a Blueprint codec
//// (JSON Schema for tool discovery); Grind needs a `gleam_json` encoder and a
//// `gleam/dynamic/decode` decoder. Neither package accepts the other's codec,
//// so the type carries two codecs, kept side by side below.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option}
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

// --- Grind codecs (gleam_json + decode) --------------------------------------

pub fn job_codec() -> Result(worker.Codec(ReportJob), worker.CodecError) {
  worker.codec(
    "report-job-v1",
    fn(job: ReportJob) {
      json.object([
        #("owner", json.string(job.owner)),
        #("title", json.string(job.title)),
        #("period", json.string(job.period)),
      ])
    },
    {
      use owner <- decode.field("owner", decode.string)
      use title <- decode.field("title", decode.string)
      use period <- decode.field("period", decode.string)
      decode.success(ReportJob(owner:, title:, period:))
    },
  )
}

pub fn report_json_codec() -> Result(worker.Codec(Report), worker.CodecError) {
  worker.codec(
    "report-v1",
    fn(report: Report) {
      json.object([
        #("owner", json.string(report.owner)),
        #("title", json.string(report.title)),
        #("period", json.string(report.period)),
        #("summary", json.string(report.summary)),
      ])
    },
    {
      use owner <- decode.field("owner", decode.string)
      use title <- decode.field("title", decode.string)
      use period <- decode.field("period", decode.string)
      use summary <- decode.field("summary", decode.string)
      decode.success(Report(owner:, title:, period:, summary:))
    },
  )
}

// --- Blueprint codecs (Relay tool contracts) ---------------------------------

pub fn request_codec() -> Result(
  codec.Codec(ReportRequest),
  codec.PropertyError,
) {
  codec.record2(
    codec.required(
      "title",
      codec.string() |> codec.describe("Report title, e.g. Revenue"),
    ),
    codec.required(
      "period",
      codec.string() |> codec.describe("Reporting period, e.g. 2026-Q3"),
    ),
    ReportRequest,
    fn(r) { r.title },
    fn(r) { r.period },
  )
}

pub fn submitted_codec() -> Result(codec.Codec(Submitted), codec.PropertyError) {
  codec.record2(
    codec.required("job_id", codec.int()),
    codec.required("state", codec.string()),
    Submitted,
    fn(s) { s.job_id },
    fn(s) { s.state },
  )
}

pub fn status_request_codec() -> codec.Codec(StatusRequest) {
  codec.field("job_id", codec.int())
  |> codec.imap(StatusRequest, fn(s) { s.job_id })
}

/// Four fields exceed `record3`, so the record is built from nested pairs.
pub fn report_codec() -> Result(codec.Codec(Report), codec.PropertyError) {
  let string = codec.string()
  case
    codec.combine(
      codec.required("owner", string),
      codec.required("title", string),
    ),
    codec.combine(
      codec.required("period", string),
      codec.required("summary", string),
    )
  {
    Ok(left), Ok(right) ->
      case codec.combine(left, right) {
        Ok(all) ->
          Ok(
            codec.object(all)
            |> codec.imap(
              fn(t) {
                let #(#(owner, title), #(period, summary)) = t
                Report(owner:, title:, period:, summary:)
              },
              fn(r) { #(#(r.owner, r.title), #(r.period, r.summary)) },
            ),
          )
        Error(e) -> Error(e)
      }
    Error(e), _ | _, Error(e) -> Error(e)
  }
}

pub fn status_codec() -> Result(codec.Codec(ReportStatus), codec.PropertyError) {
  case report_codec() {
    Error(e) -> Error(e)
    Ok(report) ->
      codec.record3(
        codec.required("job_id", codec.int()),
        codec.required("state", codec.string()),
        codec.optional_option("report", report),
        ReportStatus,
        fn(s) { s.job_id },
        fn(s) { s.state },
        fn(s) { s.report },
      )
  }
}
