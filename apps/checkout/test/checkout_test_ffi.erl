-module(checkout_test_ffi).
-export([parent/1, raw_http/3]).

%% The process that spawned Pid (OTP 25+). Used only to find the grind
%% attempt process that started a saga runner.
parent(Pid) ->
    case erlang:process_info(Pid, parent) of
        {parent, Parent} when is_pid(Parent) -> {ok, Parent};
        _ -> {error, nil}
    end.

%% Sends Request verbatim to 127.0.0.1:Port and returns the status code of
%% the reply. Used to send framings an HTTP client would not choose, such as
%% a chunked body. A closed connection before any reply is an error.
raw_http(Port, Request, TimeoutMs) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], TimeoutMs) of
        {error, _} -> {error, nil};
        {ok, Socket} ->
            Sent = gen_tcp:send(Socket, Request),
            Reply = read_status(Socket, <<>>, TimeoutMs),
            gen_tcp:close(Socket),
            case {Sent, Reply} of
                {ok, {ok, Status}} -> {ok, Status};
                _ -> {error, nil}
            end
    end.

read_status(Socket, Buffer, TimeoutMs) ->
    case binary:split(Buffer, <<"\r\n">>) of
        [<<"HTTP/1.1 ", Code:3/binary, _/binary>>, _] -> {ok, binary_to_integer(Code)};
        [_, _] -> {error, nil};
        [_] ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, More} -> read_status(Socket, <<Buffer/binary, More/binary>>, TimeoutMs);
                {error, _} -> {error, nil}
            end
    end.
