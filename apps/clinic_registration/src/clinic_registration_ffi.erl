-module(clinic_registration_ffi).
-export([exit_shutdown/0]).

%% End the calling process with reason `shutdown`, the reason a supervisor
%% expects from its parent.
exit_shutdown() ->
    exit(shutdown).
