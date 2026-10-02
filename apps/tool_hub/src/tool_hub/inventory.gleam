//// The "inventory" MCP server: a small product catalog with typed Relay tools.
////
//// The codecs below are the single source of each tool's schema. Relay admits
//// them into definitions; `tool_hub/remote_tools` derives the fabric
//// definitions from the same Relay definitions.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import json/blueprint/codec.{type Codec}
import relay/server
import relay/tool
import relay/transport/http

pub type Product {
  Product(sku: String, name: String, price_cents: Int)
}

pub type SearchQuery {
  SearchQuery(text: String, limit: Int)
}

pub type SearchResult {
  SearchResult(products: List(Product))
}

pub type StockQuery {
  StockQuery(sku: String)
}

pub type Stock {
  Stock(sku: String, on_hand: Int, warehouse: String)
}

pub type ReserveRequest {
  ReserveRequest(sku: String, quantity: Int)
}

pub type Reservation {
  Reservation(reservation_id: String, sku: String, quantity: Int)
}

pub type InventoryError {
  UnknownSku(sku: String)
  NotEnoughStock(sku: String, on_hand: Int)
}

// --- codecs: one per wire shape -------------------------------------------

pub fn product_codec() -> Codec(Product) {
  use sku <- codec.field("sku", codec.string(), fn(p: Product) { p.sku })
  use name <- codec.field("name", codec.string(), fn(p: Product) { p.name })
  use price_cents <- codec.field("price_cents", codec.int(), fn(p: Product) {
    p.price_cents
  })
  codec.success(Product(sku:, name:, price_cents:))
}

pub fn search_query_codec() -> Codec(SearchQuery) {
  use text <- codec.field(
    "text",
    codec.string() |> codec.describe("Words to match in product names"),
    fn(q: SearchQuery) { q.text },
  )
  use limit <- codec.field(
    "limit",
    codec.integer_between(1, 10),
    fn(q: SearchQuery) { q.limit },
  )
  codec.success(SearchQuery(text:, limit:))
}

pub fn search_result_codec() -> Codec(SearchResult) {
  use products <- codec.field(
    "products",
    codec.list(product_codec()),
    fn(r: SearchResult) { r.products },
  )
  codec.success(SearchResult(products:))
}

pub fn stock_query_codec() -> Codec(StockQuery) {
  use sku <- codec.field("sku", codec.string(), fn(q: StockQuery) { q.sku })
  codec.success(StockQuery(sku:))
}

pub fn stock_codec() -> Codec(Stock) {
  use sku <- codec.field("sku", codec.string(), fn(s: Stock) { s.sku })
  use on_hand <- codec.field("on_hand", codec.int(), fn(s: Stock) { s.on_hand })
  use warehouse <- codec.field("warehouse", codec.string(), fn(s: Stock) {
    s.warehouse
  })
  codec.success(Stock(sku:, on_hand:, warehouse:))
}

pub fn reserve_request_codec() -> Codec(ReserveRequest) {
  use sku <- codec.field("sku", codec.string(), fn(r: ReserveRequest) { r.sku })
  use quantity <- codec.field(
    "quantity",
    codec.integer_between(1, 100),
    fn(r: ReserveRequest) { r.quantity },
  )
  codec.success(ReserveRequest(sku:, quantity:))
}

pub fn reservation_codec() -> Codec(Reservation) {
  use reservation_id <- codec.field(
    "reservation_id",
    codec.string(),
    fn(r: Reservation) { r.reservation_id },
  )
  use sku <- codec.field("sku", codec.string(), fn(r: Reservation) { r.sku })
  use quantity <- codec.field("quantity", codec.int(), fn(r: Reservation) {
    r.quantity
  })
  codec.success(Reservation(reservation_id:, sku:, quantity:))
}

// --- Relay definitions: name, description, annotations, codecs ------------

pub fn search_products() -> tool.Definition(SearchQuery, SearchResult) {
  let assert Ok(name) = tool.tool_name("search_products")
  let assert Ok(definition) =
    tool.definition(name, search_query_codec(), search_result_codec())
  definition
  |> tool.with_description("Find products whose name contains the text.")
  |> tool.with_annotations(read_only())
}

pub fn get_stock() -> tool.Definition(StockQuery, Stock) {
  let assert Ok(name) = tool.tool_name("get_stock")
  let assert Ok(definition) =
    tool.definition(name, stock_query_codec(), stock_codec())
  definition
  |> tool.with_description("Units on hand for one SKU.")
  |> tool.with_annotations(read_only())
}

pub fn reserve_stock() -> tool.Definition(ReserveRequest, Reservation) {
  let assert Ok(name) = tool.tool_name("reserve_stock")
  let assert Ok(definition) =
    tool.definition(name, reserve_request_codec(), reservation_codec())
  definition
  |> tool.with_description("Hold units of one SKU for an order.")
  |> tool.with_annotations(
    tool.empty_annotations()
    |> tool.with_read_only_hint(Some(False))
    |> tool.with_idempotent_hint(Some(False)),
  )
}

