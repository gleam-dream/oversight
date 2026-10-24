// THROWAWAY: Can an injected one-call provider preserve per-item batch failures?
import lab/blueprint.{type Codec}
import lab/llm
import lab/value

pub type PipelineItem {
  PipelineItem(id: String, prompt: String)
}

pub type Insight {
  Insight(summary: String)
}

pub type ItemResult {
  ItemResult(id: String, outcome: Result(Insight, llm.CallError))
}

// A deterministic response function makes a provider that can run fully offline.
pub fn fake_provider(
  respond: fn(String) -> Result(value.Value, llm.CallError),
) -> llm.Provider {
  llm.provider(fn(request) {
    case request.messages {
      [llm.User(prompt)] -> respond(prompt)
      _ -> Error(llm.UnsupportedCapability)
    }
  })
}

pub fn request_for(item: PipelineItem) -> llm.Request {
  let PipelineItem(_, prompt) = item
  llm.Request([llm.User(prompt)], 128)
}

pub fn run_item(provider: llm.Provider, item: PipelineItem) -> ItemResult {
  let PipelineItem(id, _) = item
  let outcome = llm.structured(provider, request_for(item), insight_codec())
  ItemResult(id, outcome)
}

// Every result retains its item id and its own refusal, provider failure, or
// structured-output decode error. One failed response never stops the batch.
pub fn run_batch(
  provider: llm.Provider,
  items: List(PipelineItem),
) -> List(ItemResult) {
  map(items, fn(item) { run_item(provider, item) })
}

fn insight_codec() -> Codec(Insight) {
  blueprint.new(
    fn(insight) {
      let Insight(summary) = insight
      Ok(value.Object([#("summary", value.Text(summary))]))
    },
    fn(raw) {
      case raw {
        value.Object([#("summary", value.Text(summary))]) ->
          Ok(Insight(summary))
        _ -> Error(blueprint.CannotDecode("Expected an insight with a summary"))
      }
    },
  )
}

fn map(items: List(a), transform: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [head, ..tail] -> [transform(head), ..map(tail, transform)]
  }
}

pub fn probe() -> Nil {
  let provider =
    fake_provider(fn(prompt) {
      case prompt {
        "good" -> Ok(value.Object([#("summary", value.Text("retained"))]))
        "refused" -> Error(llm.Refused("scripted refusal"))
        _ -> Ok(value.Int(42))
      }
    })
  let assert [
    ItemResult("a", Ok(Insight("retained"))),
    ItemResult("b", Error(llm.Refused("scripted refusal"))),
    ItemResult("c", Error(llm.InvalidStructuredOutput(_))),
  ] =
    run_batch(provider, [
      PipelineItem("a", "good"),
      PipelineItem("b", "refused"),
      PipelineItem("c", "invalid"),
    ])
  Nil
}
