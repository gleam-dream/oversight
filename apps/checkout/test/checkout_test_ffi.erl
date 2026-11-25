-module(checkout_test_ffi).
-export([parent/1, raw_http/3, children/1, fail/1]).

%% The process that spawned Pid (OTP 25+). Used only to find the grind
%% attempt process that started a saga runner.
parent(Pid) ->
    case erlang:process_info(Pid, parent) of
        {parent, Parent} when is_pid(Parent) -> {ok, Parent};
        _ -> {error, nil}
    end.

%% The running children of a supervisor.
children(Supervisor) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(Supervisor), is_pid(Pid)].

%% Makes a process exit abnormally. A worker is killed. A supervisor is
%% told to terminate with an abnormal reason, so it stops its own children
%% first, as it does when it gives up on them; killing it instead would
%% leave them exiting, still registered, while its replacement starts.
fail(Pid) ->
    case proc_lib:translate_initial_call(Pid) of
        {supervisor, _, _} ->
            try proc_lib:stop(Pid, fault, 10000) catch exit:_ -> ok end;
        _ ->
            exit(Pid, kill)
    end,
    nil.

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
