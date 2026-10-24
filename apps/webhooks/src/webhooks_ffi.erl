-module(webhooks_ffi).
-export([unique_int/0, now_ms/0, monotonic_ms/0]).

unique_int() -> erlang:unique_integer([positive]).

now_ms() -> erlang:system_time(millisecond).

%% The clock grind and http_gun stamp their events with.
monotonic_ms() -> erlang:monotonic_time(millisecond).
