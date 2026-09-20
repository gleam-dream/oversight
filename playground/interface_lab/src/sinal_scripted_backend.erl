-module(sinal_scripted_backend).

-export([get/2, put/2]).

get(Key, Default) ->
    case erlang:get(Key) of
        undefined -> Default;
        State -> State
    end.

put(Key, State) ->
    erlang:put(Key, State),
    nil.
