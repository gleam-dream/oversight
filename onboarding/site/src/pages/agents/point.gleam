//// One refund through a Decisions decision point.
////
//// A billing model recommends a refund. A versioned policy either lets it
//// proceed (possibly after an undo window) or asks finance; the refund is
//// released at most once to a gated tool. Every step appends to the
//// occurrence's record. Changing the case or the policy starts a new
//// occurrence.

import gleam/int
import gleam/list
import gleam/string

pub type Version {
  V1
  V2
  V3
  V4
}

pub const versions = [V1, V2, V3, V4]

/// How the gated tool answers the next release attempt.
pub type GatedTool {
  Allows
  Refuses
  IsUnsure
}

pub const tools = [Allows, Refuses, IsUnsure]

pub type Outcome {
  Released
  Rejected
  Expired
  Withdrawn
  Refused
}

pub type Phase {
  Recommended
  Accepted
  Awaiting(approvals: Int)
  Held
  Settled(Outcome)
}

pub type Occurrence {
  /// `key` is the trigger's key, the same for every step of this occurrence;
  /// `path` lists the phases visited, oldest first; `entries` is the record,
  /// newest first.
  Occurrence(key: Int, phase: Phase, path: List(Phase), entries: List(String))
}

pub type Point {
  Point(
    amount: Int,
    confidence: Int,
    version: Version,
    tool: GatedTool,
    occurrence: Occurrence,
  )
}

/// What the reader (or the people around the point) can do next.
pub type Verb {
  ReadPolicy
  Supersede
  Release
  Approve
  Reject
  PassDeadline
  EndHold
  WithdrawInHold
  StartAgain
}

pub fn new() -> Point {
  Point(
    amount: 40,
    confidence: 95,
    version: V1,
    tool: Allows,
    occurrence: recommend(40, 95, first_key),
  )
}

/// The key of the first simulated message.
pub const first_key = 4471

/// A fresh occurrence: the model's recommendation, admitted under its key.
pub fn recommend(amount: Int, confidence: Int, key: Int) -> Occurrence {
  Occurrence(key:, phase: Recommended, path: [Recommended], entries: [
    "recommend: refund €"
    <> int.to_string(amount)
    <> " · confidence "
    <> int.to_string(confidence)
    <> "% · key "
    <> key_name(key),
  ])
}

fn key_name(key: Int) -> String {
  "msg-" <> int.to_string(key)
}

/// A new occurrence comes from a new message, so it gets the next key; only
/// a duplicate delivery of the same message lands on an existing occurrence.
fn fresh(point: Point, amount: Int, confidence: Int) -> Occurrence {
  recommend(amount, confidence, point.occurrence.key + 1)
}

// SETTINGS --------------------------------------------------------------------

pub fn set_amount(point: Point, amount: Int) -> Point {
  Point(..point, amount:, occurrence: fresh(point, amount, point.confidence))
}

pub fn set_confidence(point: Point, confidence: Int) -> Point {
  Point(
    ..point,
    confidence:,
    occurrence: fresh(point, point.amount, confidence),
  )
}

pub fn publish(point: Point, version: Version) -> Point {
  Point(
    ..point,
    version:,
    occurrence: fresh(point, point.amount, point.confidence),
  )
}

/// Load one exact case, as the 400-recommendation view sends it.
pub fn load(
  point: Point,
  amount: Int,
  confidence: Int,
  version: Version,
) -> Point {
  Point(
    ..point,
    amount:,
    confidence:,
    version:,
    occurrence: fresh(point, amount, confidence),
  )
}

pub fn set_tool(point: Point, tool: GatedTool) -> Point {
  Point(..point, tool:)
}

pub fn start_again(point: Point) -> Point {
  Point(..point, occurrence: fresh(point, point.amount, point.confidence))
}

// POLICY ----------------------------------------------------------------------

pub fn number(version: Version) -> Int {
  case version {
    V1 -> 1
    V2 -> 2
    V3 -> 3
    V4 -> 4
  }
}

/// Small, confident refunds proceed alone from v2.
pub fn proceeds(version: Version, amount: Int, confidence: Int) -> Bool {
  number(version) >= 2 && amount <= 100 && confidence >= 90
}

