-module(clinic_registration_ffi).
-export([exit_shutdown/0, stop_supervisor/1]).

%% End the calling process with reason `shutdown`, the reason a supervisor
%% expects from its parent.
exit_shutdown() ->
    exit(shutdown).

%% Stop a supervisor from any process and wait until it and its children
%% are gone. The reason is `normal`, so a process linked to the
%% supervisor, such as the one that started it, is not taken down.
stop_supervisor(Pid) ->
    try proc_lib:stop(Pid, normal, infinity) catch exit:noproc -> ok end,
    nil.
