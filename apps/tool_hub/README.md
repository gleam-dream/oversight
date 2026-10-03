# tool_hub

MCP in both directions, built from public package APIs only:

1. **inventory**, a Relay MCP server, exposes three typed tools:
   `search_products`, `get_stock` (both read-only) and `reserve_stock`.
2. A **fabric agent** mounts those tools through the Relay client and answers
   questions with a scripted LLM provider (llm_wire over an http_gun client).
3. A second Relay server exposes that agent as the MCP tool **`ask_assistant`**,
   so any MCP client can call the agent.

Everything runs on loopback. The LLM provider is a small mist server that
speaks llm_wire's scripted wire format (`llm_wire/testing.config()`), so no
key or network is used. Friction and proposals are in [FEEDBACK.md](FEEDBACK.md).

## Run

From this directory, inside the oversight dev shell:

```sh
gleam run    # one question, end to end, with the telemetry trail of the run
gleam test   # 14 scenarios
```

## Modules

| Module                  | Role                                                                                                    |
| ----------------------- | ------------------------------------------------------------------------------------------------------- |
| `tool_hub/inventory`    | Domain, Blueprint codecs, Relay definitions and the inventory server                                    |
| `tool_hub/remote_tools` | Glue: Relay tools as fabric tools (typed from definitions, dynamic from `tools/list`) and error mapping |
| `tool_hub/assistant`    | The fabric agent, `ask_assistant` on a second Relay server, and its `tool.cancelled` handler            |
| `tool_hub/scripted_llm` | Loopback LLM provider for the scripted wire format, with a "hold the stream open" step                  |
| `tool_hub/telemetry`    | Sinal handlers for relay, fabric, llm_wire, http_gun and sinal events; joins one run across packages    |
| `tool_hub`              | Wiring (`start`/`stop`), the demo script and `main`                                                     |

## Seams exercised

| Seam                                     | Where                                                                                                                   | Test                                                                                                                                                                               |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One codec across relay, fabric, llm_wire | `remote_tools.fabric_definition`, `remote_tools.mount`                                                                  | `common_path_answers_through_both_mcp_servers_test`, `typed_tool_schema_is_identical_in_all_three_places_test`                                                                     |
| Dynamic schemas without native types     | `remote_tools.discover`, `tool.input_contract`                                                                          | `discovered_tools_work_without_native_types_test`                                                                                                                                  |
| MCP `isError` → fabric `Explain`         | `remote_tools.classify`                                                                                                 | `remote_tool_error_is_shown_to_the_model_test`                                                                                                                                     |
| Lost MCP call → fabric `Uncertain` → MCP | `remote_tools.classify`, `assistant.tool_error`                                                                         | `timed_out_reservation_is_uncertain_test`, `unreachable_server_before_a_reservation_is_explained_test`, `unreachable_server_on_a_read_only_tool_is_explained_test`                 |
| Invalid model arguments                  | fabric's argument check on the shared codec                                                                             | `invalid_model_arguments_never_reach_the_server_test`                                                                                                                              |
| Cancellation MCP → agent → LLM stream    | `assistant.await_or_cancel` (reacts to `tool.cancelled`); Relay `client.close`, `with_cancellation`, timeout            | `disconnecting_mcp_client_cancels_run_and_model_stream_test`, `cancelling_one_call_keeps_the_client_open_test`, `relay_client_timeout_cancels_the_run_test` and two negative tests |
| Telemetry correlation                    | `telemetry.follow`; Relay `http.with_correlation` and `tool.correlation`, reused on the HTTP Gun and Relay client views | `common_path_answers_through_both_mcp_servers_test`                                                                                                                                |
| http_gun loopback policy, client label   | `tool_hub.provider_client`                                                                                              | every test                                                                                                                                                                         |

Builds on the [ecosystem pilot](../../playground/ecosystem_pilot/), which
covered Relay → LLM Wire directly; this app puts fabric between them and
adds the reverse direction.
