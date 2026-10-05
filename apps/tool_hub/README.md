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
gleam test   # 16 scenarios
```

## Modules

| Module                  | Role                                                                                                 |
| ----------------------- | ---------------------------------------------------------------------------------------------------- |
| `tool_hub/inventory`    | Domain, Blueprint codecs, Relay definitions and the inventory server                                 |
| `tool_hub/assistant`    | The typed-answer fabric agent and `ask_assistant` on a second Relay server (`relay_serve.serve`)     |
| `tool_hub/scripted_llm` | Loopback LLM provider for the scripted wire format, with a "hold the stream open" step               |
| `tool_hub/telemetry`    | Sinal handlers for relay, fabric, llm_wire, http_gun and sinal events; joins one run across packages |
| `tool_hub`              | Wiring (`start`/`stop`), the demo script and `main`                                                  |

## Seams exercised

| Seam                                     | Where                                                                                                                    | Test                                                                                                                                                                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| One codec across relay, fabric, llm_wire | `relay_tools.tool`                                                                                                       | `common_path_answers_through_both_mcp_servers_test`, `typed_tool_schema_is_identical_in_all_three_places_test`                                                                                                                                         |
| Dynamic schemas without native types     | `relay_discovery.discovered`                                                                                             | `discovered_tools_work_without_native_types_test`                                                                                                                                                                                                      |
| MCP `isError` → fabric `Explain`         | `relay_tools.tool` (built-in classification)                                                                             | `remote_tool_error_is_shown_to_the_model_test`                                                                                                                                                                                                         |
| Lost MCP call → fabric `Uncertain` → MCP | `relay_tools.tool`, `relay_serve.serve` (`outcome_unknown`)                                                              | `timed_out_reservation_is_uncertain_test`, `unreachable_server_before_a_reservation_is_explained_test`, `unreachable_server_on_a_read_only_tool_is_explained_test`                                                                                     |
| Invalid model arguments                  | fabric's argument check on the shared codec                                                                              | `invalid_model_arguments_never_reach_the_server_test`                                                                                                                                                                                                  |
| Cancellation MCP → agent → LLM stream    | `relay_serve.serve` (unkeyed call owns its run, keyed call does not); Relay `client.close`, `with_cancellation`, timeout | `disconnecting_mcp_client_cancels_run_and_model_stream_test`, `cancelling_one_call_keeps_the_client_open_test`, `relay_client_timeout_cancels_the_run_test`, `keyed_call_outlives_its_disconnect_test`, `retried_keyed_call_reaches_the_same_run_test` |
| Telemetry correlation                    | `telemetry.follow`; the caller's `client.with_correlation` crosses both Relay servers and every package's view           | `common_path_answers_through_both_mcp_servers_test`                                                                                                                                                                                                    |
| http_gun loopback policy, client label   | `tool_hub.provider_client`                                                                                               | every test                                                                                                                                                                                                                                             |

Builds on the [ecosystem pilot](../../playground/ecosystem_pilot/), which
covered Relay → LLM Wire directly; this app puts fabric between them and
adds the reverse direction.

## Round 9 composition

The app owns four compiled recipe copies: `relay_tools` (40 lines),
`relay_discovery` (50), `relay_serve` (41), and `relay_run` (12, used in tests).
They match fabric's README and unpublished `consumers/relay_tools` package.
`fabric/invoke` owns request/run lifecycle; Relay owns MCP and delivery
information. The app has no bridge package dependency.

The demo correlates both its listing and question. It reports zero unjoined
Relay or llm_wire events. See [FEEDBACK.md](FEEDBACK.md#after-round-9) for code
cost, retained coverage and remaining composition friction.
