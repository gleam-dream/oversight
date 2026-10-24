-module(archive_release_test_ffi).
-export([database_url/0, finally/2, stop_process/1]).
database_url() ->
    case os:getenv("DATABASE_URL") of
        false -> erlang:error(run_with_disposable_postgres);
        Value -> unicode:characters_to_binary(Value)
    end.
finally(Cleanup, Work) ->
    try Work() after Cleanup() end.
stop_process(Pid) ->
    unlink(Pid),
    Monitor = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Monitor, process, Pid, _} -> nil
    after 5000 -> erlang:error(pool_cleanup_timeout)
    end.
