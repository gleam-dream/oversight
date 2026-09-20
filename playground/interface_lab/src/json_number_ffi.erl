%% THROWAWAY: Exact IEEE-754 boundary support for the Gleam decimal kernel.
-module(json_number_ffi).
-export([
    byte_length/1,
    byte_codes/1,
    ascii_string/1,
    integer_to_string/1,
    integer_divide/2,
    integer_remainder/2,
    float_parts/1,
    parse_float_candidate/1,
    float_fixture/1,
    float_bits_hex/1,
    join_strings/2,
    emit_line/1
]).

byte_length(Value) when is_binary(Value) -> byte_size(Value).

byte_codes(Value) when is_binary(Value) -> binary_to_list(Value).

ascii_string(Bytes) when is_list(Bytes) -> list_to_binary(Bytes).

integer_to_string(Value) when is_integer(Value) -> integer_to_binary(Value).

integer_divide(Dividend, Divisor) when is_integer(Dividend), is_integer(Divisor), Divisor =/= 0 ->
    Dividend div Divisor.

integer_remainder(Dividend, Divisor) when is_integer(Dividend), is_integer(Divisor), Divisor =/= 0 ->
    Dividend rem Divisor.

join_strings([], _Separator) -> <<>>;
join_strings([Value], _Separator) -> Value;
join_strings([Value | Rest], Separator) ->
    <<Value/binary, Separator/binary, (join_strings(Rest, Separator))/binary>>.

emit_line(Line) when is_binary(Line) ->
    io:put_chars([Line, $\n]),
    nil.

float_parts(Value) when is_float(Value) ->
    <<Sign:1, Exponent:11, Fraction:52>> = <<Value:64/float-big>>,
    case Exponent of
        16#7ff -> non_finite_parts;
        0 when Fraction =:= 0 -> {finite_parts, Sign =:= 1, 0, 0};
        0 -> {finite_parts, Sign =:= 1, Fraction, -1074};
        _ -> {finite_parts, Sign =:= 1, (1 bsl 52) bor Fraction, Exponent - 1023 - 52}
    end.

parse_float_candidate(Token) when is_binary(Token) ->
    case re:run(
        Token,
        <<"^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$">>,
        [{capture, none}]
    ) of
        nomatch -> candidate_invalid;
        match ->
            FloatToken = ensure_float_lexeme(Token),
            try list_to_float(binary_to_list(FloatToken)) of
                Value ->
                    case float_parts(Value) of
                        non_finite_parts -> candidate_overflow;
                        _ -> {candidate_value, Value}
                    end
            catch
                error:badarg -> candidate_overflow;
                _:_ -> candidate_overflow
            end
    end.

float_fixture(positive_zero) -> from_bits(16#0000000000000000);
float_fixture(negative_zero) -> from_bits(16#8000000000000000);
float_fixture(half) -> from_bits(16#3fe0000000000000);
float_fixture(tenth) -> from_bits(16#3fb999999999999a);
float_fixture(negative_tenth) -> from_bits(16#bfb999999999999a);
float_fixture(minimum_subnormal) -> from_bits(16#0000000000000001);
float_fixture(maximum_finite) -> from_bits(16#7fefffffffffffff).

float_bits_hex(Value) when is_float(Value) ->
    <<Bits:64/unsigned-big>> = <<Value:64/float-big>>,
    binary:encode_hex(<<Bits:64/unsigned-big>>, lowercase).

from_bits(Bits) ->
    <<Value:64/float-big>> = <<Bits:64/unsigned-big>>,
    Value.

ensure_float_lexeme(Token) ->
    case binary:match(Token, <<".">>) of
        {_, 1} -> Token;
        nomatch -> insert_decimal_point(Token)
    end.

insert_decimal_point(Token) ->
    case binary:match(Token, <<"e">>) of
        {Position, 1} -> insert_before(Token, Position, <<".0">>);
        nomatch ->
            case binary:match(Token, <<"E">>) of
                {Position, 1} -> insert_before(Token, Position, <<".0">>);
                nomatch -> <<Token/binary, ".0">>
            end
    end.

insert_before(Token, Position, Inserted) ->
    <<Mantissa:Position/binary, Exponent/binary>> = Token,
    <<Mantissa/binary, Inserted/binary, Exponent/binary>>.
