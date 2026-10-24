%% THROWAWAY: Compare UTF-8 schema identifiers for canonical ordering only.
-module(blueprint_runtime_ffi).
-export([string_less/2]).

string_less(Left, Right) when is_binary(Left), is_binary(Right) ->
    Left < Right.
