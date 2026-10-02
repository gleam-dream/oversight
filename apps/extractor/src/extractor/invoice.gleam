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

/// The Blueprint codec for an invoice. Six properties exceed `record3`, so
/// the properties are combined pairwise and mapped through nested tuples.
pub fn codec() -> codec.Codec(Invoice) {
  let assert Ok(currency) =
    codec.string_enum([#("USD", Usd), #("EUR", Eur), #("GBP", Gbp)])
  let assert Ok(quantity) = codec.integer_between(1, 1_000_000)
  let assert Ok(cents) = codec.integer_between(0, 1_000_000_000)
  let assert Ok(line_item) =
    codec.record3(
      codec.required("description", codec.string()),
      codec.required("quantity", quantity),
      codec.required("unit_price_cents", cents),
      LineItem,
      fn(item) { item.description },
      fn(item) { item.quantity },
      fn(item) { item.unit_price_cents },
    )
  let date =
    codec.try_imap(codec.string(), check_date, Ok)
    |> codec.describe("Issue date as YYYY-MM-DD")
  let assert Ok(head) =
    codec.combine(
      codec.required("vendor", codec.string()),
      codec.required("number", codec.string()),
    )
  let assert Ok(head) = codec.combine(head, codec.required("issued_on", date))
  let assert Ok(head) =
    codec.combine(head, codec.required("currency", currency))
  let assert Ok(head) =
    codec.combine(head, codec.required("line_items", codec.list(line_item)))
  let assert Ok(all) = codec.combine(head, codec.required("total_cents", cents))
  codec.object(all)
  |> codec.try_imap(
    fn(fields) {
      let #(#(#(#(#(vendor, number), issued_on), currency), line_items), total) =
        fields
      check_total(Invoice(
        vendor:,
        number:,
        issued_on:,
        currency:,
        line_items:,
        total_cents: total,
      ))
    },
    fn(invoice: Invoice) {
      Ok(#(
        #(
          #(
            #(#(invoice.vendor, invoice.number), invoice.issued_on),
            invoice.currency,
          ),
          invoice.line_items,
        ),
        invoice.total_cents,
      ))
    },
  )
}

fn check_date(text: String) -> Result(String, codec.DecodeError) {
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
        _, _, _, _ -> invalid_date(text)
      }
    _ -> invalid_date(text)
  }
}

fn invalid_date(text: String) -> Result(String, codec.DecodeError) {
  Error(codec.CannotDecode(codec.CustomDecodeReason("not a date: " <> text)))
}

fn check_total(invoice: Invoice) -> Result(Invoice, codec.DecodeError) {
  let sum =
    list.fold(invoice.line_items, 0, fn(acc, item) { acc + line_total(item) })
  case sum == invoice.total_cents {
    True -> Ok(invoice)
    False ->
      Error(codec.DecodeAtField(
        "total_cents",
        codec.CannotDecode(codec.CustomDecodeReason(
          "total "
          <> int.to_string(invoice.total_cents)
          <> " differs from line sum "
          <> int.to_string(sum),
        )),
      ))
  }
}
