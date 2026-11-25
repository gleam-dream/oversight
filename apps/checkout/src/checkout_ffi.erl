-module(checkout_ffi).
-export([attempt/1, stop_supervisor/1]).

%% Runs Fun and reports whether it returned instead of raising.
attempt(Fun) ->
    try Fun() of
        _ -> true
    catch
        _:_ -> false
    end.

%% Stops a supervisor and waits until it has stopped its children, in
%% reverse start order, and exited. Works from any process. A supervisor
%% that is already gone counts as stopped.
stop_supervisor(Pid) ->
    try proc_lib:stop(Pid, shutdown, infinity) of
        _ -> nil
    catch
        exit:_ -> nil
    end.
