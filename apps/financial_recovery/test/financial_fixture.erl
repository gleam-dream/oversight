-module(financial_fixture).
-export([shutdown/1 , start_provider/2, visible/2, counts/1]).
shutdown(Pid) ->
    unlink(Pid), Ref = monitor(process, Pid), exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> nil after 10000 -> error(shutdown_timeout) end.

start_provider(Mode, Notices) ->
    Parent=self(), Ref=make_ref(),
    Pid=spawn_link(fun() ->
        Table=ets:new(provider,[public,set]),
        ets:insert(Table,[{mode,Mode},{visible,true},{submissions,0},{lookups,0}]),
        {ok,Listen}=gen_tcp:listen(0,[binary,{active,false},{packet,http_bin},{ip,{127,0,0,1}},{reuseaddr,true}]),
        {ok,{_,Port}}=inet:sockname(Listen),
        Owner=self(), spawn_link(fun()->accept(Listen,Table,Notices,Owner) end),
        Parent!{Ref,self(),Port}, control(Table)
    end),
    receive {Ref,Pid,Port} -> {Pid,Port} after 5000 -> error(provider_start_timeout) end.
visible(Pid,Value) -> call(Pid,{visible,Value}).
counts(Pid) -> call(Pid,counts).
call(Pid,Command) ->
    Ref=make_ref(), Pid!{self(),Ref,Command},
    receive {Ref,Answer}->Answer after 5000->error(provider_control_timeout) end.
control(Table) ->
    receive
        {From,Ref,{visible,Value}} -> ets:insert(Table,{visible,Value}), From!{Ref,nil};
        {From,Ref,counts} -> From!{Ref,{ets:lookup_element(Table,submissions,2),ets:lookup_element(Table,lookups,2)}}
    end, control(Table).
accept(Listen,Table,Notices,Owner) ->
    case gen_tcp:accept(Listen) of
        {ok,Socket}->
            Handler=spawn_link(fun()->link(Owner),receive {socket,S}->serve(S,Table,Notices) end end),
            ok=gen_tcp:controlling_process(Socket,Handler), Handler!{socket,Socket},accept(Listen,Table,Notices,Owner);
        {error,closed}->ok
    end.
serve(Socket,Table,Notices) ->
    {ok,{http_request,Method,{abs_path,Path},_}}=gen_tcp:recv(Socket,0,10000),
    Headers=headers(Socket,[]),
    Length=case proplists:get_value(<<"content-length">>,Headers) of undefined->0;L->binary_to_integer(L) end,
    ok=inet:setopts(Socket,[{packet,raw}]),
    case Length of 0->ok;_-> {ok,_}=gen_tcp:recv(Socket,Length,10000) end,
    case Method of
        'POST' ->
            Key=proplists:get_value(<<"idempotency-key">>,Headers),
            ets:update_counter(Table,submissions,1),
            ets:insert(Table,{{payment,Key},<<"provider-",Key/binary>>}),
            notify(Notices,Key),
            case ets:lookup_element(Table,mode,2) of
                0->reply(Socket,200,<<"provider-",Key/binary>>);
                1->receive release->reply(Socket,200,<<"provider-",Key/binary>>) after 30000->gen_tcp:close(Socket) end;
                2->gen_tcp:close(Socket)
            end;
        'GET' ->
            ets:update_counter(Table,lookups,1),
            Parsed = uri_string:parse(Path),
            case binary:split(maps:get(path, Parsed), <<"/">>, [global]) of
                [<<>>, <<"payments">>, EncodedKey] ->
                    Key = uri_string:percent_decode(EncodedKey),
                    case ets:lookup_element(Table,visible,2) of
                        false->reply(Socket,503,<<"lookup unavailable">>);
                        true->case ets:lookup(Table,{payment,Key}) of [{{payment,Key},Reference}]->reply(Socket,200,Reference);[]->reply(Socket,404,<<"absence not authoritative">>) end
                    end;
                _ -> reply(Socket,400,<<"expected one encoded operation segment">>)
            end
    end.
headers(Socket,Acc) ->
    case gen_tcp:recv(Socket,0,10000) of
        {ok,http_eoh}->Acc;
        {ok,{http_header,_,Name,_,Value}}->headers(Socket,[{lower_header(Name),Value}|Acc])
    end.
reply(Socket,Status,Body) ->
    ok=gen_tcp:send(Socket,[<<"HTTP/1.1 ">>,integer_to_binary(Status),<<" Fixture\r\nContent-Length: ">>,integer_to_binary(byte_size(Body)),<<"\r\nConnection: close\r\n\r\n">>,Body]),
    gen_tcp:close(Socket).
notify({subject,Pid,Ref},Value) -> Pid!{Ref,Value}.
lower_header(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
lower_header(Name) -> string:lowercase(Name).
