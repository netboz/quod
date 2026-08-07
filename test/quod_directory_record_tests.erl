-module(quod_directory_record_tests).

-include_lib("eunit/include/eunit.hrl").

-define(VERSION, 2).       %% current record/body version
-define(OLD_VERSION, 1).   %% superseded by the V3 ledger break

signed_record_roundtrip_and_tamper_rejection_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Endpoint = {<<"node.example">>, 4555},
    Hosted = [{<<"quod:agent">>, anchor(1), observer},
              {<<"quod:root">>, anchor(2), validator}],
    {ok, Encoded} = quod_directory_record:sign(
                      Pub, Endpoint, Hosted, 7, 11, Signer),
    {ok, Record} = quod_directory_record:decode(Encoded),
    ?assertEqual(Pub, quod_directory_record:node_key(Record)),
    ?assertEqual(Endpoint, quod_directory_record:endpoint(Record)),
    ?assertEqual(Hosted, quod_directory_record:hosted(Record)),
    ?assertEqual(7, quod_directory_record:epoch(Record)),
    ?assertEqual(11, quod_directory_record:sequence(Record)),
    Last = byte_size(Encoded) - 1,
    <<Prefix:Last/binary, Byte>> = Encoded,
    ?assertMatch(
       {error, _},
       quod_directory_record:decode(<<Prefix/binary, (Byte bxor 1)>>)).

wrong_author_signature_is_rejected_test() ->
    {Pub, _Seed} = quod_identity:generate(),
    {_OtherPub, OtherSeed} = Other = quod_identity:generate(),
    BodySigner = quod_identity:key_term(Other),
    %% The key embedded in the body differs from the signing key.
    Body = term_to_binary(
             {quod_directory_body, ?VERSION, Pub, <<"node">>, 4556,
              [{<<"quod:root">>, anchor(3), validator}], 1, 1},
             [deterministic]),
    Sig = quod_identity:sign(
            Body, BodySigner),
    Encoded = term_to_binary(
                {quod_directory_record, ?VERSION, Body, Sig}, [deterministic]),
    ?assertEqual(
       {error, bad_signature},
       quod_directory_record:decode(Encoded)),
    ?assertEqual(32, byte_size(OtherSeed)).

bounds_and_shape_fail_closed_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    AtLimit = [{<<N:16>>, anchor(N), validator}
               || N <- lists:seq(1, 32)],
    TooMany = [{<<N:16>>, anchor(N), validator}
               || N <- lists:seq(1, 33)],
    LongestName = binary:copy(<<"n">>, 255),
    TooLongName = binary:copy(<<"n">>, 256),
    ?assertMatch(
       {ok, _},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557}, AtLimit, 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557}, TooMany, 1, 1, Signer)),
    ?assertMatch(
       {ok, _},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{LongestName, anchor(40), observer}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{TooLongName, anchor(41), observer}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{<<"a">>, anchor(42), validator},
          {<<"a">>, anchor(43), observer}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{<<"b">>, anchor(44), validator},
          {<<"a">>, anchor(45), observer}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{<<"a">>, <<1, 2, 3>>, validator}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{<<"a">>, anchor(46), leader}], 1, 1, Signer)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:sign(
         Pub, {<<"node">>, 4557},
         [{<<"a">>, anchor(47), validator} | improper],
         1, 1, Signer)),
    ?assertEqual(
       {error, too_large},
       quod_directory_record:decode(<<0:(16 * 1024 + 1)/unit:8>>)),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:decode(term_to_binary(
                                      {quod_directory_record, ?VERSION, bad, bad}))),
    ?assertEqual(
       {error, bad_record},
       quod_directory_record:decode(
         term_to_binary({quod_directory_record, ?VERSION, <<>>, <<>>, []},
                        [compressed]))).

namespace_only_wire_format_is_rejected_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Body = term_to_binary(
             {quod_directory_body, ?VERSION, Pub, <<"old-node">>, 4558,
              [<<"quod:root">>], 1, 1},
             [deterministic]),
    Signature = quod_identity:sign(Body, Signer),
    Encoded = term_to_binary(
                {quod_directory_record, ?VERSION, Body, Signature},
                [deterministic]),
    ?assertEqual(
       {error, bad_record}, quod_directory_record:decode(Encoded)).

%% A record signed under the superseded version must not decode, even though it
%% is otherwise well-formed and correctly signed: the V3 ledger break rebinds
%% what a route attests.
superseded_version_is_rejected_test() ->
    {Pub, Seed} = quod_identity:generate(),
    Signer = quod_identity:key_term({Pub, Seed}),
    Body = term_to_binary(
             {quod_directory_body, ?OLD_VERSION, Pub, <<"node">>, 4559,
              [{<<"quod:root">>, anchor(4), validator}], 1, 1},
             [deterministic]),
    Signature = quod_identity:sign(Body, Signer),
    Encoded = term_to_binary(
                {quod_directory_record, ?OLD_VERSION, Body, Signature},
                [deterministic]),
    ?assertEqual(
       {error, bad_record}, quod_directory_record:decode(Encoded)).

anchor(N) -> <<N:256>>.
