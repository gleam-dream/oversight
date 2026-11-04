-module(webhooks_test_ffi).
-export([raw_status/2, set_clock/1, clock/0]).

%% A settable clock in Unix seconds, shared by every process, for a
%% receiver whose freshness and retention a test drives by hand.
set_clock(Seconds) -> persistent_term:put({?MODULE, clock}, Seconds), nil.
clock() -> persistent_term:get({?MODULE, clock}).

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
