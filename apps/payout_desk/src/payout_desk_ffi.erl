%% Listener and supervision helpers for the composition root.
-module(payout_desk_ffi).

-export([free_port/0, shutdown/1]).

%% A currently free loopback port. The token audience names the desk's MCP
%% URL before its listener exists.
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

%% Stops a linked supervisor the way its parent would, without taking the
%% caller down with it.
shutdown(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after 10000 ->
        exit(Pid, kill),
        nil
    end.
