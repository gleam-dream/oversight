//// The scripted batch: invoices as documents, and how the "LLM" answers.

import extractor/invoice.{type Invoice, Eur, Gbp, Invoice, LineItem, Usd}
import extractor/scripted
import gleam/int
import gleam/list
import gleam/string
import json/blueprint/codec

pub const document_host = "docs.example.test"

pub fn acme() -> Invoice {
  Invoice(
    vendor: "Acme Tools GmbH",
    number: "INV-1001",
    issued_on: "2026-09-14",
    currency: Eur,
    line_items: [
      LineItem("Claw hammer", 2, 1250),
      LineItem("Nails, box of 500", 10, 199),
    ],
    total_cents: 4490,
  )
}

pub fn globex() -> Invoice {
  Invoice(
    vendor: "Globex Ltd",
    number: "GX-77",
    issued_on: "2026-08-30",
    currency: Gbp,
    line_items: [LineItem("Consulting hour", 3, 15_000)],
    total_cents: 45_000,
  )
}

pub fn initech() -> Invoice {
  Invoice(
    vendor: "Initech Inc",
    number: "2026-0042",
    issued_on: "2026-09-01",
    currency: Usd,
    line_items: [
      LineItem("TPS report covers", 100, 25),
      LineItem("Stapler, red", 1, 1899),
    ],
    total_cents: 4399,
  )
}

/// The document text a vendor would send.
pub fn render(invoice: Invoice) -> String {
  string.join(
    [
      "INVOICE " <> invoice.number,
      "From: " <> invoice.vendor,
      "Date: " <> invoice.issued_on,
      "",
      ..list.map(invoice.line_items, fn(item) {
        item.description
        <> "  x"
        <> int.to_string(item.quantity)
        <> "  @ "
        <> int.to_string(item.unit_price_cents)
        <> " cents"
      })
    ]
      |> list.append([
        "",
        "Total due: "
          <> int.to_string(invoice.total_cents)
          <> " cents "
          <> invoice.currency_code(invoice.currency),
      ]),
    "\n",
  )
}

/// What a well-behaved model returns for this invoice.
pub fn model_output(invoice: Invoice) -> String {
  let assert Ok(text) = codec.encode_json(invoice.codec(), invoice)
  text
}

pub fn document(id: String, invoice: Invoice, behavior: scripted.Behavior) {
  scripted.Document(
    id:,
    content_type: "text/plain; charset=utf-8",
    body: scripted.Fixed(render(invoice)),
    behavior:,
  )
}

/// The demo batch: three good invoices (one rate-limited once), one
/// answer with an unknown currency, one whose total contradicts its lines,
/// one PDF, and one oversized stream.
pub fn batch() -> List(scripted.Document) {
  [
    document("acme", acme(), scripted.Answer(model_output(acme()))),
    document(
      "globex",
      globex(),
      scripted.RateLimitedOnce(1, model_output(globex())),
    ),
    document("initech", initech(), scripted.Answer(model_output(initech()))),
    document(
      "bad-currency",
      acme(),
      scripted.Answer(string.replace(model_output(acme()), "\"EUR\"", "\"YEN\"")),
    ),
    document(
      "bad-total",
      acme(),
      scripted.Answer(string.replace(model_output(acme()), "4490", "9999")),
    ),
    scripted.Document(
      id: "scan-pdf",
      content_type: "application/pdf",
      body: scripted.Fixed("%PDF-1.7"),
      behavior: scripted.Answer(""),
    ),
    scripted.Document(
      id: "huge",
      content_type: "text/plain",
      body: scripted.Streamed(string.repeat("x", 16_384), 16),
      behavior: scripted.Answer(""),
    ),
  ]
}

/// Documents whose provider call ends in a content-filter stop: one after
/// some output, one at the prompt.
pub fn filtered() -> List(scripted.Document) {
  [
    document(
      "filtered-output",
      acme(),
      scripted.ContentFiltered("{\"vendor\":\"Acme"),
    ),
    document("blocked-prompt", acme(), scripted.PromptBlocked),
  ]
}
