-module(owned_handlers_ffi).
-export([handlers_with_id_prefix/1]).

%% How many telemetry handlers have an id that starts with Prefix.
handlers_with_id_prefix(Prefix) ->
    length([H || #{id := Id} = H <- telemetry:list_handlers([]),
                 is_binary(Id),
                 binary:longest_common_prefix([Id, Prefix]) =:= byte_size(Prefix)]).
