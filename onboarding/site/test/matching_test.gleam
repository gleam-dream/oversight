import gleam/int
import gleam/list
import gleam/string
import pages/gleam_lang
import pages/gleam_lang/matching.{
  BigRefundArm, Binding, GuardFailed, ManyItemsArm, Matched, NoMatch, NotTried,
  OrderNoteArm, RefundArm,
}
import pages/gleam_lang/snippets
import site/code
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

/// What the compiled `describe` returns for every sample: the same answers
/// the snippets package's own test pins (snippets/test/snippets_test.gleam).
pub fn the_playground_answers_like_the_compiled_function_test() {
  let answers = [
    #(matching.LargeRefund, "Ask finance"),
    #(matching.SmallRefund, "late, 2000"),
    #(matching.PaidForNothing, "Paid for nothing?"),
    #(matching.PaidForOne, "One item: book"),
    #(matching.PaidForThree, "book +2"),
    #(matching.OrderNote, "About order 42"),
    #(matching.OtherNote, "Nothing to do"),
    #(matching.StillPending, "Nothing to do"),
  ]
  assert list.map(answers, fn(a) { a.0 }) == matching.samples
  list.each(answers, fn(answer) {
    let assert matching.Ran(result:, ..) =
      matching.run(matching.Complete, matching.value(answer.0))
    assert result == answer.1
  })
}

pub fn every_arm_is_a_line_of_the_compiled_snippet_test() {
  list.each(matching.arms, fn(arm) {
    let assert Ok(_) = code.line_of(snippets.describe, matching.pattern(arm))
  })
  // In the order the case expression lists them.
  let lines =
    list.map(matching.arms, fn(arm) {
      let assert Ok(line) =
        code.line_of(snippets.describe, matching.pattern(arm))
      line
    })
  assert lines == list.sort(lines, int.compare)
}

pub fn arms_are_tried_from_the_top_and_stop_at_the_first_match_test() {
  let assert matching.Ran(attempts:, ..) =
    matching.run(matching.Complete, matching.value(matching.SmallRefund))
  assert list.take(attempts, 3)
    == [
      #(BigRefundArm, GuardFailed([Binding("cents", "2000")])),
      #(
        RefundArm,
        Matched(
          [Binding("cents", "2000"), Binding("reason", "\"late\"")],
          "late, 2000",
        ),
      ),
      #(matching.EmptyArm, NotTried),
    ]
  assert list.count(attempts, fn(a) {
      case a.1 {
        Matched(..) -> True
        _ -> False
      }
    })
    == 1
}

pub fn list_and_string_patterns_bind_their_parts_test() {
  let assert matching.Ran(attempts:, ..) =
    matching.run(matching.Complete, matching.value(matching.PaidForThree))
  assert list.key_find(attempts, ManyItemsArm)
    == Ok(Matched(
      [Binding("first", "\"book\""), Binding("rest", "[\"mug\", \"pen\"]")],
      "book +2",
    ))
  let assert matching.Ran(attempts:, ..) =
    matching.run(matching.Complete, matching.value(matching.OtherNote))
  assert list.key_find(attempts, OrderNoteArm) == Ok(NoMatch)
}

pub fn without_the_empty_arm_nothing_compiles_test() {
  list.each(matching.samples, fn(sample) {
    assert matching.run(matching.WithoutEmptyArm, matching.value(sample))
      == matching.DoesNotCompile
  })
  let shown = matching.source(matching.WithoutEmptyArm, snippets.describe)
  assert !string.contains(shown, "Paid(items: [])")
  assert list.length(string.split(shown, "\n"))
    == list.length(string.split(snippets.describe, "\n")) - 1
  // The compiler names exactly the value the deleted arm handled.
  assert string.contains(snippets.missing_empty_error, "Paid(items: [])")
}

pub fn literals_read_like_gleam_test() {
  assert matching.literal(matching.value(matching.LargeRefund))
    == "Refunded(cents: 25000, reason: \"damaged\")"
  assert matching.literal(matching.value(matching.PaidForThree))
    == "Paid(items: [\"book\", \"mug\", \"pen\"])"
  assert matching.literal(matching.value(matching.StillPending)) == "Pending"
}

// THE TOUR --------------------------------------------------------------------

fn next(model: gleam_lang.Model) -> gleam_lang.Model {
  let context = context.new(motion.On, progress.empty())
  gleam_lang.update(
    model,
    gleam_lang.Tour(gleam_lang.MatchTour, tour.Next),
    context,
  ).0
}

pub fn the_match_tour_walks_the_patterns_then_breaks_the_build_test() {
  let model = next(gleam_lang.init())
  assert model.sample == matching.LargeRefund
  let model = next(model)
  assert model.sample == matching.SmallRefund
  let model = next(next(next(model)))
  assert model.sample == matching.OtherNote
  assert model.program == matching.Complete
  let model = next(model)
  assert model.sample == matching.PaidForNothing
  assert model.program == matching.WithoutEmptyArm
  let model = next(next(model))
  assert tour.phase(tour.get(model.tours, gleam_lang.MatchTour)) == Free
  // Replaying puts the arm back.
  let context = context.new(motion.On, progress.empty())
  let model =
    gleam_lang.update(
      model,
      gleam_lang.Tour(gleam_lang.MatchTour, tour.Replay),
      context,
    ).0
  assert model.program == matching.Complete
  assert tour.phase(tour.get(model.tours, gleam_lang.MatchTour))
    == Guided(0, Paused)
}
