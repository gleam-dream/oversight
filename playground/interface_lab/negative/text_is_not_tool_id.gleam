// THROWAWAY: Text block routing and tool-result correlation are distinct.
import lab/llm_stream_events as stream

pub fn invalid() {
  stream.ArgumentsDelta(stream.TextBlockId("block-1"), "fragment")
}
