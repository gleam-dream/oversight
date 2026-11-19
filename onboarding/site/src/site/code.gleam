//// Gleam code, highlighted. A small tokenizer for the snippets the course
//// shows: it knows Gleam's keywords, names, strings, numbers, comments and
//// operators line by line, which is all a short snippet needs. Rendering is
//// plain spans with classes, so no highlighting library is loaded.

import gleam/list
import gleam/string
import lustre/attribute.{attribute, class}
import lustre/element.{type Element}
import lustre/element/html

// TOKENS ----------------------------------------------------------------------

pub type Kind {
  Keyword
  /// A type or a constructor: any name that starts with a capital letter.
  Constructor
  /// A name that is called or defined: followed by `(`.
  Function
  /// A field label: followed by `:`.
  Label
  Name
  Text
  Number
  Comment
  Operator
  Punctuation
  Space
}

pub type Token {
  Token(kind: Kind, text: String)
}

const keywords = [
  "as", "assert", "case", "const", "echo", "fn", "if", "import", "let", "opaque",
  "panic", "pub", "todo", "type", "use",
]

/// Longest first, so `->` wins over `-`.
const operators = [
  "<>", "->", "<-", "|>", "==", "!=", "<=", ">=", "..", "<", ">", "+", "-", "*",
  "/", "%", "=", "|",
]

/// The tokens of one line of Gleam.
pub fn tokenize(line: String) -> List(Token) {
  scan(string.to_graphemes(line), []) |> list.reverse |> merge
}

fn scan(chars: List(String), acc: List(Token)) -> List(Token) {
  case chars {
    [] -> acc
    ["/", "/", ..] -> [Token(Comment, string.concat(chars)), ..acc]
    ["\"", ..rest] -> {
      let #(body, rest) = take_string(rest, ["\""])
      scan(rest, [Token(Text, body), ..acc])
    }
    [c, ..rest] if c == " " || c == "\t" -> scan(rest, [Token(Space, c), ..acc])
    [c, ..] ->
      case is_digit(c), is_name_start(c) {
        True, _ -> {
          let #(digits, rest) = take_while(chars, is_number_char)
          scan(rest, [Token(Number, digits), ..acc])
        }
        _, True -> {
          let #(word, rest) = take_while(chars, is_name_char)
          scan(rest, [Token(classify(word, rest), word), ..acc])
        }
        _, _ ->
          case operator(chars) {
            Ok(#(op, rest)) -> scan(rest, [Token(Operator, op), ..acc])
            Error(Nil) -> {
              let assert [c, ..rest] = chars
              scan(rest, [Token(Punctuation, c), ..acc])
            }
          }
      }
  }
}

fn classify(word: String, rest: List(String)) -> Kind {
  let next = case rest {
    [c, ..] -> c
    [] -> ""
  }
  let after = case rest {
    [_, c, ..] -> c
    _ -> ""
  }
  case list.contains(keywords, word), is_upper(word) {
    True, _ -> Keyword
    _, True -> Constructor
    _, False ->
      case next, after {
        "(", _ -> Function
        ":", ":" -> Name
        ":", _ -> Label
        _, _ -> Name
      }
  }
}

/// A string literal from its opening quote, escapes included.
fn take_string(
  chars: List(String),
  acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [] -> #(string.concat(list.reverse(acc)), [])
    ["\\", c, ..rest] -> take_string(rest, [c, "\\", ..acc])
    ["\"", ..rest] -> #(string.concat(list.reverse(["\"", ..acc])), rest)
    [c, ..rest] -> take_string(rest, [c, ..acc])
  }
}

fn take_while(
  chars: List(String),
  keep: fn(String) -> Bool,
) -> #(String, List(String)) {
  let taken = list.take_while(chars, keep)
  #(string.concat(taken), list.drop(chars, list.length(taken)))
}

