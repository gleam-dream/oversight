-module(admission_fixture).
-export([with_cleanup/2, stop_process/1, await_exit/1, wait_stopped/2, monotonic_milliseconds/0, open_request/3, read_status/1, close/1]).

with_cleanup(Work, Cleanup) ->
    try Work() after Cleanup() end.

%% A monitor acknowledgement makes cleanup observable even on assertion failure.
stop_process(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> nil
    after 2000 -> error({fixture_cleanup_timeout, Pid}) end.

await_exit(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> nil
    after 2000 -> erlang:demonitor(Ref, [flush]), error({fixture_exit_timeout, Pid}) end.

%% A bounded observation, unlike stop_process this never terminates the subject.
wait_stopped(Pid, Timeout) ->
    Ref = erlang:monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> true
    after Timeout -> erlang:demonitor(Ref, [flush]), false end.

monotonic_milliseconds() -> erlang:monotonic_time(millisecond).

%% Test-only local HTTP/1.1 peer. No Relay/Mist records or private modules.
open_request(Port, Headers, Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 2000) of
        {ok, Socket} ->
            Wire = ["POST / HTTP/1.1\r\nHost: 127.0.0.1\r\n",
                "Connection: close\r\nContent-Length: ", integer_to_binary(byte_size(Body)),
                "\r\n", [[K, ": ", V, "\r\n"] || {K, V} <- Headers], "\r\n", Body],
            case gen_tcp:send(Socket, Wire) of
                ok -> {ok, Socket};
                {error, Reason} -> gen_tcp:close(Socket), {error, describe(Reason)}
            end;
        {error, Reason} -> {error, describe(Reason)}
    end.

read_status(Socket) ->
    read_status(Socket, <<>>, erlang:monotonic_time(millisecond) + 2000).

read_status(Socket, Acc, Deadline) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} ->
            [<<"HTTP/1.1">>, Code | _] = binary:split(Acc, <<" ">>, [global]),
            {ok, binary_to_integer(Code)};
        nomatch ->
            Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
            case gen_tcp:recv(Socket, 0, Remaining) of
                {ok, Chunk} -> read_status(Socket, <<Acc/binary, Chunk/binary>>, Deadline);
                {error, Reason} -> {error, describe(Reason)}
            end
    end.

close(Socket) -> gen_tcp:close(Socket), nil.

describe(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
