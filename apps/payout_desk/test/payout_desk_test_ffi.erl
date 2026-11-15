%% Test helpers that need the runtime directly.
-module(payout_desk_test_ffi).
-export([once/1]).

%% True the first time it is called with Key on this node.
once(Key) ->
    case persistent_term:get({payout_desk_once, Key}, false) of
        false ->
            persistent_term:put({payout_desk_once, Key}, true),
            true;
        true ->
            false
    end.
