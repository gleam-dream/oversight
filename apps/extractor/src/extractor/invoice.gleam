//// The extracted record: an invoice with a nested list of line items and a
//// currency enum. One Blueprint codec supplies the LLM output schema, the
//// strict decoder for provider output, and the JSON stored with each job.

import gleam/int
import gleam/list
import gleam/string
import json/blueprint/codec

pub type Currency {
  Usd
  Eur
  Gbp
}

pub type LineItem {
  LineItem(description: String, quantity: Int, unit_price_cents: Int)
}

pub type Invoice {
  Invoice(
    vendor: String,
    number: String,
    issued_on: String,
    currency: Currency,
    line_items: List(LineItem),
    total_cents: Int,
  )
}

pub fn currency_code(currency: Currency) -> String {
  case currency {
    Usd -> "USD"
    Eur -> "EUR"
    Gbp -> "GBP"
  }
}

pub fn line_total(item: LineItem) -> Int {
  item.quantity * item.unit_price_cents
}

/// The Blueprint codec for an invoice. The record builder lists the six
/// properties in schema order. The `total_cents` codec is built after
/// `line_items` decodes, so its check sees the lines and a mismatch is
/// reported at `total_cents`.
///
/// It stays a combinator codec: the date check is a custom `try_map` and the
/// total depends on the decoded lines, which the generator does not express.
/// Each child codec is built inside its field, never bound with `let` above
/// the record, so a later field's continuation captures no codec and the
/// codec copies at its own size. See the codec practice guide:
/// https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md
pub fn codec() -> codec.Codec(Invoice) {
  use vendor <- codec.field("vendor", codec.string(), get: fn(i) { i.vendor })
  use number <- codec.field("number", codec.string(), get: fn(i) { i.number })
  use issued_on <- codec.field("issued_on", date_codec(), get: fn(i) {
    i.issued_on
  })
  use currency <- codec.field("currency", currency_codec(), get: fn(i) {
    i.currency
  })
  use line_items <- codec.field(
    "line_items",
    codec.list(line_item_codec()),
    get: fn(i) { i.line_items },
  )
  use total_cents <- codec.field(
    "total_cents",
    total_matching(line_items),
    get: fn(i) { i.total_cents },
  )
  codec.success(Invoice(
    vendor:,
    number:,
    issued_on:,
    currency:,
    line_items:,
    total_cents:,
  ))
}

fn currency_codec() -> codec.Codec(Currency) {
  codec.string_enum([#("USD", Usd), #("EUR", Eur), #("GBP", Gbp)])
}

fn cents_codec() -> codec.Codec(Int) {
  codec.integer_between(0, 1_000_000_000)
}

fn line_item_codec() -> codec.Codec(LineItem) {
  use description <- codec.field("description", codec.string(), get: fn(item) {
    item.description
  })
  use quantity <- codec.field(
    "quantity",
    codec.integer_between(1, 1_000_000),
    get: fn(item) { item.quantity },
  )
  use unit_price_cents <- codec.field(
    "unit_price_cents",
    cents_codec(),
    get: fn(item) { item.unit_price_cents },
  )
  codec.success(LineItem(description:, quantity:, unit_price_cents:))
}

fn date_codec() -> codec.Codec(String) {
  codec.try_map(
    codec.string(),
    decode: check_date,
    encode: Ok,
    placeholder: "1970-01-01",
  )
  |> codec.describe("Issue date as YYYY-MM-DD")
}

fn check_date(text: String) -> Result(String, String) {
  case string.split(text, "-") {
    [year, month, day] ->
      case
        string.length(year) == 4
        && string.length(month) == 2
        && string.length(day) == 2,
        int.parse(year),
        int.parse(month),
        int.parse(day)
      {
        True, Ok(_), Ok(m), Ok(d) if m >= 1 && m <= 12 && d >= 1 && d <= 31 ->
          Ok(text)
        _, _, _, _ -> Error("not a date: " <> text)
      }
    _ -> Error("not a date: " <> text)
  }
}

fn total_matching(items: List(LineItem)) -> codec.Codec(Int) {
  let check = fn(total) {
    let sum = list.fold(items, 0, fn(acc, item) { acc + line_total(item) })
    case sum == total {
      True -> Ok(total)
      False ->
        Error(
          "total "
          <> int.to_string(total)
          <> " differs from line sum "
          <> int.to_string(sum),
        )
    }
  }
  codec.try_map(cents_codec(), decode: check, encode: Ok, placeholder: 0)
}
