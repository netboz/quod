-module(quod_client_tls).
-moduledoc """
Browser-facing TLS material for the client endpoint.

A browser exposes Web Crypto (`crypto.subtle`) only in a **secure context**, so
on any non-loopback `http://` origin the client's entire key and signing flow is
unreachable — `SubtleCrypto` is simply absent. The client endpoint therefore has
to be served over TLS to function at all.

The node's own identity certificate (`m:quod_identity`) cannot be reused for
this: it carries an **Ed25519** key, and no major browser supports Ed25519 in
the certificate path. This module keeps one separate **P-256** keypair whose
only job is to terminate browser TLS.

The certificate is self-signed and authenticates nothing — a visitor accepts it
once per node, exactly as they would for any appliance on a private network. It
exists to unlock the secure-context APIs, not to establish trust: user
authentication rests on the Ed25519 challenge-response in `m:quod_client_auth`,
which is unaffected by who signed the transport certificate. An operator who
wants a real certificate points `client.certfile`/`client.keyfile` at one and
this module is never consulted.

Both halves live beside `node.key` in the identity directory and survive
restarts, so a visitor's accepted exception keeps working across deploys. The
certificate is re-minted automatically once it is inside its renewal window.
""".

-include_lib("public_key/include/public_key.hrl").

-export([ensure/1, mint/1]).

-define(KEYFILE, "client_tls.key").
-define(CERTFILE, "client_tls.crt").

%% Browsers reject a server certificate whose validity span is far longer than a
%% year, so this is deliberately short-lived and renewed in place rather than
%% minted once for a decade like the node's own identity cert.
-define(VALIDITY_DAYS, 397).
-define(RENEW_WITHIN_DAYS, 30).

-type material() :: #{cert := binary(), key := #'ECPrivateKey'{}}.
-export_type([material/0]).

-doc """
Load this node's browser-TLS keypair from `Dir`, minting and persisting one on
first boot and re-minting when the stored certificate is missing, unreadable, or
inside its renewal window.

The private key is written with the same audited atomic/0600 path as `node.key`
(`quod_identity:write_atomic/3`).
""".
-spec ensure(file:filename_all()) -> {ok, material()} | {error, term()}.
ensure(Dir) ->
    KeyPath = filename:join(Dir, ?KEYFILE),
    CertPath = filename:join(Dir, ?CERTFILE),
    case read_key(KeyPath) of
        {ok, Key} -> ensure_cert(CertPath, Key);
        none -> mint_and_store(KeyPath, CertPath, mint_key());
        {error, _} = Error -> Error
    end.

-doc "Mint a fresh self-signed P-256 certificate for `Key` (no disk access).".
-spec mint(#'ECPrivateKey'{}) -> binary().
mint(#'ECPrivateKey'{publicKey = Point} = Key) ->
    Name = {rdnSequence, [[#'AttributeTypeAndValue'{
              type = ?'id-at-commonName', value = {utf8String, <<"quod client">>}}]]},
    SPKI = #'OTPSubjectPublicKeyInfo'{
              algorithm = #'PublicKeyAlgorithm'{
                             algorithm = ?'id-ecPublicKey',
                             parameters = {namedCurve, ?'secp256r1'}},
              subjectPublicKey = #'ECPoint'{point = Point}},
    TBS = #'OTPTBSCertificate'{
             version = v3,
             serialNumber = serial(),
             signature = #'SignatureAlgorithm'{algorithm = ?'ecdsa-with-SHA256'},
             issuer = Name,
             validity = validity(),
             subject = Name,
             subjectPublicKeyInfo = SPKI,
             extensions = extensions()},
    public_key:pkix_sign(TBS, Key).

%% ======================================================================
%% internals
%% ======================================================================

