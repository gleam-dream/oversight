// THROWAWAY: Exact JSON-number parsing and checked BEAM number projections.
import lab/json_number as number

@external(erlang, "json_number_ffi", "integer_to_string")
fn integer_to_string(value: Int) -> String

@external(erlang, "json_number_ffi", "join_strings")
fn join_strings(values: List(String), separator: String) -> String

@external(erlang, "json_number_ffi", "emit_line")
fn emit_line(value: String) -> Nil

type FloatFixture {
  PositiveZero
  NegativeZero
  Half
  Tenth
  MinimumSubnormal
  MaximumFinite
  NegativeTenth
}

@external(erlang, "json_number_ffi", "float_fixture")
fn float_fixture(fixture: FloatFixture) -> Float

@external(erlang, "json_number_ffi", "float_bits_hex")
fn float_bits_hex(value: Float) -> String

pub fn probe() -> Nil {
  let assert Error(number.TokenLimitMustBePositive) =
    number.number_limits(0, 1, 0)
  let assert Error(number.SignificandLimitMustBePositive) =
    number.number_limits(1, 0, 0)
  let assert Error(number.ExponentLimitMustBeNonnegative) =
    number.number_limits(1, 1, -1)
  let assert Error(number.IntegerDigitLimitMustBePositive) =
    number.integer_projection_limit(0)
  let limits = limits()
  let projection_limit = projection_limit()

  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "+1")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "01")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "1.")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, ".1")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "1e+")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "1.2.3")
  let assert Error(number.InvalidSyntax) =
    number.parse_number(limits, repeat("9", 33) <> "e+")
  let assert Error(number.TokenTooLong) =
    number.parse_number(limits, repeat("9", 65))
  let assert Error(number.TooManySignificandDigits) =
    number.parse_number(limits, repeat("9", 33))
  let assert Error(number.TooManySignificandDigits) =
    number.parse_number(limits, repeat("9", 33) <> "e1")
  let assert Error(number.ExponentOutOfRange) =
    number.parse_number(limits, "1e1201")
  let assert Error(number.ExponentOutOfRange) =
    number.parse_number(limits, "0e1266")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, "１")
  let assert Error(number.InvalidSyntax) = number.parse_number(limits, " 1")

  let assert Ok(zero) = number.parse_number(limits, "0")
  let assert Ok(negative_zero) = number.parse_number(limits, "-0")
  let assert Ok(one) = number.parse_number(limits, "1")
  let assert Ok(one_point_zero) = number.parse_number(limits, "1.0")
  let assert Ok(ten_e_minus_one) = number.parse_number(limits, "10e-1")
  let assert Ok(hundred_e_minus_two) = number.parse_number(limits, "100e-2")
  let assert Ok(decimal_reduced) = number.parse_number(limits, "1.2300e2")
  let assert Ok(exponent_adjusted) = number.parse_number(limits, "123.45e1201")
  let assert Ok(trailing_zero_adjusted) =
    number.parse_number(limits, "100e-1202")
  let assert Ok(twelve) = number.parse_number(limits, "12")
  let assert Ok(one_twenty) = number.parse_number(limits, "120")
  let assert Ok(negative_one_twenty) = number.parse_number(limits, "-120")
  let assert Ok(negative_half) = number.parse_number(limits, "-0.5")
  let assert Ok(negative_decimal) = number.parse_number(limits, "-123.45")
  let assert number.EqualTo = number.compare(zero, negative_zero)
  let assert number.EqualTo = number.compare(one, one_point_zero)
  let assert number.EqualTo = number.compare(one, ten_e_minus_one)
  let assert number.EqualTo = number.compare(one, hundred_e_minus_two)
  let assert number.LessThan = number.compare(negative_half, one)
  let assert number.GreaterThan =
    number.compare(negative_decimal, must_parse(limits, "-123.5"))
  let assert "0" = number.number_text(negative_zero)
  let assert "1.23e2" = number.number_text(decimal_reduced)
  let assert "1.2345e1203" = number.number_text(exponent_adjusted)
  let assert "1e-1200" = number.number_text(trailing_zero_adjusted)

  let assert Ok(large_integer) = number.parse_number(limits, "9007199254740993")
  let assert Ok(large_integer_native) =
    number.to_int_exact(large_integer, projection_limit)
  let assert 9_007_199_254_740_993 = large_integer_native
  let assert Error(number.IntegerDigitLimitExceeded) =
    number.to_int_exact(
      must_parse(limits, "123456789012345678901234567890"),
      projection_limit,
    )
  let assert Error(number.FractionalInteger) =
    number.to_int_exact(must_parse(limits, "1.5"), projection_limit)
  let assert Ok(12) = number.to_int_exact(twelve, projection_limit)
  let assert Ok(1) = number.to_int_exact(ten_e_minus_one, projection_limit)
  let assert Ok(120) = number.to_int_exact(one_twenty, projection_limit)
  let assert Ok(-120) =
    number.to_int_exact(negative_one_twenty, projection_limit)
  let assert Error(number.FractionalInteger) =
    number.to_int_exact(negative_half, projection_limit)
  let assert True = number.is_integer(must_parse(limits, "10e-1"))
  let assert False = number.is_integer(must_parse(limits, "0.1"))

  let assert Ok(exact_half) = number.to_float_exact(must_parse(limits, "0.5"))
  let assert "3fe0000000000000" = float_bits_hex(exact_half)
  let assert Error(number.FloatInexact) =
    number.to_float_exact(must_parse(limits, "0.1"))
  let assert Error(number.FloatInexact) =
    number.to_float_exact(must_parse(limits, "9007199254740993"))
  let assert Error(number.FloatOverflow) =
    number.to_float_exact(must_parse(limits, "1e400"))
  let assert Error(number.FloatUnderflow) =
    number.to_float_exact(must_parse(limits, "1e-400"))
  let assert Error(number.FloatInexact) =
    number.to_float_exact(negative_decimal)
  let assert Ok(constructed_tenth) =
    number.from_float_exact(float_fixture(Tenth))
  let assert "1.000000000000000055511151231257827021181583404541015625e-1" =
    number.number_text(constructed_tenth)
  let assert Ok(constructed_half) = number.from_float_exact(float_fixture(Half))
  let assert "5e-1" = number.number_text(constructed_half)
  let assert "0" = number.number_text(number.from_int(0))
  let assert "1.2e1" = number.number_text(number.from_int(12))
  let assert "1.2e2" = number.number_text(number.from_int(120))
  let assert "-1.2e2" = number.number_text(number.from_int(-120))
  let assert "9.007199254740993e15" =
    number.number_text(number.from_int(9_007_199_254_740_993))
  Nil
}

