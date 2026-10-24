//// Two http_gun clients with different jobs.
////
//// The fetcher follows document URLs that arrive with the batch: an SSRF
//// surface. It admits only the document hosts, a short deadline, a small
//// pool, and a body cap. The LLM client reaches a fixed set of provider
//// origins and streams long answers; llm_wire's per-call view lifts its
//// request timeout to the call's overall budget. One shared client would
//// force one destination policy onto both, so a document URL could reach the
//// provider origin.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/destination
import sinal/forwarder

pub type Clients {
  Clients(fetcher: http_gun.Client, llm: http_gun.Client)
}

pub type Network {
  /// Scripted loopback services; document hosts resolve to 127.0.0.1, and
  /// the provider server is the one loopback port the LLM client may reach.
  Loopback(document_hosts: List(String), provider_port: Int)
}

pub fn fetcher_config(
  network: Network,
  observations: Option(forwarder.Forwarder),
) -> config.Config {
  let Loopback(document_hosts:, ..) = network
  config.default()
  |> config.with_request_timeout(config.After(duration.seconds(5)))
  |> config.with_connect_timeout(duration.seconds(1))
  |> config.with_max_connections(8)
  |> config.with_max_connections_per_origin(2)
  |> config.with_max_response_body_bytes(1_048_576)
  |> config.with_destination(
    destination.loopback_only() |> destination.only_hosts(document_hosts),
  )
  |> config.with_resolver(fn(_host, _remaining) {
    Ok([destination.Ipv4(127, 0, 0, 1)])
  })
  |> config.with_label("fetcher")
  |> observed(observations)
}

pub fn llm_config(
  network: Network,
  observations: Option(forwarder.Forwarder),
) -> config.Config {
  let Loopback(provider_port:, ..) = network
  config.default()
  |> config.with_destination(
    destination.loopback_only()
    |> destination.only_hosts(["127.0.0.1:" <> int.to_string(provider_port)]),
  )
  |> config.with_label("llm")
  |> observed(observations)
}

fn observed(
  settings: config.Config,
  observations: Option(forwarder.Forwarder),
) -> config.Config {
  case observations {
    Some(forwarder) -> config.with_observations(settings, forwarder)
    None -> settings
  }
}

pub fn start(
  network: Network,
  observations: Option(forwarder.Forwarder),
) -> Result(Clients, http_gun.StartError) {
  use fetcher <- result.try(
    http_gun.start(fetcher_config(network, observations)),
  )
  use llm <- result.try(http_gun.start(llm_config(network, observations)))
  Ok(Clients(fetcher:, llm:))
}

pub fn stop(clients: Clients) -> Nil {
  http_gun.stop(clients.fetcher)
  http_gun.stop(clients.llm)
}
