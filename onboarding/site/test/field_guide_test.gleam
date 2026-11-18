import gleam/list
import pages/field_guide.{RetraceTour, Tour}
import pages/field_guide/glossary
import pages/field_guide/retrace.{Line}
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

fn send(model: field_guide.Model, msg: field_guide.Msg) -> field_guide.Model {
  let context = context.new(motion.On, progress.empty())
  field_guide.update(model, msg, context).0
}

// RETRACE ---------------------------------------------------------------------

pub fn an_empty_recording_shows_an_empty_cart_test() {
  let frame = retrace.frame(0, retrace.Private)
  assert frame.lines == [Line("empty", "")]
  assert frame.total == "€0"
  assert frame.discount_label == "No coupon"
  assert frame.discount == ""
  assert frame.email == "(empty)"
  assert frame.status == "nothing recorded yet"
}

pub fn the_coupon_is_an_external_result_that_takes_ten_percent_test() {
  let frame = retrace.frame(4, retrace.Private)
  assert frame.lines == [Line("Book", "€12"), Line("Mug", "€8")]
  assert frame.discount == "−€2"
  assert frame.total == "€18"
  assert frame.status == "shopping"
  let assert Ok(#(_, origin)) = list.drop(retrace.recording, 3) |> list.first
  assert origin == retrace.ExternalResult
}

pub fn a_private_email_never_comes_back_test() {
  assert retrace.frame(6, retrace.Private).email == "•••• (excluded at capture)"
  assert retrace.frame(6, retrace.Safe).email == "ada@example.com"
  assert retrace.frame(6, retrace.Safe).status == "checked out"
}

pub fn amounts_print_without_trailing_zeros_test() {
  assert retrace.euros(1800) == "€18"
  assert retrace.euros(1080) == "€10.8"
  assert retrace.euros(1205) == "€12.05"
}

pub fn the_retrace_tour_scrubs_and_switches_test() {
  let m = field_guide.init()
  assert m.position == 6
  // Step 1 rewinds to the start of the recording.
  let m = send(m, Tour(RetraceTour, tour.Replay))
  assert m.position == 0
  let m = send(m, Tour(RetraceTour, tour.Next))
  assert m.position == 3
  let m = send(m, Tour(RetraceTour, tour.Next))
  assert m.position == 4
  let m = send(m, Tour(RetraceTour, tour.Next))
  assert m.strategy == retrace.ProtectedObservations
  let m = send(m, Tour(RetraceTour, tour.Next))
  assert m.position == 6
  assert m.email == retrace.Private
  let m = send(m, Tour(RetraceTour, tour.Next))
  assert m.email == retrace.Safe
  assert tour.phase(tour.get(m.tours, RetraceTour)) == Guided(5, Paused)
  let m = send(m, Tour(RetraceTour, tour.Back))
  assert m.email == retrace.Private
  assert m.strategy == retrace.ProtectedObservations
  let m = send(m, Tour(RetraceTour, tour.Skip))
  assert tour.phase(tour.get(m.tours, RetraceTour)) == Free
}

pub fn scrubbing_stays_inside_the_recording_test() {
  let m = send(field_guide.init(), field_guide.ReaderScrubbedTo(9))
  assert m.position == 6
  let m = send(m, field_guide.ReaderScrubbedTo(-1))
  assert m.position == 0
}

// GLOSSARY --------------------------------------------------------------------

fn names(terms: List(glossary.Term)) -> List(String) {
  list.map(terms, fn(term) { term.term })
}

pub fn the_glossary_filters_by_text_and_group_test() {
  assert list.length(glossary.terms) == 37
  assert names(glossary.filter("lease", glossary.AllTerms))
    == ["Lease", "Decision point", "Undo window", "Release"]
  assert list.length(glossary.filter("", glossary.Libraries)) == 22
  assert list.length(glossary.filter("", glossary.Runtime)) == 11
  assert names(glossary.filter("", glossary.Principles))
    == ["NotSent", "MaybeSent", "Idempotency key", "Reconcile"]
}

pub fn the_filter_ignores_case_and_matches_tags_test() {
  assert names(glossary.filter("CODEC", glossary.AllTerms)) == ["Codec"]
  assert names(glossary.filter("http gun", glossary.AllTerms))
    == ["Destination policy", "Cassette"]
}

pub fn the_reader_filters_the_glossary_test() {
  let m = send(field_guide.init(), field_guide.ReaderFilteredTerms("hold"))
  let m = send(m, field_guide.ReaderPickedGroup(glossary.Libraries))
  assert m.query == "hold"
  assert m.group == glossary.Libraries
}

pub fn the_cheat_sheet_covers_twelve_libraries_test() {
  assert list.length(glossary.cheat_sheet) == 12
}