pub fn oracle_lines() -> List(String) {
  [
    limits_line(),
    ..append(
      parse_lines(parse_tokens()),
      append(
        comparison_lines(comparison_pairs()),
        append(
          float_lines(float_fixtures()),
          from_int_lines(from_int_fixtures()),
        ),
      ),
    )
  ]
}

pub fn main() -> Nil {
  emit_lines(oracle_lines())
}

fn limits() -> number.NumberLimits {
  let assert Ok(limits) = number.number_limits(64, 32, 1200)
  limits
}

fn projection_limit() -> number.IntegerProjectionLimit {
  let assert Ok(limit) = number.integer_projection_limit(24)
  limit
}

fn parse_tokens() -> List(String) {
  [
    "+1",
    "01",
    "1.",
    ".1",
    "1e",
    "1e+",
    "--1",
    "1.2.3",
    repeat("9", 33) <> "e+",
    repeat("9", 33) <> "e1",
    "-0",
    "0",
    "1",
    "1.0",
    "10e-1",
    "100e-2",
    "123.45",
    "1.2300e2",
    "123.45e1201",
    "100e-1202",
    "0.5",
    "0.1",
    "0.125",
    "9007199254740992",
    "9007199254740993",
    "123456789012345678901234567890",
    "1e400",
    "1e-400",
    "1e-324",
    "1.7976931348623157e308",
    "1.7976931348623159e308",
    "-0.5",
    "-123.45",
    "١",
    " 1",
    "1e1201",
    "0e1266",
    repeat("9", 33),
    repeat("9", 65),
  ]
}

