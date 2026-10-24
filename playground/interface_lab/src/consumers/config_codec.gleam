// THROWAWAY: Can a pure codec describe domain input and retain error location?
import lab/blueprint
import lab/value

pub type Config {
  Config(host: String, port: Int)
}

pub fn codec() -> blueprint.Codec(Config) {
  blueprint.imap(
    blueprint.pair(blueprint.text(), blueprint.int()),
    fn(pair) { Config(pair.0, pair.1) },
    fn(config) { #(config.host, config.port) },
  )
}

pub fn load(raw: value.Value) -> Result(Config, blueprint.DecodeError) {
  case blueprint.decode(codec(), raw) {
    Ok(config) -> Ok(config)
    Error(error) -> Error(blueprint.DecodeAtField("server", error))
  }
}

pub fn probe() -> Nil {
  let config = Config("localhost", 8080)
  let assert Ok(encoded) = blueprint.encode(codec(), config)
  let assert Ok(decoded) = load(encoded)
  let assert True = decoded == config
  let assert Error(blueprint.DecodeAtField(
    "server",
    blueprint.DecodeAtIndex(1, _),
  )) = load(value.Array([value.Text("localhost"), value.Text("bad-port")]))
  Nil
}
