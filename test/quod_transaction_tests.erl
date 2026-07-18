-module(quod_transaction_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NS, <<"test:transactions">>).

identity() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

unsigned(Pub) ->
    #transaction{
       tx_id = <<"tx-1">>,
       caller_ns = ?NS,
       goal = {set, alpha, 1},
       result = #{<<"X">> => 1},
       diff = [{assert, {{value, alpha, 1}, true}}],
       read_check = #{{value, 3} => 42, {policy, 1} => 7},
       author = Pub,
       author_seq = 1,
       submitted_at = 1750000000000,
       sig = none}.

signed() ->
    {Pub, Identity} = identity(),
    Tx0 = unsigned(Pub),
    {ok, Tx} = quod_transaction:sign(?NS, Tx0, Identity),
    {Tx, Identity}.

sign_and_verify_test() ->
    {Tx, _Identity} = signed(),
    ?assertEqual(64, byte_size(Tx#transaction.sig)),
    ?assert(quod_transaction:verify(?NS, Tx)),
    ?assertEqual(quod_transaction:bytes(?NS, Tx#transaction{sig = none}),
                 quod_transaction:bytes(?NS, Tx)).

deterministic_read_check_order_test() ->
    {Pub, _Identity} = identity(),
    A = (unsigned(Pub))#transaction{
          read_check = maps:from_list([{{value, 3}, 42}, {{policy, 1}, 7}])},
    B = A#transaction{
          read_check = maps:from_list([{{policy, 1}, 7}, {{value, 3}, 42}])},
    ?assertEqual(quod_transaction:bytes(?NS, A),
                 quod_transaction:bytes(?NS, B)).

namespace_binding_test() ->
    {Tx, _Identity} = signed(),
    ?assert(quod_transaction:verify(?NS, Tx)),
    ?assertNot(quod_transaction:verify(<<"other:ontology">>, Tx)).

every_committed_field_is_bound_test() ->
    {Tx, _Identity} = signed(),
    Mutations = [
      Tx#transaction{tx_id = <<"tx-2">>},
      Tx#transaction{caller_ns = <<"other">>},
      Tx#transaction{goal = {set, alpha, 2}},
      Tx#transaction{result = #{<<"X">> => 2}},
      Tx#transaction{diff = [{assert, {{value, alpha, 2}, true}}]},
      Tx#transaction{read_check = #{{value, 3} => 43}},
      Tx#transaction{author = <<0:256>>},
      Tx#transaction{author_seq = 2},
      Tx#transaction{submitted_at = 1750000000001}
    ],
    [?assertNot(quod_transaction:verify(?NS, Mutated)) || Mutated <- Mutations].

malformed_and_wrong_author_test() ->
    {Pub, Identity} = identity(),
    {OtherPub, OtherIdentity} = identity(),
    Tx = unsigned(Pub),
    ?assertEqual({error, author_mismatch},
                 quod_transaction:sign(?NS, Tx, OtherIdentity)),
    {ok, Signed} = quod_transaction:sign(?NS, Tx, Identity),
    ?assertNot(quod_transaction:verify(?NS, Signed#transaction{sig = <<1, 2, 3>>})),
    ?assertNot(quod_transaction:verify(?NS, Signed#transaction{author = OtherPub})),
    ?assertEqual({error, already_signed},
                 quod_transaction:sign(?NS, Signed, Identity)).

history_genesis_exemption_test() ->
    {Pub, Identity} = identity(),
    Genesis = (unsigned(Pub))#transaction{
                tx_id = <<"genesis:test">>, diff = [], read_check = #{},
                author_seq = 0, sig = none},
    ?assert(quod_simplex:valid_history_entry(?NS, 1, {batch, [Genesis]}, [])),
    ?assertNot(quod_simplex:valid_history_entry(?NS, 2, {batch, [Genesis]}, [Pub])),
    {ok, Signed} = quod_transaction:sign(
                     ?NS, Genesis#transaction{author_seq = 1}, Identity),
    ?assert(quod_simplex:valid_history_entry(?NS, 2, {batch, [Signed]}, [Pub])),
    ?assertNot(quod_simplex:valid_history_entry(
                 <<"other">>, 2, {batch, [Signed]}, [Pub])).

relay_submission_roundtrip_test() ->
    {Tx, _Identity} = signed(),
    {ok, Submission} = quod_transaction:submission(?NS, Tx),
    ?assertEqual(16, byte_size(quod_transaction:submission_id(Submission))),
    ?assert(quod_transaction:verify_submission(Submission)),
    ?assertEqual({ok, Tx},
                 quod_transaction:decode_verified_submission(?NS, Submission)),
    ?assertMatch({error, namespace_or_author_mismatch},
                 quod_transaction:decode_verified_submission(
                   <<"other">>, Submission)).

relay_verifies_before_decode_test() ->
    {Tx, _Identity} = signed(),
    {ok, {submit, Author, Signature, Canonical}} =
        quod_transaction:submission(?NS, Tx),
    Tampered = {submit, Author, flip_first(Signature), Canonical},
    ?assertNot(quod_transaction:verify_submission(Tampered)),
    %% A valid signature over a non-canonical term is authenticated but still not
    %% a transaction in the versioned canonical format.
    {_OtherPub, OtherIdentity} = identity(),
    Opaque = term_to_binary({'not', a, transaction}, [deterministic]),
    OtherAuthor = maps:get(pubkey, OtherIdentity),
    OtherSig = quod_identity:sign(Opaque, OtherIdentity),
    AuthenticatedGarbage = {submit, OtherAuthor, OtherSig, Opaque},
    ?assert(quod_transaction:verify_submission(AuthenticatedGarbage)),
    ?assertMatch({error, malformed_submission},
                 quod_transaction:decode_verified_submission(
                   ?NS, AuthenticatedGarbage)).

flip_first(<<Byte, Rest/binary>>) -> <<(Byte bxor 1), Rest/binary>>.
