%% THROWAWAY: Pure text escapes and integer formatting for generated Gleam source.
-module(blueprint_codegen_ffi).
-export([string_literal/1, integer_to_string/1]).

string_literal(Text) when is_binary(Text) ->
    Codepoints = unicode:characters_to_list(Text, utf8),
    Escaped = lists:flatmap(fun escape_codepoint/1, Codepoints),
    unicode:characters_to_binary([$" | Escaped] ++ [$"]).

integer_to_string(Value) when is_integer(Value) ->
    integer_to_binary(Value).

escape_codepoint($") -> "\\\"";
escape_codepoint($\\) -> "\\\\";
escape_codepoint($\n) -> "\\n";
escape_codepoint($\r) -> "\\r";
escape_codepoint($\t) -> "\\t";
escape_codepoint(Value) when Value < 32; Value >= 127 ->
    lists:flatten(io_lib:format("\\u{~.16B}", [Value]));
escape_codepoint(Value) -> [Value].