ensure_cert(CertPath, Key) ->
    case read_cert(CertPath) of
        {ok, Cert} -> {ok, #{cert => Cert, key => Key}};
        renew -> store_cert(CertPath, Key);
        {error, _} = Error -> Error
    end.

mint_and_store(KeyPath, CertPath, Key) ->
    case quod_identity:write_atomic(
           KeyPath, public_key:der_encode('ECPrivateKey', Key), 8#600) of
        ok -> store_cert(CertPath, Key);
        {error, _} = Error -> Error
    end.

store_cert(CertPath, Key) ->
    Cert = mint(Key),
    case quod_identity:write_atomic(CertPath, Cert, 8#644) of
        ok -> {ok, #{cert => Cert, key => Key}};
        {error, _} = Error -> Error
    end.

mint_key() ->
    {Point, Private} = crypto:generate_key(ecdh, secp256r1),
    #'ECPrivateKey'{version = 1,
                    privateKey = Private,
                    parameters = {namedCurve, ?'secp256r1'},
                    publicKey = Point}.

read_key(Path) ->
    case file:read_file(Path) of
        {ok, Der} ->
            %% A damaged key is a hard error, not a silent re-mint: re-minting
            %% would invalidate every visitor's accepted exception without
            %% anyone noticing the file had been corrupted.
            try public_key:der_decode('ECPrivateKey', Der) of
                #'ECPrivateKey'{publicKey = P} = Key when is_binary(P) -> {ok, Key};
                _ -> {error, bad_client_tls_key}
            catch _:_ -> {error, bad_client_tls_key}
            end;
        {error, enoent} -> none;
        {error, _} = Error -> Error
    end.

%% An unreadable or near-expired certificate is simply re-minted from the key we
%% still hold — only the key is irreplaceable.
read_cert(Path) ->
    case file:read_file(Path) of
        {ok, Der} ->
            case fresh_enough(Der) of
                true -> {ok, Der};
                false -> renew
            end;
        %% A missing certificate is recoverable from the still-valid private
        %% key.  Other read failures may be transient (or indicate a broken
        %% volume); replacing material then would invalidate every browser's
        %% accepted certificate exception for no good reason.
        {error, enoent} -> renew;
        {error, _} = Error -> Error
    end.

fresh_enough(Der) ->
    try
        #'OTPCertificate'{
           tbsCertificate = #'OTPTBSCertificate'{
              validity = #'Validity'{notAfter = NotAfter}}} =
            public_key:pkix_decode_cert(Der, otp),
        seconds(NotAfter) - erlang:system_time(second) >
            ?RENEW_WITHIN_DAYS * 86400
    catch _:_ -> false
    end.

validity() ->
    Now = erlang:system_time(second),
    #'Validity'{
       %% Backdated so a node whose clock trails the visitor's by a few minutes
       %% does not present a not-yet-valid certificate.
       notBefore = utc(Now - 3600),
       notAfter = utc(Now + ?VALIDITY_DAYS * 86400)}.

extensions() ->
    [#'Extension'{extnID = ?'id-ce-basicConstraints',
                  critical = true,
                  extnValue = #'BasicConstraints'{cA = false}},
     #'Extension'{extnID = ?'id-ce-keyUsage',
                  critical = true,
                  extnValue = [digitalSignature, keyAgreement]},
     #'Extension'{extnID = ?'id-ce-extKeyUsage',
                  critical = false,
                  extnValue = [?'id-kp-serverAuth']},
     %% Modern browsers ignore the common name entirely, so the names the client
     %% is actually reached by must appear here. The node is reached through an
     %% orchestrator-mapped host port whose address it cannot know at boot, so
     %% this covers loopback plus any address the node advertises for itself;
     %% anything else still works behind the usual self-signed warning.
     #'Extension'{extnID = ?'id-ce-subjectAltName',
                  critical = false,
                  extnValue = subject_alt_names()}].

subject_alt_names() ->
    [{dNSName, "localhost"}, {iPAddress, [127, 0, 0, 1]}] ++ advertised_address().

advertised_address() ->
    case application:get_env(quod, node_addr) of
        {ok, {{A, B, C, D}, _Port}} -> [{iPAddress, [A, B, C, D]}];
        _ -> []
    end.

%% A serial must be positive and unpredictable; a fixed one would make two
%% re-mints indistinguishable to a client that cached the first.
serial() ->
    <<Serial:64/unsigned-big>> = crypto:strong_rand_bytes(8),
    Serial + 1.

%% X.509 uses two-digit years before 2050 (utcTime) and four after.
utc(Seconds) ->
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(Seconds, second),
    case Y < 2050 of
        true ->
            {utcTime, lists:flatten(
                        io_lib:format("~2..0w~2..0w~2..0w~2..0w~2..0w~2..0wZ",
                                      [Y rem 100, Mo, D, H, Mi, S]))};
        false ->
            {generalTime, lists:flatten(
                            io_lib:format("~4..0w~2..0w~2..0w~2..0w~2..0w~2..0wZ",
                                          [Y, Mo, D, H, Mi, S]))}
    end.

seconds({utcTime, Text}) ->
    [Y, Mo, D, H, Mi, S] = two_digit_fields(Text),
    Century = case Y < 50 of true -> 2000; false -> 1900 end,
    epoch({Century + Y, Mo, D}, {H, Mi, S});
seconds({generalTime, [A, B, C, E | Rest]}) ->
    [Mo, D, H, Mi, S] = two_digit_fields(Rest),
    epoch({list_to_integer([A, B, C, E]), Mo, D}, {H, Mi, S}).

two_digit_fields(Text) ->
    [list_to_integer([X, Y]) || [X, Y] <- pairs(strip_zone(Text))].

strip_zone(Text) -> lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Text).

pairs([A, B | Rest]) -> [[A, B] | pairs(Rest)];
pairs(_) -> [].

epoch(Date, Time) ->
    calendar:datetime_to_gregorian_seconds({Date, Time}) -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
