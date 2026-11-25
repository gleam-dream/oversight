-module(telemetry_test_ffi).
-export([handlers/1]).

%% How many telemetry handlers are attached to events under Prefix.
handlers(Prefix) ->
    length(telemetry:list_handlers([binary_to_atom(P) || P <- Prefix])).
