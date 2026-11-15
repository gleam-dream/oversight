-module(moderation_desk_ffi).
-export([quiet/0, stop_supervisor/1, schedulers/0, machine/0, monotonic_us/0]).

%% Keep crash reports of killed processes out of the output; the tests
%% kill processes on purpose.
quiet() ->
    logger:set_primary_config(level, none),
    nil.

stop_supervisor(Pid) ->
    try proc_lib:stop(Pid, shutdown, infinity) of
        _ -> nil
    catch
        exit:_ -> nil
    end.

schedulers() ->
    erlang:system_info(schedulers_online).

machine() ->
    Arch = erlang:system_info(system_architecture),
    Otp = erlang:system_info(otp_release),
    Cores = erlang:system_info(logical_processors_available),
    Count = case Cores of unknown -> erlang:system_info(logical_processors); N -> N end,
    list_to_binary(io_lib:format("~s, OTP ~s, ~p logical processors, ~p schedulers online",
                                 [Arch, Otp, Count, erlang:system_info(schedulers_online)])).

monotonic_us() ->
    erlang:monotonic_time(microsecond).
