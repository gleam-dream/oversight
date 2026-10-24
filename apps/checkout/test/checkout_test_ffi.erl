-module(checkout_test_ffi).
-export([parent/1]).

%% The process that spawned Pid (OTP 25+). Used only to find the grind
%% attempt process that started a saga runner.
parent(Pid) ->
    case erlang:process_info(Pid, parent) of
        {parent, Parent} when is_pid(Parent) -> {ok, Parent};
        _ -> {error, nil}
    end.
