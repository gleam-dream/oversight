-module(checkout_ffi).
-export([stop_supervisor/1]).

%% Stops a supervisor and waits until it has stopped its children, in
%% reverse start order, and exited. Works from any process. A supervisor
%% that is already gone counts as stopped.
stop_supervisor(Pid) ->
    try proc_lib:stop(Pid, shutdown, infinity) of
        _ -> nil
    catch
        exit:_ -> nil
    end.
