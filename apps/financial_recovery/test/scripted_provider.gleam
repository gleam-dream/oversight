import gleam/erlang/process

pub type Mode {
  Reply
  Hold
  LoseReply
}

pub type Provider {
  Provider(pid: process.Pid, port: Int)
}

pub fn start(mode: Mode, notices: process.Subject(String)) -> Provider {
  let #(pid, port) =
    start_server(
      case mode {
        Reply -> 0
        Hold -> 1
        LoseReply -> 2
      },
      notices,
    )
  Provider(pid, port)
}

@external(erlang, "financial_fixture", "start_provider")
fn start_server(
  mode: Int,
  notices: process.Subject(String),
) -> #(process.Pid, Int)

@external(erlang, "financial_fixture", "visible")
pub fn visible(provider: process.Pid, visible: Bool) -> Nil

@external(erlang, "financial_fixture", "counts")
pub fn counts(provider: process.Pid) -> #(Int, Int)

@external(erlang, "financial_fixture", "forget")
pub fn forget(provider: process.Pid, operation: String) -> Nil

@external(erlang, "financial_fixture", "reference")
pub fn reference(provider: process.Pid, operation: String, value: String) -> Nil

@external(erlang, "financial_fixture", "block_next_lookup")
pub fn block_next_lookup(
  provider: process.Pid,
  notices: process.Subject(process.Pid),
) -> Nil

@external(erlang, "financial_fixture", "release_lookup")
pub fn release_lookup(handler: process.Pid, status: Int) -> Nil

@external(erlang, "financial_fixture", "shutdown")
pub fn stop(provider: process.Pid) -> Nil
