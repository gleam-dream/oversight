-module(support_ffi).
-export([unique/0, ensure/2, quiet_pool_shutdown/0, once/1]).

%% A positive integer no other call on this node returns.
unique() ->
    erlang:unique_integer([positive, monotonic]).

%% Run Body, then Cleanup however Body ends.
ensure(Body, Cleanup) ->
    try
        Body()
    after
        Cleanup()
    end.

%% pgo's pool supervisor reports an error each time a pool is stopped while
%% a connection is opening, and a killed process reports its crash. Every test
%% stops its pools, so drop exactly those reports.
quiet_pool_shutdown() ->
    Filter = fun(#{msg := {report, #{label := {supervisor, shutdown_error},
                                     report := Report}}}, _) ->
                     case proplists:get_value(supervisor, Report) of
                         {_, pgo_pool_sup} -> stop;
                         _ -> ignore
                     end;
                (#{msg := {report, #{label := {supervisor, child_terminated},
                                     report := Report}}}, _) ->
                     case proplists:get_value(reason, Report) of
                         killed -> stop;
                         _ -> ignore
                     end;
                (#{msg := {report, #{label := {proc_lib, crash},
                                     report := [Info | _]}}}, _) ->
                     case proplists:get_value(error_info, Info) of
                         {exit, killed, _} -> stop;
                         _ -> ignore
                     end;
                (_, _) -> ignore
             end,
    _ = logger:add_primary_filter(clinic_quiet_pool_shutdown, {Filter, nil}),
    nil.

%% True the first time it is called with Key on this node, false after.
once(Key) ->
    Counter = case persistent_term:get({?MODULE, Key}, undefined) of
                  undefined ->
                      C = atomics:new(1, []),
                      persistent_term:put({?MODULE, Key}, C),
                      C;
                  C -> C
              end,
    atomics:add_get(Counter, 1, 1) =:= 1.