fn read_only() -> tool.ToolAnnotations {
  tool.empty_annotations() |> tool.with_read_only_hint(Some(True))
}

// --- the catalog -----------------------------------------------------------

/// Stock levels live in an actor so that reservations change them.
pub opaque type Catalog {
  Catalog(subject: Subject(CatalogMessage))
}

type CatalogMessage {
  Search(SearchQuery, Subject(SearchResult))
  Lookup(String, Subject(Result(Stock, InventoryError)))
  Reserve(ReserveRequest, Subject(Result(Reservation, InventoryError)))
}

type Entry {
  Entry(product: Product, on_hand: Int, warehouse: String)
}

pub fn demo_catalog() -> Catalog {
  let entries =
    [
      Entry(Product("KB-101", "Ergonomic keyboard", 8900), 12, "Lisbon"),
      Entry(Product("KB-205", "Compact keyboard", 5900), 0, "Lisbon"),
      Entry(Product("MS-300", "Wireless mouse", 2900), 40, "Porto"),
    ]
    |> list.map(fn(entry) { #(entry.product.sku, entry) })
    |> dict.from_list
  let assert Ok(started) =
    actor.new(#(entries, 0))
    |> actor.on_message(handle_catalog)
    |> actor.start
  Catalog(started.data)
}

fn handle_catalog(
  state: #(Dict(String, Entry), Int),
  message: CatalogMessage,
) -> actor.Next(#(Dict(String, Entry), Int), CatalogMessage) {
  let #(entries, issued) = state
  case message {
    Search(SearchQuery(text:, limit:), reply) -> {
      let needle = string.lowercase(text)
      let products =
        dict.values(entries)
        |> list.map(fn(entry) { entry.product })
        |> list.filter(fn(product) {
          string.contains(string.lowercase(product.name), needle)
        })
        |> list.sort(fn(a, b) { string.compare(a.sku, b.sku) })
        |> list.take(limit)
      process.send(reply, SearchResult(products))
      actor.continue(state)
    }
    Lookup(sku, reply) -> {
      process.send(
        reply,
        dict.get(entries, sku)
          |> result.map(fn(entry) { Stock(sku, entry.on_hand, entry.warehouse) })
          |> result.replace_error(UnknownSku(sku)),
      )
      actor.continue(state)
    }
    Reserve(ReserveRequest(sku:, quantity:), reply) ->
      case dict.get(entries, sku) {
        Error(Nil) -> {
          process.send(reply, Error(UnknownSku(sku)))
          actor.continue(state)
        }
        Ok(entry) if entry.on_hand < quantity -> {
          process.send(reply, Error(NotEnoughStock(sku, entry.on_hand)))
          actor.continue(state)
        }
        Ok(entry) -> {
          let id = "R-" <> int.to_string(issued + 1)
          process.send(reply, Ok(Reservation(id, sku, quantity)))
          let entry = Entry(..entry, on_hand: entry.on_hand - quantity)
          actor.continue(#(dict.insert(entries, sku, entry), issued + 1))
        }
      }
  }
}

pub fn render_error(error: InventoryError) -> String {
  case error {
    UnknownSku(sku) -> "unknown SKU " <> sku
    NotEnoughStock(sku, on_hand) ->
      "only " <> int.to_string(on_hand) <> " units of " <> sku <> " on hand"
  }
}

// --- the server ------------------------------------------------------------

/// The bound handlers. Application errors are rendered before Relay erases
/// their type, so the MCP client sees `isError: true` with this text.
pub fn tools(catalog: Catalog) -> List(tool.ContextTool(Nil)) {
  let Catalog(subject) = catalog
  [
    tool.handle(search_products(), fn(query) {
      Ok(process.call(subject, 1000, Search(query, _)))
    }),
    tool.handle_with_error_renderer(
      get_stock(),
      fn(query: StockQuery) {
        process.call(subject, 1000, Lookup(query.sku, _))
      },
      render_error,
    ),
    tool.handle_with_error_renderer(
      reserve_stock(),
      fn(request) { process.call(subject, 1000, Reserve(request, _)) },
      render_error,
    ),
  ]
}

/// Starts the inventory MCP server on an ephemeral loopback port.
pub fn serve(catalog: Catalog) -> Result(http.HttpServer(Nil), String) {
  use registry <- result.try(
    tool.registry(tools(catalog))
    |> result.replace_error("duplicate inventory tool"),
  )
  server.server(registry)
  |> http.listener(fn() { Nil })
  |> http.start
}

pub fn url(running: http.HttpServer(context)) -> String {
  "http://127.0.0.1:" <> int.to_string(http.http_server_port(running)) <> "/"
}
