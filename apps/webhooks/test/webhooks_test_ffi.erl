-module(webhooks_test_ffi).
-export([raw_status/2]).

%% Sends raw bytes to a loopback HTTP server and returns the response
%% status, or 0 when none arrives. For framing an HTTP client will not send.
raw_status(Port, Request) ->
    {ok, Socket} =
        gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 2000),
    ok = gen_tcp:send(Socket, Request),
    Status =
        case gen_tcp:recv(Socket, 0, 5000) of
            {ok, <<"HTTP/1.1 ", Code:3/binary, _/binary>>} ->
                binary_to_integer(Code);
            _ ->
                0
        end,
    gen_tcp:close(Socket),
    Status.
