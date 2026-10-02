-module(research_agent_ffi).
-export([shutdown/1, start_peer/0, peer_call/4, kill_peer/1, pid_to_string/1, string_to_pid/1]).

%% Stops a linked supervisor the way its parent would, without taking the
%% caller down with it.
shutdown(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after 5000 ->
        exit(Pid, kill),
        nil
    end.

%% A second VM on this host with the same code paths, controlled over its
%% standard I/O (no distribution needed).
start_peer() ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    Args = lists:flatmap(fun(P) -> ["-pa", P] end, Paths),
    case peer:start(#{connection => standard_io, args => Args, wait_boot => 30000}) of
        {ok, Peer} ->
            unlink(Peer),
            {ok, _} = peer:call(Peer, application, ensure_all_started, [research_agent], 30000),
            {ok, Peer};
        {ok, Peer, _Node} ->
            unlink(Peer),
            {ok, _} = peer:call(Peer, application, ensure_all_started, [research_agent], 30000),
            {ok, Peer};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

peer_call(Peer, Module, Function, Args) ->
    try
        {ok, peer:call(Peer, Module, Function, Args, 60000)}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

%% SIGKILL: no drain, no handoff, no lease release.
kill_peer(Peer) ->
    OsPid = peer:call(Peer, os, getpid, [], 5000),
    os:cmd("kill -9 " ++ OsPid),
    nil.

pid_to_string(Pid) -> list_to_binary(pid_to_list(Pid)).

string_to_pid(Text) ->
    try {ok, list_to_pid(binary_to_list(Text))}
    catch _:_ -> {error, nil}
    end.
