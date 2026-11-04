-module(extractor_raw_http_ffi).
-export([status/2]).

%% Sends one raw HTTP/1.1 request to a loopback port and returns the
%% response's status code, so a test can frame a body as a client library
%% never would.
status(Port, Request) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 2000) of
        {ok, Socket} ->
            Result =
                case gen_tcp:send(Socket, Request) of
                    ok -> read_status(Socket, <<>>);
                    {error, _} -> {error, nil}
                end,
            gen_tcp:close(Socket),
            Result;
        {error, _} ->
            {error, nil}
    end.

read_status(_Socket, <<"HTTP/1.1 ", Code:3/binary, _/binary>>) ->
    {ok, binary_to_integer(Code)};
read_status(Socket, Seen) when byte_size(Seen) < 12 ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, More} -> read_status(Socket, <<Seen/binary, More/binary>>);
        {error, _} -> {error, nil}
    end;
read_status(_Socket, _Seen) ->
    {error, nil}.
