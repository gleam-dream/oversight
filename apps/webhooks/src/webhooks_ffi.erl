-module(webhooks_ffi).
-export([parse_ip/1, unique_int/0, now_ms/0]).

%% Parse an IP literal (no DNS). Returns the address as a list of integers:
%% four for IPv4, eight for IPv6. Glue: http_gun parses literals internally
%% (http_gun/internal/bridge.parse_address) but does not expose it.
parse_ip(Text) ->
    case inet:parse_strict_address(binary_to_list(Text)) of
        {ok, Tuple} -> {ok, tuple_to_list(Tuple)};
        {error, _} -> {error, nil}
    end.

unique_int() -> erlang:unique_integer([positive]).

now_ms() -> erlang:system_time(millisecond).
