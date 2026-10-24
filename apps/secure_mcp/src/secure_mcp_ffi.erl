%% Listener helpers for the app's start-up and shutdown.
-module(secure_mcp_ffi).

-export([free_port/0, shutdown/1]).

%% A currently free loopback port. The token audience and Hellhound's redirect
%% URI name the app's port before the app's listener exists.
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

%% Stops a supervisor started (and linked) by the calling process with the
%% `shutdown` reason, so OTP logs no crash report.
shutdown(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> nil after 5000 -> nil end.
