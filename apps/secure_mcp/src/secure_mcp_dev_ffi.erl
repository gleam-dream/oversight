%% Crypto and socket helpers for the app's scripted OpenID provider.
%%
%% Warden ships no public testing support (its scripted provider, server and
%% PKI live in warden/test and use erlang-jose plus an OpenSSL script), so this
%% app writes its own minimal provider on OTP's `public_key` and `ssl`.
-module(secure_mcp_dev_ffi).

-include_lib("public_key/include/public_key.hrl").

-export([generate_rsa/0, public_jwk/2, sign_rs256/2, generate_tls/1, free_port/0,
         now_seconds/0, unique/0, shutdown/1]).

%% An RSA-2048 signing key.
generate_rsa() ->
    public_key:generate_key({rsa, 2048, 65537}).

%% The public JWK JSON text for a key, with kid, use and alg.
public_jwk(#'RSAPrivateKey'{modulus = N, publicExponent = E}, Kid) ->
    iolist_to_binary(json:encode(#{
        <<"kty">> => <<"RSA">>,
        <<"kid">> => Kid,
        <<"use">> => <<"sig">>,
        <<"alg">> => <<"RS256">>,
        <<"n">> => b64url(binary:encode_unsigned(N)),
        <<"e">> => b64url(binary:encode_unsigned(E))
    })).

sign_rs256(Key, Message) ->
    public_key:sign(Message, sha256, Key).

b64url(Bin) -> base64:encode(Bin, #{mode => urlsafe, padding => false}).

%% A throwaway CA and a `localhost` server certificate. Writes cert.pem and
%% key.pem into Dir and returns the CA certificate as PEM text.
generate_tls(Dir) ->
    {ok, _} = application:ensure_all_started(ssl),
    San = #'Extension'{
        extnID = ?'id-ce-subjectAltName',
        critical = false,
        extnValue = [{dNSName, "localhost"}, {iPAddress, <<127, 0, 0, 1>>}]
    },
    Chain = #{
        root => [{key, {rsa, 2048, 65537}}],
        intermediates => [],
        peer => [{key, {rsa, 2048, 65537}}, {extensions, [San]}]
    },
    #{server_config := Server, client_config := Client} =
        public_key:pkix_test_data(#{server_chain => Chain, client_chain => Chain}),
    Cert = proplists:get_value(cert, Server),
    {KeyType, KeyDer} = proplists:get_value(key, Server),
    %% The CA that actually validates the server certificate.
    [Ca | _] = [C || C <- proplists:get_value(cacerts, Client),
                     element(1, public_key:pkix_path_validation(C, [Cert], [])) =:= ok],
    D = unicode:characters_to_list(Dir),
    ok = filelib:ensure_dir(filename:join(D, "x")),
    ok = file:write_file(filename:join(D, "cert.pem"),
                         public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
    ok = file:write_file(filename:join(D, "key.pem"),
                         public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    public_key:pem_encode([{'Certificate', Ca, not_encrypted}]).

%% A currently free loopback port. Warden needs the redirect URI (and so the
%% app's port) before the app's listener exists.
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

now_seconds() -> erlang:system_time(second).

unique() -> erlang:unique_integer([positive, monotonic]).

%% Stops a supervisor started (and linked) by the calling process with the
%% `shutdown` reason, so OTP logs no crash report.
shutdown(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _} -> nil after 5000 -> nil end.
