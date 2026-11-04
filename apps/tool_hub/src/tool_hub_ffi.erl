-module(tool_hub_ffi).
-export([stop_process/1, random_token/0, secure_equal/2]).

%% Stops an OTP process (a supervisor started unlinked) without a crash report.
stop_process(Pid) ->
    try proc_lib:stop(Pid, normal, 5000) of
        ok -> nil
    catch
        exit:_ -> nil
    end.

%% 32 random bytes, URL-safe base64 without padding.
random_token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).

%% Compares two binaries in time independent of where they differ.
secure_equal(Left, Right) ->
    crypto:hash_equals(crypto:hash(sha256, Left), crypto:hash(sha256, Right)).
