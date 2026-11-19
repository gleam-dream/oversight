import gleeunit
import shop/events.{Note, Paid, Pending, Refunded}

pub fn main() -> Nil {
  gleeunit.main()
}

/// The values the course's pattern-matching playground offers, and what the
/// compiled `describe` returns for each. The playground is tested against
/// the same answers.
pub fn describe_answers_every_sample_test() {
  assert events.describe(Refunded(cents: 25_000, reason: "damaged"))
    == "Ask finance"
  assert events.describe(Refunded(cents: 2000, reason: "late")) == "late, 2000"
  assert events.describe(Paid(items: [])) == "Paid for nothing?"
  assert events.describe(Paid(items: ["book"])) == "One item: book"
  assert events.describe(Paid(items: ["book", "mug", "pen"])) == "book +2"
  assert events.describe(Note("order-42")) == "About order 42"
  assert events.describe(Note("hello")) == "Nothing to do"
  assert events.describe(Pending) == "Nothing to do"
}
