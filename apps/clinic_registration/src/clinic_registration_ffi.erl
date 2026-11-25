-module(clinic_registration_ffi).
-export([exit_shutdown/0, free_port/0]).

%% End the calling process with reason `shutdown`, the reason a supervisor
%% expects from its parent.
exit_shutdown() ->
    exit(shutdown).

%% A loopback port that was free when it was asked for.
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
