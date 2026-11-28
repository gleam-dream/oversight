-module(extractor_copy_cost_ffi).
-export([flat_size_bytes/1]).

%% Bytes a copy to another process takes. A copy does not keep sharing, so
%% it costs the term's flat size.
flat_size_bytes(Term) ->
    erts_debug:flat_size(Term) * erlang:system_info(wordsize).
