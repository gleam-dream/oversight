-module(support_desk_lifecycle_test_ffi).
-export([linked_processes/0, ticket_handler_count/0]).

%% Inspect ownership links, never global process counts or private actor state.
linked_processes() ->
    {links, Links} = process_info(self(), links),
    [Pid || Pid <- Links, is_pid(Pid)].

%% Native telemetry's public registry exposes registrations even after an owner exits.
ticket_handler_count() ->
    length(telemetry:list_handlers([support_desk, ticket, opened])).
