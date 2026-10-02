-module(tool_hub_ffi).
-export([stop_process/1]).

%% Stops an OTP process (a supervisor started unlinked) without a crash report.
stop_process(Pid) ->
    try proc_lib:stop(Pid, normal, 5000) of
        ok -> nil
    catch
        exit:_ -> nil
    end.