fn comparison_pairs() -> List(#(String, String)) {
  [
    #("1", "1.0"),
    #("-0", "0"),
    #("9007199254740993", "9007199254740992"),
    #("-2", "-10"),
    #("-1.01", "-1.001"),
    #("-1", "1"),
    #("1", "0.99"),
    #("1.20", "12e-1"),
    #("1.01", "1.001"),
    #("1e3", "9.99e2"),
    #("0.001", "0.01"),
  ]
}

fn float_fixtures() -> List(#(FloatFixture, String)) {
  [
    #(PositiveZero, "0000000000000000"),
    #(NegativeZero, "8000000000000000"),
    #(Half, "3fe0000000000000"),
    #(Tenth, "3fb999999999999a"),
    #(MinimumSubnormal, "0000000000000001"),
    #(MaximumFinite, "7fefffffffffffff"),
    #(NegativeTenth, "bfb999999999999a"),
  ]
}

fn from_int_fixtures() -> List(#(Int, String)) {
  [
    #(0, "0"),
    #(12, "12"),
    #(120, "120"),
    #(-120, "-120"),
    #(9_007_199_254_740_993, "9007199254740993"),
  ]
}

fn from_int_lines(fixtures: List(#(Int, String))) -> List(String) {
  case fixtures {
    [] -> []
    [#(value, input), ..rest] -> [
      from_int_line(value, input),
      ..from_int_lines(rest)
    ]
  }
}

fn from_int_line(value: Int, input: String) -> String {
  let parsed = number.from_int(value)
  let integer_result = number.to_int_exact(parsed, projection_limit())
  let #(status, integer_value) = case integer_result {
    Ok(roundtrip) -> #("exact", text_value(integer_to_string(roundtrip)))
    Error(number.IntegerDigitLimitExceeded) -> #("digit_limit", null_value())
    Error(number.FractionalInteger) -> #("fractional", null_value())
  }
  object_row([
    text_field("kind", "from_int"),
    text_field("input", input),
    text_field("canonical", number.number_text(parsed)),
    text_field("int_status", status),
    raw_field("int_value", integer_value),
  ])
}

fn parse_lines(tokens: List(String)) -> List(String) {
  case tokens {
    [] -> []
    [token, ..rest] -> [parse_line(token), ..parse_lines(rest)]
  }
}

fn parse_line(token: String) -> String {
  case number.parse_number(limits(), token) {
    Error(error) -> rejected_parse_row(token, error)
    Ok(parsed) -> accepted_parse_row(token, parsed)
  }
}

fn rejected_parse_row(token: String, error: number.NumberError) -> String {
  let status = case error {
    number.InvalidSyntax -> "invalid_syntax"
    number.TokenTooLong -> "token_too_long"
    number.TooManySignificandDigits -> "significand_too_long"
    number.ExponentOutOfRange -> "exponent_out_of_range"
  }
  object_row([
    text_field("kind", "parse"),
    text_field("token", token),
    text_field("status", status),
    raw_field("canonical", "null"),
    raw_field("integer", "null"),
    text_field("int_status", "not_applicable"),
    raw_field("int_value", "null"),
    text_field("float_status", "not_applicable"),
    raw_field("float_bits_hex", "null"),
    raw_field("float_exact_decimal", "null"),
  ])
}

fn accepted_parse_row(token: String, parsed: number.JsonNumber) -> String {
  let integer_text = bool_text(number.is_integer(parsed))
  let #(integer_status, integer_value) = case
    number.to_int_exact(parsed, projection_limit())
  {
    Ok(value) -> #("exact", text_value(integer_to_string(value)))
    Error(number.FractionalInteger) -> #("fractional", null_value())
    Error(number.IntegerDigitLimitExceeded) -> #("digit_limit", null_value())
  }
  let #(float_status, float_bits, exact_float_decimal) =
    float_projection_fields(parsed)
  object_row([
    text_field("kind", "parse"),
    text_field("token", token),
    text_field("status", "accepted"),
    text_field("canonical", number.number_text(parsed)),
    raw_field("integer", integer_text),
    text_field("int_status", integer_status),
    raw_field("int_value", integer_value),
    text_field("float_status", float_status),
    raw_field("float_bits_hex", float_bits),
    raw_field("float_exact_decimal", exact_float_decimal),
  ])
}

