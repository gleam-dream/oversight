-module(instrument_replay_env).
-export([get/1]).
get(Name) -> unicode:characters_to_binary(os:getenv(binary_to_list(Name))).
