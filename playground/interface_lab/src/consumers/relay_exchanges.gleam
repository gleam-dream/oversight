// THROWAWAY: Can repeated wire IDs remain scoped to independent request exchanges?
import lab/blueprint
import lab/relay
import lab/relay_exchange as exchange
import lab/value

pub fn probe() -> Nil {
  let echo_tool =
    relay.context_tool(
      "echo",
      blueprint.field("input", blueprint.text()),
      blueprint.text(),
      blueprint.text(),
      fn(context, input) { Ok(context <> ":" <> input) },
    )
  let assert Ok(registry) = relay.registry([echo_tool])
  let initial = exchange.server(registry)
  let exchange_a = exchange.fresh_exchange()
  let exchange_b = exchange.fresh_exchange()
  let same_call_a =
    call("tenant-a", "shared-request", "shared-progress", "work-a")
  let same_call_b =
    call("tenant-b", "shared-request", "shared-progress", "work-b")

  let #(after_a, effects_a) =
    exchange.step(initial, exchange.Begin(exchange_a, same_call_a))
  let assert [exchange.OpenStream(opened_a), exchange.Invoke(task_a)] =
    effects_a
  let assert True = opened_a == exchange_a
  let invocation_a = exchange.invocation_id(task_a)

  let #(after_b, effects_b) =
    exchange.step(after_a, exchange.Begin(exchange_b, same_call_b))
  let assert [exchange.OpenStream(opened_b), exchange.Invoke(task_b)] =
    effects_b
  let assert True = opened_b == exchange_b
  let invocation_b = exchange.invocation_id(task_b)
  let assert True = invocation_a != invocation_b

  let #(after_a_progress, progress_a) =
    exchange.step(after_b, exchange.Progress(invocation_a, 0))
  let assert [
    exchange.SendProgress(
      exchange_for_progress_a,
      exchange.ProgressString("shared-progress"),
      0,
    ),
  ] = progress_a
  let assert True = exchange_for_progress_a == exchange_a
  let #(after_b_progress, progress_b) =
    exchange.step(after_a_progress, exchange.Progress(invocation_b, 0))
  let assert [
    exchange.SendProgress(
      exchange_for_progress_b,
      exchange.ProgressString("shared-progress"),
      0,
    ),
  ] = progress_b
  let assert True = exchange_for_progress_b == exchange_b
  let #(after_increasing_progress, accepted_increase) =
    exchange.step(after_b_progress, exchange.Progress(invocation_b, 1))
  let assert [
    exchange.SendProgress(
      exchange_for_increase,
      exchange.ProgressString("shared-progress"),
      1,
    ),
  ] = accepted_increase
  let assert True = exchange_for_increase == exchange_b
  let #(after_decreasing_progress, ignored_decrease) =
    exchange.step(after_increasing_progress, exchange.Progress(invocation_b, 0))
  let assert [] = ignored_decrease
  let #(after_duplicate_progress, no_duplicate_progress) =
    exchange.step(after_decreasing_progress, exchange.Progress(invocation_a, 0))
  let assert [] = no_duplicate_progress
  let #(after_negative_progress, no_negative_progress) =
    exchange.step(after_duplicate_progress, exchange.Progress(invocation_a, -1))
  let assert [] = no_negative_progress
  let #(after_close_a, cancel_a) =
    exchange.step(after_negative_progress, exchange.Closed(exchange_a))
  let assert [exchange.Cancel(cancelled_a), exchange.CloseStream(closed_a)] =
    cancel_a
  let assert True = cancelled_a == invocation_a
  let assert True = closed_a == exchange_a
  let #(after_close_again, no_second_cancel) =
    exchange.step(after_close_a, exchange.Closed(exchange_a))
  let assert [] = no_second_cancel

  // A worker completion and progress arriving after close cannot write to a
  // replacement exchange that reuses both wire identifiers.
  let late_a = exchange.perform(task_a)
  let #(after_late_a, no_late_a) = exchange.step(after_close_again, late_a)
  let assert [] = no_late_a
  let #(after_late_progress, no_late_progress) =
    exchange.step(after_late_a, exchange.Progress(invocation_a, 1))
  let assert [] = no_late_progress

  let completed_b = exchange.perform(task_b)
  let #(after_b_complete, complete_b) =
    exchange.step(after_late_progress, completed_b)
  let assert [
    exchange.Complete(
      completed_exchange_b,
      exchange.RequestString("shared-request"),
      Ok(value.Text("tenant-b:work-b")),
    ),
    exchange.CloseStream(closed_b),
  ] = complete_b
  let assert True = completed_exchange_b == exchange_b
  let assert True = closed_b == exchange_b
  let #(after_b_replay, no_second_result) =
    exchange.step(after_b_complete, completed_b)
  let assert [] = no_second_result
  let #(_after_terminal_progress, no_terminal_progress) =
    exchange.step(after_b_replay, exchange.Progress(invocation_b, 1))
  let assert [] = no_terminal_progress
  let #(after_begin_replay, no_second_invoke) =
    exchange.step(after_b_replay, exchange.Begin(exchange_b, same_call_b))
  let assert [] = no_second_invoke

  let exchange_c = exchange.fresh_exchange()
  let same_call_c =
    call("tenant-c", "shared-request", "shared-progress", "work-c")
  let #(after_c, effects_c) =
    exchange.step(after_begin_replay, exchange.Begin(exchange_c, same_call_c))
  let assert [exchange.OpenStream(opened_c), exchange.Invoke(task_c)] =
    effects_c
  let assert True = opened_c == exchange_c
  let invocation_c = exchange.invocation_id(task_c)
  let assert True = invocation_c != invocation_a
  let assert True = invocation_c != invocation_b
  let #(after_old_replay, no_old_result) = exchange.step(after_c, late_a)
  let assert [] = no_old_result
  let completed_c = exchange.perform(task_c)
  let #(after_c_complete, complete_c) =
    exchange.step(after_old_replay, completed_c)
  let assert [
    exchange.Complete(
      completed_exchange_c,
      exchange.RequestString("shared-request"),
      Ok(value.Text("tenant-c:work-c")),
    ),
    exchange.CloseStream(closed_c),
  ] = complete_c
  let assert True = completed_exchange_c == exchange_c
  let assert True = closed_c == exchange_c

  let tokenless_exchange = exchange.fresh_exchange()
  let tokenless_call = call_without_progress("tenant-d", "tokenless", "work-d")
  let #(after_tokenless, tokenless_effects) =
    exchange.step(
      after_c_complete,
      exchange.Begin(tokenless_exchange, tokenless_call),
    )
  let assert [exchange.OpenStream(_), exchange.Invoke(tokenless_task)] =
    tokenless_effects
  let tokenless_id = exchange.invocation_id(tokenless_task)
  let #(after_ignored_tokenless, ignored_tokenless_progress) =
    exchange.step(after_tokenless, exchange.Progress(tokenless_id, 10))
  let assert [] = ignored_tokenless_progress
  let #(after_tokenless_close, tokenless_cancel) =
    exchange.step(after_ignored_tokenless, exchange.Closed(tokenless_exchange))
  let assert [exchange.Cancel(cancelled_tokenless), exchange.CloseStream(_)] =
    tokenless_cancel
  let assert True = cancelled_tokenless == tokenless_id
  let #(after_repeated_close, no_repeated_close) =
    exchange.step(after_tokenless_close, exchange.Closed(tokenless_exchange))
  let assert [] = no_repeated_close

  let unknown_exchange = exchange.fresh_exchange()
  let unknown_call =
    exchange.ParsedCall(
      "tenant-a",
      exchange.RequestString("unknown"),
      exchange.Present(exchange.ProgressString("unused")),
      "missing-tool",
      value.Object([#("input", value.Text("x"))]),
    )
  let #(after_unknown, unknown_effects) =
    exchange.step(
      after_repeated_close,
      exchange.Begin(unknown_exchange, unknown_call),
    )
  let assert [
    exchange.OpenStream(_),
    exchange.Complete(_, _, Error(relay.UnknownTool("missing-tool"))),
    exchange.CloseStream(_),
  ] = unknown_effects
  let #(_after_unknown_replay, no_unknown_replay) =
    exchange.step(after_unknown, exchange.Begin(unknown_exchange, unknown_call))
  let assert [] = no_unknown_replay

  let preclosed_exchange = exchange.fresh_exchange()
  let #(after_preclose, no_preclose_effect) =
    exchange.step(after_unknown, exchange.Closed(preclosed_exchange))
  let assert [] = no_preclose_effect
  let #(after_preclose_replay, no_second_preclose_effect) =
    exchange.step(after_preclose, exchange.Closed(preclosed_exchange))
  let assert [] = no_second_preclose_effect
  let #(_after_preclosed_begin, no_late_begin) =
    exchange.step(
      after_preclose_replay,
      exchange.Begin(preclosed_exchange, same_call_a),
    )
  let assert [] = no_late_begin
  Nil
}

fn call(
  context: String,
  request_id: String,
  token: String,
  input: String,
) -> exchange.ParsedCall(String) {
  exchange.ParsedCall(
    context,
    exchange.RequestString(request_id),
    exchange.Present(exchange.ProgressString(token)),
    "echo",
    value.Object([#("input", value.Text(input))]),
  )
}

fn call_without_progress(
  context: String,
  request_id: String,
  input: String,
) -> exchange.ParsedCall(String) {
  exchange.ParsedCall(
    context,
    exchange.RequestString(request_id),
    exchange.Absent,
    "echo",
    value.Object([#("input", value.Text(input))]),
  )
}
