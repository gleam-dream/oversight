//// Two http_gun clients with different jobs.
////
//// The fetcher follows document URLs that arrive with the batch: an SSRF
//// surface. It admits only the document hosts, a short deadline, a small
//// pool, and a body cap. The LLM client reaches a fixed set of provider
//// origins, streams long answers, and needs a deadline ceiling above the
//// llm_wire overall budget. One shared client would force one destination
//// policy onto both, so a document URL could reach the provider origin.

import gleam/option.{type Option, Some}
import gleam/result
import http_gun
import http_gun/config
import http_gun/destination
import sinal/forwarder

pub type Clients {
  Clients(fetcher: http_gun.Client, llm: http_gun.Client)
}

pub type Network {
  /// Scripted loopback services; document hosts resolve to 127.0.0.1.
  Loopback(document_hosts: List(String))
}

pub fn fetcher_config(
  network: Network,
  observations: Option(forwarder.Forwarder),
) -> config.Config {
  let defaults = config.default()
  let Loopback(document_hosts) = network
  config.Config(
    ..defaults,
    deadline_ms: 5000,
    connect_ms: 1000,
    limits: config.Limits(
      ..defaults.limits,
      connections: 8,
      per_origin: 2,
      collect_bytes: 1_048_576,
    ),
    observations:,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
      allowed_hosts: Some(document_hosts),
      resolver: Some(fn(_host, _remaining_ms) {
        Ok([destination.Ipv4(127, 0, 0, 1)])
      }),
    ),
  )
}

pub fn llm_config(observations: Option(forwarder.Forwarder)) -> config.Config {
  let defaults = config.default()
  config.Config(
    ..defaults,
    deadline_ms: 120_000,
    observations:,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
      allowed_hosts: Some(["127.0.0.1"]),
    ),
  )
}

pub fn start(
  network: Network,
  observations: Option(forwarder.Forwarder),
) -> Result(Clients, http_gun.Failure) {
  use fetcher <- result.try(
    http_gun.start(fetcher_config(network, observations)),
  )
  use llm <- result.try(http_gun.start(llm_config(observations)))
  Ok(Clients(fetcher:, llm:))
}

pub fn stop(clients: Clients) -> Nil {
  let _ = http_gun.stop(clients.fetcher)
  let _ = http_gun.stop(clients.llm)
  Nil
}
