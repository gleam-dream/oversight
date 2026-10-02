%% Disposable test PKI: a P-256 root and a `localhost` leaf it signed.
%% OTP rejects a self-signed peer even when it is listed in `cacerts`
%% (`selfsigned_peer`), and kryptos only builds self-signed certificates, so
%% the chain comes from OTP's own `public_key:pkix_test_data/1`.
-module(sso_portal_pki_ffi).
-export([generate/1]).
-include_lib("public_key/include/public_key.hrl").

generate(Dir) ->
    San = #'Extension'{extnID = ?'id-ce-subjectAltName', critical = false,
                       extnValue = [{dNSName, "localhost"}, {iPAddress, <<127, 0, 0, 1>>}]},
    Key = {key, {namedCurve, secp256r1}},
    Conf = public_key:pkix_test_data(#{
        root => [Key, {digest, sha256}],
        peer => [Key, {digest, sha256}, {extensions, [San]}]}),
    {cert, Cert} = lists:keyfind(cert, 1, Conf),
    {key, {'ECPrivateKey', KeyDer}} = lists:keyfind(key, 1, Conf),
    {cacerts, [Ca | _]} = lists:keyfind(cacerts, 1, Conf),
    CertFile = filename:join(Dir, "localhost.pem"),
    KeyFile = filename:join(Dir, "localhost.key"),
    ok = file:write_file(CertFile, public_key:pem_encode([{'Certificate', Cert, not_encrypted}])),
    ok = file:write_file(KeyFile, public_key:pem_encode([{'ECPrivateKey', KeyDer, not_encrypted}])),
    CaPem = public_key:pem_encode([{'Certificate', Ca, not_encrypted}]),
    {CaPem, Ca, CertFile, KeyFile}.