fn operator(chars: List(String)) -> Result(#(String, List(String)), Nil) {
  list.find_map(operators, fn(op) {
    let size = string.length(op)
    case string.concat(list.take(chars, size)) == op {
      True -> Ok(#(op, list.drop(chars, size)))
      False -> Error(Nil)
    }
  })
}

/// Join neighbouring tokens of the same kind, so spaces and punctuation do
/// not become a span each.
fn merge(tokens: List(Token)) -> List(Token) {
  list.fold(tokens, [], fn(acc, token) {
    case acc {
      [Token(kind:, text:), ..rest]
        if kind == token.kind && { kind == Space || kind == Punctuation }
      -> [Token(kind:, text: text <> token.text), ..rest]
      _ -> [token, ..acc]
    }
  })
  |> list.reverse
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c) && c != ""
}

fn is_number_char(c: String) -> Bool {
  is_digit(c) || c == "_" || c == "."
}

fn is_name_start(c: String) -> Bool {
  is_lower(c) || is_upper(c) || c == "_"
}

fn is_name_char(c: String) -> Bool {
  is_name_start(c) || is_digit(c)
}

fn is_lower(c: String) -> Bool {
  string.lowercase(c) == c && string.uppercase(c) != c
}

fn is_upper(c: String) -> Bool {
  case string.first(c) {
    Ok(first) ->
      string.uppercase(first) == first && string.lowercase(first) != first
    Error(Nil) -> False
  }
}

// VIEW ------------------------------------------------------------------------

/// How a line of a snippet is marked, for playgrounds that point at code.
pub type Mark {
  Plain
  /// The line a playground is about right now.
  Matched
  /// Tried and passed over.
  Passed
  /// Tried; the pattern fitted but its guard said no.
  GuardFailed
  /// Failed: an error starts here.
  Failing
  /// Not reached, or removed.
  Faded
}

/// A highlighted Gleam snippet.
pub fn view(source: String, label: String) -> Element(msg) {
  view_marked(source, label, fn(_) { Plain })
}

/// A highlighted Gleam snippet whose lines a playground marks, counting from 0.
pub fn view_marked(
  source: String,
  label: String,
  mark: fn(Int) -> Mark,
) -> Element(msg) {
  html.pre([class("code"), attribute("aria-label", label)], [
    html.code(
      [],
      list.index_map(string.split(source, "\n"), fn(line, index) {
        html.span(
          [class("cl " <> mark_class(mark(index)))],
          list.map(tokenize(line), token),
        )
      }),
    ),
  ])
}

fn token(token: Token) -> Element(msg) {
  case token.kind {
    Space | Punctuation | Name -> html.text(token.text)
    kind -> html.span([class(kind_class(kind))], [html.text(token.text)])
  }
}

fn kind_class(kind: Kind) -> String {
  case kind {
    Keyword -> "tk-kw"
    Constructor -> "tk-ty"
    Function -> "tk-fn"
    Label -> "tk-lb"
    Text -> "tk-st"
    Number -> "tk-nu"
    Comment -> "tk-cm"
    Operator -> "tk-op"
    Name | Punctuation | Space -> ""
  }
}

fn mark_class(mark: Mark) -> String {
  case mark {
    Plain -> ""
    Matched -> "cl-match"
    Passed -> "cl-passed"
    GuardFailed -> "cl-guard"
    Failing -> "cl-fail"
    Faded -> "cl-faded"
  }
}

/// The compiler's own words, as it printed them: the error line in red.
pub fn compiler_output(output: String, label: String) -> Element(msg) {
  html.pre([class("code compiler"), attribute("aria-label", label)], [
    html.code(
      [],
      list.map(string.split(output, "\n"), fn(line) {
        case string.starts_with(line, "error:") {
          True -> html.span([class("cl tk-err")], [html.text(line)])
          False -> html.span([class("cl")], [html.text(line)])
        }
      }),
    ),
  ])
}

/// The index of the first line of `source` that contains `fragment`.
pub fn line_of(source: String, fragment: String) -> Result(Int, Nil) {
  string.split(source, "\n")
  |> list.index_map(fn(line, index) { #(line, index) })
  |> list.find_map(fn(pair) {
    case string.contains(pair.0, fragment) {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}
