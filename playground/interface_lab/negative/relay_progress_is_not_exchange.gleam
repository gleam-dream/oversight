import lab/relay_exchange as exchange

pub fn invalid(token: exchange.ProgressToken) -> exchange.ServerInput(Nil) {
  exchange.Closed(token)
}
