-module(extractor_ffi).
-export([stop_supervisor/1]).

%% Stop a supervisor from any process and wait until it and its children
%% are gone. The reason is `normal`, so a process linked to the
%% supervisor, such as the one that started it, is not taken down.
stop_supervisor(Pid) ->
    try proc_lib:stop(Pid, normal, infinity) catch exit:noproc -> ok end,
    nil.
