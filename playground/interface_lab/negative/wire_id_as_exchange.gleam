// THROWAWAY: Can an untrusted wire request identifier own an exchange?
import lab/relay_exchange as exchange

pub fn begin_with_wire_id(
  server: exchange.Server(String),
  wire_id: exchange.RequestId,
  call: exchange.ParsedCall(String),
) -> #(exchange.Server(String), List(exchange.ServerEffect(String))) {
  exchange.step(server, exchange.Begin(wire_id, call))
}
