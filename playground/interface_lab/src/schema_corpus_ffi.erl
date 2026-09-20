%% THROWAWAY: Test-only JSON export for an independent schema validator.
-module(schema_corpus_ffi).
-export([emit/1]).

emit(Value) ->
    io:put_chars([json:encode(to_json(Value)), $\n]),
    nil.

to_json(null) -> null;
to_json({bool, Value}) -> Value;
to_json({int, Value}) -> Value;
to_json({text, Value}) -> Value;
to_json({array, Values}) -> [to_json(Value) || Value <- Values];
to_json({object, Fields}) -> maps:from_list([{Name, to_json(Value)} || {Name, Value} <- Fields]).
