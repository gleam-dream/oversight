import gleam/list
import gleam/string
import lustre/element
import pages/gleam_lang/snippets
import site/code.{
  Comment, Constructor, Function, Keyword, Label, Name, Number, Operator,
  Punctuation, Space, Text,
}

fn kinds(line: String) -> List(#(code.Kind, String)) {
  code.tokenize(line)
  |> list.filter(fn(t) { t.kind != Space })
  |> list.map(fn(t) { #(t.kind, t.text) })
}

pub fn a_type_definition_test() {
  assert kinds("pub type Order {")
    == [
      #(Keyword, "pub"),
      #(Keyword, "type"),
      #(Constructor, "Order"),
      #(Punctuation, "{"),
    ]
}

pub fn labelled_fields_and_generics_test() {
  assert kinds("  Refunded(receipt: Receipt, refund: List(Int))")
    == [
      #(Constructor, "Refunded"),
      #(Punctuation, "("),
      #(Label, "receipt"),
      #(Punctuation, ":"),
      #(Constructor, "Receipt"),
      #(Punctuation, ","),
      #(Label, "refund"),
      #(Punctuation, ":"),
      #(Constructor, "List"),
      #(Punctuation, "("),
      #(Constructor, "Int"),
      #(Punctuation, "))"),
    ]
}

pub fn a_case_arm_with_a_guard_test() {
  assert kinds("    Refunded(cents:, ..) if cents > 10_000 -> \"Ask finance\"")
    == [
      #(Constructor, "Refunded"),
      #(Punctuation, "("),
      #(Label, "cents"),
      #(Punctuation, ":,"),
      #(Operator, ".."),
      #(Punctuation, ")"),
      #(Keyword, "if"),
      #(Name, "cents"),
      #(Operator, ">"),
      #(Number, "10_000"),
      #(Operator, "->"),
      #(Text, "\"Ask finance\""),
    ]
}

pub fn calls_through_a_module_and_pipes_test() {
  assert kinds("use order <- result.try(parse(request)) |> f")
    == [
      #(Keyword, "use"),
      #(Name, "order"),
      #(Operator, "<-"),
      #(Name, "result"),
      #(Punctuation, "."),
      #(Function, "try"),
      #(Punctuation, "("),
      #(Function, "parse"),
      #(Punctuation, "("),
      #(Name, "request"),
      #(Punctuation, "))"),
      #(Operator, "|>"),
      #(Name, "f"),
    ]
}

pub fn strings_keep_escapes_and_concatenation_test() {
  assert kinds("Note(\"order-\" <> id) // a \"quoted\" note")
    == [
      #(Constructor, "Note"),
      #(Punctuation, "("),
      #(Text, "\"order-\""),
      #(Operator, "<>"),
      #(Name, "id"),
      #(Punctuation, ")"),
      #(Comment, "// a \"quoted\" note"),
    ]
  assert kinds("\"say \\\"hi\\\"\"") == [#(Text, "\"say \\\"hi\\\"\"")]
}

pub fn tokens_give_back_the_line_exactly_test() {
  let sources = [
    snippets.order, snippets.loose_order, snippets.order_label,
    snippets.checkout, snippets.checkout_error, snippets.cart_message,
    snippets.cart_send, snippets.event, snippets.describe,
  ]
  list.each(sources, fn(source) {
    list.each(string.split(source, "\n"), fn(line) {
      assert string.concat(list.map(code.tokenize(line), fn(t) { t.text }))
        == line
    })
  })
}

pub fn the_view_marks_the_lines_it_is_asked_to_test() {
  let html =
    code.view_marked("a\nb\nc", "three lines", fn(i) {
      case i {
        1 -> code.Matched
        _ -> code.Plain
      }
    })
    |> element.to_string
  assert string.contains(html, "<span class=\"cl cl-match\">b</span>")
  assert string.contains(html, "aria-label=\"three lines\"")
}

pub fn line_of_finds_the_first_line_with_a_fragment_test() {
  assert code.line_of(snippets.describe, "Paid(items: [])") == Ok(4)
  assert code.line_of(snippets.describe, "nowhere") == Error(Nil)
}

pub fn the_compiler_output_keeps_its_words_test() {
  let html =
    code.compiler_output(snippets.disputed_error, "error") |> element.to_string
  assert string.contains(html, "error: Inexhaustive patterns")
  assert string.contains(html, "Disputed(receipt:, case_id:)")
}
