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
pub fn codec() -> codec.Codec(Invoice) {
  let currency =
    codec.string_enum([#("USD", Usd), #("EUR", Eur), #("GBP", Gbp)])
  let quantity = codec.integer_between(1, 1_000_000)
  let cents = codec.integer_between(0, 1_000_000_000)
  let line_item = {
    use description <- codec.field(
      "description",
      codec.string(),
      fn(item: LineItem) { item.description },
    )
    use quantity <- codec.field("quantity", quantity, fn(item: LineItem) {
      item.quantity
    })
    use unit_price_cents <- codec.field(
      "unit_price_cents",
      cents,
      fn(item: LineItem) { item.unit_price_cents },
    )
    codec.success(LineItem(description:, quantity:, unit_price_cents:))
  }
  let date =
    codec.try_map(
      codec.string(),
      decode: check_date,
      encode: Ok,
      placeholder: "1970-01-01",
    )
    |> codec.describe("Issue date as YYYY-MM-DD")
  {
    use vendor <- codec.field("vendor", codec.string(), fn(i: Invoice) {
      i.vendor
    })
    use number <- codec.field("number", codec.string(), fn(i: Invoice) {
      i.number
    })
    use issued_on <- codec.field("issued_on", date, fn(i: Invoice) {
      i.issued_on
    })
    use currency <- codec.field("currency", currency, fn(i: Invoice) {
      i.currency
    })
    use line_items <- codec.field(
      "line_items",
      codec.list(line_item),
      fn(i: Invoice) { i.line_items },
    )
    use total_cents <- codec.field(
      "total_cents",
      total_matching(line_items, cents),
      fn(i: Invoice) { i.total_cents },
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

fn total_matching(
  items: List(LineItem),
  cents: codec.Codec(Int),
) -> codec.Codec(Int) {
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
  codec.try_map(cents, decode: check, encode: Ok, placeholder: 0)
}