/// From v3, what proceeds alone waits out a 10-minute undo window.
pub fn holds(version: Version, amount: Int, confidence: Int) -> Bool {
  proceeds(version, amount, confidence) && number(version) >= 3
}

/// Approvals finance must give; from v4, two from €500.
pub fn needed(version: Version, amount: Int, confidence: Int) -> Int {
  case proceeds(version, amount, confidence) {
    True -> 0
    False ->
      case number(version) >= 4 && amount >= 500 {
        True -> 2
        False -> 1
      }
  }
}

pub fn version_name(version: Version) -> String {
  case version {
    V1 -> "v1 · Always ask"
    V2 -> "v2 · Small and sure"
    V3 -> "v3 · With an undo window"
    V4 -> "v4 · Two for big ones"
  }
}

pub fn version_rule(version: Version) -> String {
  case version {
    V1 -> "Every refund asks someone in finance."
    V2 ->
      "≤ €100 at ≥ 90% confidence proceeds alone; 1 in 10 of those sampled for review. Otherwise ask finance."
    V3 ->
      "Like v2, but what proceeds alone is held for 10 minutes; finance may withdraw it."
    V4 -> "Like v3, and from €500 it takes two approvals from finance."
  }
}

/// Twenty recent cases, as `#(amount, confidence)`, to show each version's reach.
pub const recent = [
  #(20, 97),
  #(35, 92),
  #(80, 99),
  #(60, 85),
  #(15, 95),
  #(120, 98),
  #(45, 91),
  #(300, 96),
  #(25, 70),
  #(90, 93),
  #(55, 99),
  #(700, 99),
  #(10, 94),
  #(40, 88),
  #(75, 96),
  #(150, 91),
  #(30, 99),
  #(95, 90),
  #(65, 97),
  #(520, 95),
]

/// How many of the recent cases proceed alone under a version.
pub fn reach(version: Version) -> Int {
  list.count(recent, fn(case_) { proceeds(version, case_.0, case_.1) })
}

pub fn tool_label(tool: GatedTool) -> String {
  case tool {
    Allows -> "Gated tool allows"
    Refuses -> "Gated tool refuses"
    IsUnsure -> "Gated tool is unsure"
  }
}

// THE OCCURRENCE --------------------------------------------------------------

pub fn is_settled(point: Point) -> Bool {
  case point.occurrence.phase {
    Settled(_) -> True
    _ -> False
  }
}

/// The verbs on offer now, in the order the buttons show them.
pub fn verbs(point: Point) -> List(Verb) {
  case point.occurrence.phase {
    Recommended -> [ReadPolicy, Supersede]
    Accepted -> [Release]
    Awaiting(_) -> [Approve, Reject, PassDeadline]
    Held -> [EndHold, WithdrawInHold]
    Settled(_) -> [StartAgain]
  }
}

/// The person approving next: Bia first, then Caio.
fn approver(approvals: Int) -> String {
  case approvals {
    0 -> "Bia"
    _ -> "Caio"
  }
}

pub fn verb_label(point: Point, verb: Verb) -> String {
  case verb {
    ReadPolicy -> "Read policy v" <> int.to_string(number(point.version))
    Supersede -> "A newer message supersedes it"
    Release -> "Release"
    Approve ->
      case point.occurrence.phase {
        Awaiting(approvals) -> approver(approvals) <> " approves"
        _ -> "Bia approves"
      }
    Reject -> "Reject"
    PassDeadline -> "Deadline passes"
    EndHold -> "Hold ends"
    WithdrawInHold -> "Finance withdraws in time"
    StartAgain -> "Start a new occurrence"
  }
}

/// Verbs that end the occurrence without a release are drawn as warnings.
pub fn is_warning(verb: Verb) -> Bool {
  case verb {
    Supersede | Reject | PassDeadline | WithdrawInHold -> True
    _ -> False
  }
}

/// The available verb whose label starts with `prefix`, as a tour finds it.
pub fn find_verb(point: Point, prefix: String) -> Result(Verb, Nil) {
  list.find(verbs(point), fn(verb) {
    string.starts_with(verb_label(point, verb), prefix)
  })
}

