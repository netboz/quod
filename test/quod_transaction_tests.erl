-module(quod_transaction_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NS, <<"test:transactions">>).
-define(GENESIS_TX_VERSION, 1).
-define(GENESIS_TX_TAG, "quod/genesis").

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
       read_check = #{{value, 3} => {present, 42}, {policy, 1} => {present, 7}},
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
          read_check = maps:from_list(
                         [{{value, 3}, {present, 42}}, {{policy, 1}, {present, 7}}])},
    B = A#transaction{
          read_check = maps:from_list(
                         [{{policy, 1}, {present, 7}}, {{value, 3}, {present, 42}}])},
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
      Tx#transaction{read_check = #{{value, 3} => {present, 43}}},
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
    Nonce = <<7:256>>,
    %% A valid genesis is assertion-only and asserts a {can_invoke,4} head:
    %% the rule gates every entry, so an ontology born without a policy could
    %% never be given one.
    Policy = {assert, {{can_invoke, {'G'}, {'P'}, {'C'}, {'N'}}, true}},
    Genesis = (unsigned(Pub))#transaction{
                tx_id = genesis_id(?NS, Nonce),
                goal = undefined, result = undefined,
                diff = [
                  {assert, {{consensus_incarnation, Nonce}, true}},
                  {assert, {{peer_admitted, Pub, undefined, undefined, Pub}, true}},
                  Policy
                ],
                read_check = #{},
                author_seq = 0, submitted_at = 0, sig = none},
    ?assert(quod_simplex:valid_history_entry(?NS, 1, {batch, [Genesis]}, [])),
    %% policy-less genesis is rejected at the founding/replay/catch-up seam
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert, {{consensus_incarnation, Nonce}, true}},
                            {assert, {{peer_admitted, Pub, undefined,
                                       undefined, Pub}, true}}]}]}, [])),
    %% assert-then-retract cannot smuggle a policy-less genesis past the
    %% assertion-only rule, even though the {can_invoke,4} head appears
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert, {{consensus_incarnation, Nonce}, true}},
                            {assert, {{peer_admitted, Pub, undefined,
                                       undefined, Pub}, true}},
                            Policy,
                            {retract, {{can_invoke, {'G'}, {'P'},
                                        {'C'}, {'N'}}, true}}]}]}, [])),
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{tx_id = <<"genesis:test">>}]}, [])),
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{tx_id = genesis_id(?NS, <<8:256>>)}]}, [])),
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{
                    diff = [{assert,
                             {{peer_admitted, Pub, undefined, undefined, Pub},
                              true}}]}]}, [])),
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{author_seq = 1}]}, [])),
    %% `#{}` in a head pattern matches any map: a non-empty read set on the
    %% founding transaction must still be refused explicitly
    ?assertNot(
       quod_simplex:valid_history_entry(
         ?NS, 1,
         {batch, [Genesis#transaction{
                    read_check = #{{x, 1} => {present, 7}}}]}, [])),
    ?assertNot(quod_simplex:valid_history_entry(?NS, 2, {batch, [Genesis]}, [Pub])),
    {ok, Signed} = quod_transaction:sign(
                     ?NS, (unsigned(Pub))#transaction{author_seq = 1}, Identity),
    ?assert(quod_simplex:valid_history_entry(?NS, 2, {batch, [Signed]}, [Pub])),
    ?assertNot(quod_simplex:valid_history_entry(
                 <<"other">>, 2, {batch, [Signed]}, [Pub])).

genesis_id(Ns, Nonce) ->
    <<?GENESIS_TX_TAG, 0, ?GENESIS_TX_VERSION:8,
      (byte_size(Ns)):32, Ns/binary, Nonce/binary>>.

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

relay_attempt_identity_test() ->
    {Tx, _Identity} = signed(),
    {ok, Submission} = quod_transaction:submission(?NS, Tx),
    SubmissionId = quod_transaction:submission_id(Submission),
    CommitteeId = <<6:256>>,
    Target = <<7:256>>,
    AttemptId =
        quod_transaction:relay_attempt_id(
          ?NS, SubmissionId, CommitteeId, 17, Target),
    ?assertEqual(16, byte_size(AttemptId)),
    ?assertEqual(
       AttemptId,
       quod_transaction:relay_attempt_id(
         ?NS, SubmissionId, CommitteeId, 17, Target)),
    ?assertEqual(
       16,
       byte_size(
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId,
           16#FFFFFFFFFFFFFFFF, Target))),
    Mutations =
        [quod_transaction:relay_attempt_id(
           <<"other:ontology">>, SubmissionId, CommitteeId, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, flip_first(SubmissionId), CommitteeId, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, <<9:256>>, 17, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId, 18, Target),
         quod_transaction:relay_attempt_id(
           ?NS, SubmissionId, CommitteeId, 17, <<8:256>>)],
    [?assertNotEqual(AttemptId, Mutated) || Mutated <- Mutations].

relay_attempt_identity_golden_vector_test() ->
    ?assertEqual(
       <<16#00, 16#0d, 16#3c, 16#41, 16#6f, 16#b2, 16#78, 16#63,
         16#7c, 16#96, 16#d7, 16#08, 16#79, 16#75, 16#fe, 16#e9>>,
       quod_transaction:relay_attempt_id(
         <<"relay:test">>, <<1:128>>, <<3:256>>, 17, <<2:256>>)).

relay_attempt_identity_rejects_malformed_test() ->
    Sid = <<1:128>>,
    CommitteeId = <<3:256>>,
    Target = <<2:256>>,
    BadInputs =
        [{not_binary, Sid, CommitteeId, 1, Target},
         {?NS, <<1:120>>, CommitteeId, 1, Target},
         {?NS, Sid, <<3:248>>, 1, Target},
         {?NS, Sid, not_binary, 1, Target},
         {?NS, Sid, CommitteeId, 0, Target},
         {?NS, Sid, CommitteeId, 16#10000000000000000, Target},
         {?NS, Sid, CommitteeId, <<"1">>, Target},
         {?NS, Sid, CommitteeId, 1, <<2:248>>},
         {?NS, Sid, CommitteeId, 1, not_binary}],
    [?assertEqual(
       error,
       quod_transaction:relay_attempt_id(
         Ns, SubmissionId, Committee, Slot, Peer))
     || {Ns, SubmissionId, Committee, Slot, Peer} <- BadInputs].

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
