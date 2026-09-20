-module(sinal_scope_ffi).

-export([
    with_scope/3,
    capture/1,
    reraise/1,
    exception_class/1,
    raise_error/0,
    raise_exit/0,
    raise_throw/0,
    raise_cleanup/0
]).

with_scope(Work, Cleanup, OnCleanupFailure) ->
    case capture_work(Work) of
        {returned, WorkResult} ->
            {scoped_completion, WorkResult, cleanup_result(Cleanup)};
        {raised, WorkException} ->
            cleanup_after_exception(Cleanup, OnCleanupFailure),
            reraise(WorkException)
    end.

capture_work(Work) ->
    try Work() of
        WorkResult -> {returned, WorkResult}
    catch
        Class:Reason:Stacktrace -> {raised, {Class, Reason, Stacktrace}}
    end.

cleanup_result(Cleanup) ->
    case attempt_cleanup(Cleanup) of
        {returned, {ok, nil}} -> {ok, nil};
        {returned, {error, DetachError}} ->
            {error, {detach_returned_error, DetachError}};
        {raised, Exception} -> {error, {detach_raised_exception, Exception}}
    end.

cleanup_after_exception(Cleanup, OnCleanupFailure) ->
    case attempt_cleanup(Cleanup) of
        {returned, {ok, nil}} -> ok;
        {returned, {error, DetachError}} ->
            safely_notify(OnCleanupFailure, {detach_returned_error, DetachError});
        {raised, Exception} ->
            safely_notify(OnCleanupFailure, {detach_raised_exception, Exception})
    end.

attempt_cleanup(Cleanup) ->
    try Cleanup() of
        Result -> {returned, Result}
    catch
        Class:Reason:Stacktrace -> {raised, {Class, Reason, Stacktrace}}
    end.

safely_notify(Callback, Failure) ->
    try Callback(Failure) of
        _ -> ok
    catch
        _Class:_Reason:_Stacktrace -> ok
    end.

capture(Work) ->
    try Work() of
        Result -> {ok, Result}
    catch
        Class:Reason:Stacktrace -> {error, {Class, Reason, Stacktrace}}
    end.

reraise({Class, Reason, Stacktrace}) -> erlang:raise(Class, Reason, Stacktrace).

exception_class({error, _Reason, _Stacktrace}) -> error_class;
exception_class({exit, _Reason, _Stacktrace}) -> exit_class;
exception_class({throw, _Reason, _Stacktrace}) -> throw_class.

raise_error() -> erlang:error(sinal_scope_error_marker).
raise_exit() -> exit(sinal_scope_exit_marker).
raise_throw() -> throw(sinal_scope_throw_marker).
raise_cleanup() -> erlang:error(sinal_scope_cleanup_marker).
