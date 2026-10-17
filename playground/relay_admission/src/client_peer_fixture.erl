-module(client_peer_fixture).
-export([start/2]).

%% A loopback HTTP peer exposes transport closure, independently of Relay's
%% endpoint implementation. It reads actual request bytes and uses the wire id.
start(Mode, Closed) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
        {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Pid = spawn(fun() ->
        receive {listener, Socket} -> serve(Socket, Mode, Closed) end
    end),
    ok = gen_tcp:controlling_process(Listener, Pid),
    Pid ! {listener, Listener},
    {Pid, Port}.

serve(Listener, Mode, Closed) ->
    try
        {ok, Socket} = gen_tcp:accept(Listener, 3000),
        try
            Request = read_request(Socket, <<>>),
            case Mode of
                <<"headers">> -> ok;
                _ ->
                    ok = gen_tcp:send(Socket,
                        <<"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
                          "Transfer-Encoding: chunked\r\n\r\n">>),
                    case Mode of
                        <<"ack">> -> ok;
                        _ ->
                            #{<<"id">> := Id} = json:decode(Request),
                            Ack = #{<<"jsonrpc">> => <<"2.0">>,
                                <<"method">> => <<"notifications/subscriptions/acknowledged">>,
                                <<"params">> => #{<<"_meta">> => #{
                                    <<"io.modelcontextprotocol/subscriptionId">> => Id},
                                    <<"notifications">> => #{<<"toolsListChanged">> => true}}},
                            send_event(Socket, json:encode(Ack)),
                            case Mode of
                                <<"malformed">> -> send_event(Socket, <<"{">>);
                                <<"eof">> -> gen_tcp:send(Socket, <<"0\r\n\r\n">>);
                                <<"oversize">> -> send_event(Socket, binary:copy(<<"x">>, 2048))
                            end
                    end
            end,
            Closed(gen_tcp:recv(Socket, 0, 3000) =:= {error, closed})
        after gen_tcp:close(Socket) end
    after gen_tcp:close(Listener) end.

read_request(Socket, Bytes) ->
    case binary:split(Bytes, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Lines = binary:split(string:lowercase(Head), <<"\r\n">>, [global]),
            [Length] = [binary_to_integer(string:trim(Value)) ||
                <<"content-length:", Value/binary>> <- Lines],
            read_body(Socket, Body, Length);
        [_] ->
            {ok, Chunk} = gen_tcp:recv(Socket, 0, 3000),
            read_request(Socket, <<Bytes/binary, Chunk/binary>>)
    end.

read_body(_Socket, Body, Length) when byte_size(Body) >= Length -> Body;
read_body(Socket, Body, Length) ->
    {ok, Chunk} = gen_tcp:recv(Socket, 0, 3000),
    read_body(Socket, <<Body/binary, Chunk/binary>>, Length).

send_event(Socket, Json) ->
    Event = iolist_to_binary(["data: ", Json, "\n\n"]),
    ok = gen_tcp:send(Socket,
        [integer_to_binary(byte_size(Event), 16), "\r\n", Event, "\r\n"]).