/// Perform a verb. A verb not on offer in the current phase changes nothing.
pub fn perform(point: Point, verb: Verb) -> Point {
  let Point(amount:, confidence:, version:, ..) = point
  let need = needed(version, amount, confidence)
  let v = "policy v" <> int.to_string(number(version))
  case point.occurrence.phase, verb {
    Recommended, ReadPolicy ->
      case proceeds(version, amount, confidence) {
        True -> {
          let hold = holds(version, amount, confidence)
          let line =
            v
            <> ": proceed"
            <> case number(version) >= 2 {
              True -> " (≤ €100, ≥ 90%)"
              False -> ""
            }
            <> case hold {
              True -> " with a 10-minute hold"
              False -> ""
            }
          add(point, [line], case hold {
            True -> Held
            False -> Accepted
          })
        }
        False ->
          add(
            point,
            [
              v
              <> ": ask finance ("
              <> int.to_string(need)
              <> " approval"
              <> case need > 1 {
                True -> "s"
                False -> ""
              }
              <> " needed)",
            ],
            Awaiting(0),
          )
      }
    Recommended, Supersede ->
      add(point, ["superseded by a newer event → expired"], Settled(Expired))
    Accepted, Release -> release(point, PolicyProceeded)
    Awaiting(approvals), Approve ->
      case approvals + 1 >= need {
        True -> release(point, VerdictCompleted(approvals))
        False ->
          add(point, [approval(approvals, need)], Awaiting(approvals + 1))
      }
    Awaiting(_), Reject -> add(point, ["reject by Bia"], Settled(Rejected))
    Awaiting(_), PassDeadline ->
      add(point, ["deadline reached → expired"], Settled(Expired))
    Held, EndHold -> release(point, HoldEnded)
    Held, WithdrawInHold ->
      add(point, ["withdrawn by Dani during the hold"], Settled(Withdrawn))
    Settled(_), StartAgain -> start_again(point)
    _, _ -> point
  }
}

/// The record line for the next approval, the `approvals + 1`th of `need`.
fn approval(approvals: Int, need: Int) -> String {
  "approve by "
  <> approver(approvals)
  <> " ("
  <> int.to_string(approvals + 1)
  <> "/"
  <> int.to_string(need)
  <> ")"
}

/// What a release attempt follows.
type Attempt {
  /// The policy let the refund proceed alone, with nobody waiting on it.
  PolicyProceeded
  /// The undo window closed.
  HoldEnded
  /// This approval, after `approvals` earlier ones, completes the verdict.
  VerdictCompleted(approvals: Int)
}

/// Where the occurrence stays when the attempt does not settle it.
fn before(attempt: Attempt) -> Phase {
  case attempt {
    PolicyProceeded -> Accepted
    HoldEnded -> Held
    VerdictCompleted(approvals) -> Awaiting(approvals)
  }
}

/// Try to release through the gated tool.
fn release(point: Point, attempt: Attempt) -> Point {
  let need = needed(point.version, point.amount, point.confidence)
  let verdict = case attempt {
    VerdictCompleted(approvals) -> [approval(approvals, need)]
    PolicyProceeded | HoldEnded -> []
  }
  case point.tool, attempt {
    Allows, _ ->
      add(
        point,
        list.append(verdict, [
          "accepted → release check passed",
          "released: refund sent to the gated tool, once, in this transaction",
        ]),
        Settled(Released),
      )
    // Nothing is recorded, so an approval this attempt carried is not
    // counted, and the earlier ones stand.
    IsUnsure, _ ->
      add(
        point,
        list.append(
          list.map(verdict, fn(line) { line <> ": attempted, not counted" }),
          [
            "release attempt: tool Unsure (lost connection) → verb fails with ToolUnsure; nothing recorded as refused, try again",
          ],
        ),
        before(attempt),
      )
    Refuses, PolicyProceeded ->
      add(
        point,
        [
          "release check: Refuse (balance too low), with nobody waiting",
          "refused",
        ],
        Settled(Refused),
      )
    Refuses, HoldEnded ->
      add(
        point,
        ["hold ended → release check: Refuse (balance too low)", "refused"],
        Settled(Refused),
      )
    // The refused verdict changes no status: the earlier approvals stand.
    Refuses, VerdictCompleted(_) ->
      add(
        point,
        list.append(verdict, [
          "verdict completed, but the tool refused → ToolRefused: transaction rolled back",
          "record_refusal (second transaction): refused verdict kept on the record; occurrence still waits",
        ]),
        before(attempt),
      )
  }
}

