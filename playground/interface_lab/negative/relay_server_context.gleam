import lab/relay_authorization as authorization
import lab/relay_exchange as exchange
import lab/relay_server_2026 as server
import lab/value

pub fn invalid(
  configured: server.Server(String, Int),
  exchange_id: exchange.ExchangeId,
  grant: authorization.GrantedRequest(Int),
  message: value.Value,
) {
  server.step(
    configured,
    server.RequestReceived(exchange_id, 42, grant, message),
  )
}