fn float_projection_fields(
  parsed: number.JsonNumber,
) -> #(String, String, String) {
  case number.to_float_exact(parsed) {
    Ok(value) -> {
      let assert Ok(exact_decimal) = number.from_float_exact(value)
      #(
        "exact",
        text_value(float_bits_hex(value)),
        text_value(number.number_text(exact_decimal)),
      )
    }
    Error(number.FloatOverflow) -> #("overflow", "null", "null")
    Error(number.FloatUnderflow) -> #("underflow", "null", "null")
    Error(number.FloatInexact) -> #("inexact", "null", "null")
    Error(number.InvalidFloatCandidate) -> #(
      "invalid_candidate",
      "null",
      "null",
    )
  }
}

fn comparison_lines(pairs: List(#(String, String))) -> List(String) {
  case pairs {
    [] -> []
    [#(left_text, right_text), ..rest] -> [
      comparison_line(left_text, right_text),
      ..comparison_lines(rest)
    ]
  }
}

fn comparison_line(left_text: String, right_text: String) -> String {
  let order = case
    number.compare(
      must_parse(limits(), left_text),
      must_parse(limits(), right_text),
    )
  {
    number.LessThan -> "less"
    number.EqualTo -> "equal"
    number.GreaterThan -> "greater"
  }
  object_row([
    text_field("kind", "compare"),
    text_field("left", left_text),
    text_field("right", right_text),
    text_field("order", order),
  ])
}

fn float_lines(fixtures: List(#(FloatFixture, String))) -> List(String) {
  case fixtures {
    [] -> []
    [#(fixture, input_bits), ..rest] -> [
      float_line(fixture, input_bits),
      ..float_lines(rest)
    ]
  }
}

fn float_line(fixture: FloatFixture, input_bits: String) -> String {
  let value = float_fixture(fixture)
  let assert True = input_bits == float_bits_hex(value)
  let assert Ok(parsed) = number.from_float_exact(value)
  let assert Ok(roundtrip) = number.to_float_exact(parsed)
  object_row([
    text_field("kind", "from_float"),
    text_field("input_hex", input_bits),
    text_field("status", "accepted"),
    text_field("canonical", number.number_text(parsed)),
    text_field("roundtrip_bits_hex", float_bits_hex(roundtrip)),
  ])
}

fn limits_line() -> String {
  object_row([
    text_field("kind", "limits"),
    text_field("parse_max_token_bytes", "64"),
    text_field("parse_max_significand_digits", "32"),
    text_field("parse_max_abs_exponent", "1200"),
    text_field("int_projection_max_digits", "24"),
  ])
}

fn text_field(name: String, value: String) -> String {
  json_string(name) <> ":" <> json_string(value)
}

fn raw_field(name: String, value: String) -> String {
  json_string(name) <> ":" <> value
}

fn text_value(value: String) -> String {
  json_string(value)
}

fn null_value() -> String {
  "null"
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn json_string(value: String) -> String {
  "\"" <> value <> "\""
}

fn object_row(fields: List(String)) -> String {
  "{" <> join_strings(fields, ",") <> "}"
}

fn emit_lines(lines: List(String)) -> Nil {
  case lines {
    [] -> Nil
    [line, ..rest] -> {
      emit_line(line)
      emit_lines(rest)
    }
  }
}

fn must_parse(limits: number.NumberLimits, token: String) -> number.JsonNumber {
  let assert Ok(parsed) = number.parse_number(limits, token)
  parsed
}

fn repeat(character: String, count: Int) -> String {
  case count {
    _ if count <= 0 -> ""
    _ -> character <> repeat(character, count - 1)
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [item, ..rest] -> [item, ..append(rest, right)]
  }
}