/// Append lines to the record and move to `phase`, extending the path unless
/// the occurrence stays in the same stage.
fn add(point: Point, lines: List(String), phase: Phase) -> Point {
  let Occurrence(key:, path:, entries:, ..) = point.occurrence
  let path = case list.last(path) {
    Ok(last) ->
      case stage(last) == stage(phase) {
        True -> path
        False -> list.append(path, [phase])
      }
    Error(Nil) -> [phase]
  }
  let entries =
    list.fold(lines, entries, fn(entries, line) { [line, ..entries] })
  Point(..point, occurrence: Occurrence(key:, phase:, path:, entries:))
}

/// The stage name of a phase, as the path shows it.
pub fn stage(phase: Phase) -> String {
  case phase {
    Recommended -> "recommended"
    Accepted -> "accepted"
    Awaiting(_) -> "awaiting"
    Held -> "held"
    Settled(Released) -> "released"
    Settled(Rejected) -> "rejected"
    Settled(Expired) -> "expired"
    Settled(Withdrawn) -> "withdrawn"
    Settled(Refused) -> "refused"
  }
}

pub fn stage_colour(phase: Phase) -> String {
  case phase {
    Recommended -> "#EEE7FD"
    Awaiting(_) -> "#FFF1C2"
    Accepted -> "#E0E9FD"
    Held -> "#FFF1C2"
    Settled(Released) -> "#E2F4E7"
    Settled(Rejected) -> "#FDECEA"
    Settled(Expired) -> "#EDEFF3"
    Settled(Withdrawn) -> "#EDEFF3"
    Settled(Refused) -> "#FDECEA"
  }
}

pub fn title(point: Point) -> String {
  let need = needed(point.version, point.amount, point.confidence)
  case point.occurrence.phase {
    Recommended -> "Recommended"
    Accepted -> "Accepted by policy"
    Awaiting(approvals) ->
      "Awaiting finance ("
      <> int.to_string(approvals)
      <> " of "
      <> int.to_string(need)
      <> ")"
    Held -> "Held: 10-minute undo window"
    Settled(Released) -> "Released, exactly once"
    Settled(Rejected) -> "Rejected"
    Settled(Expired) -> "Expired"
    Settled(Withdrawn) -> "Withdrawn"
    Settled(Refused) -> "Refused"
  }
}

pub fn why(point: Point) -> String {
  let need = needed(point.version, point.amount, point.confidence)
  let settled = fn(text) {
    text
    <> " Every step is in the record: that’s what tallies agreement per model version later."
  }
  case point.occurrence.phase {
    Recommended ->
      "The model recommended a €"
      <> int.to_string(point.amount)
      <> " refund at "
      <> int.to_string(point.confidence)
      <> "% confidence. Admitted once under its trigger’s key: a duplicate delivery would land on this same occurrence."
    Accepted ->
      "No person needed. Next comes the release check and the gated tool, inside your transaction."
    Awaiting(_) ->
      "A card shows the approver exactly what the model saw. "
      <> case need > 1 {
        True -> "Two different people must approve."
        False -> "One approval completes it."
      }
    Held ->
      "The policy let it through alone, but it waits before release. Finance can still withdraw it."
    Settled(Released) ->
      settled(
        "The gated tool accepted the released refund. Nothing else in the system can refund this fee.",
      )
    Settled(Rejected) ->
      settled(
        "A person said no. The tool never ran, and the record says who decided, on what information.",
      )
    Settled(Expired) ->
      settled("Superseded or out of time. Nothing was released.")
    Settled(Withdrawn) ->
      settled("Taken back during the undo window. Nothing was released.")
    Settled(Refused) ->
      settled("The release check refused. On the record, nothing released.")
  }
}

pub fn background(point: Point) -> String {
  case point.occurrence.phase {
    Settled(Released) -> "#E2F4E7"
    Settled(_) -> "#F6F7F9"
    _ -> "#FFF7FC"
  }
}
