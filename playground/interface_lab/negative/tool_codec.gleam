// THROWAWAY: Reject a codec that disagrees with the registered handler.
import consumers/adapters
import lab/blueprint
import lab/relay

pub fn invalid() -> relay.Tool {
  relay.tool(
    "lookup",
    blueprint.text(),
    blueprint.text(),
    adapters.error_codec(),
    adapters.lookup,
  )
}
