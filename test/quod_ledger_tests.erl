-module(quod_ledger_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%%%===================================================================
%%% classify/1 — the single enumeration of committed entry-data variants
%%%===================================================================

tx(I) ->
    #transaction{tx_id = integer_to_binary(I), origin = {<<"quod:root">>, <<0:256>>},
                 diff = [{assert, {{fact, I}, true}}], read_check = #{},
                 author = <<0:256>>, sig = none}.

%% The block and ledger use the same explicit content tag; payload/1 is a
%% deliberately content-only convenience for its existing callers.
content_classification_test() ->
    Txs = [tx(1), tx(2)],
    Data = {batch, Txs},
    ?assertEqual({batch, Txs}, Data),
    ?assertEqual({content, Txs}, quod_ledger:classify(Data)),
    ?assertEqual({ok, Txs}, quod_ledger:payload(Data)).

%% A complaint-certified skip carries nothing to fold and is NOT content — the
%% distinction every per-variant consumer dispatches on.
noop_is_its_own_kind_test() ->
    ?assertEqual(noop, quod_ledger:classify(noop)),
    ?assertEqual(error, quod_ledger:payload(noop)).

%% DTX controls use the same batch family as content.  The superseded top-level
%% singleton form is a hard format break, not a compatibility route.
canonical_control_batch_classification_and_old_format_break_test() ->
    Signer = signer(),
    Target = {<<"quod:ledger-controls">>, key(10)},
    {First, _FirstRef} = direct_abort(
                           Target, key(11), key(12), 1, Signer),
    {Second, _SecondRef} = direct_abort(
                             Target, key(13), key(14), 2, Signer),
    Data = {batch, [{dtx, First}, {dtx, Second}]},
    ?assertEqual(
       {controls, [{resolve, First}, {resolve, Second}]},
       quod_ledger:classify(Data)),
    ?assertEqual(error, quod_ledger:payload(Data)),
    ?assertEqual(invalid, quod_ledger:classify({dtx, First})).

control_batch_order_is_the_shared_signed_lane_order_test() ->
    Signer = signer(),
    %% The signing-journal sequence fixes ordering within one target/phase.
    %% Another target is never allowed in the same ontology's block.
    Target = {<<"quod:ledger-target">>, key(90)},
    {First, _} = direct_abort(
                   Target, key(91), key(92), 1, Signer),
    {Second, _} = direct_abort(
                    Target, key(11), key(12), 2, Signer),
    ?assertEqual(
       {controls, [{resolve, First}, {resolve, Second}]},
       quod_ledger:classify(
         {batch, [{dtx, First}, {dtx, Second}]})).

%% Wire/disk input enters the block decoder, never native classification.
%% Malformed, noncanonical and native-tuple injections fail at that boundary.
malformed_dtx_is_invalid_test() ->
    Signer = signer(),
    Target = {<<"quod:ledger-malformed">>, key(20)},
    {Control, _Ref} = direct_abort(Target, key(21), key(22), 1, Signer),
    {ok, Blob} = quod_atomic:encode_control(Control),
    Malformed = [{batch, [{dtx, not_a_binary}]},
                 {batch, [{dtx, <<>>}]},
                 {batch, [{dtx, <<"not etf">>}]},
                 {batch, [{dtx, <<Blob/binary, 0>>}]},
                 {batch, [{dtx, Control}]}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual({error, bad_block}, quod_ledger:decode_block(wire_block(Data)))
      end, Malformed).

native_control_roundtrip_preserves_wire_bytes_and_checks_ingress_test() ->
    F = quod_ct:signed_atomic_fixture(#{}), C = maps:get(vote_control, F),
    {ok, Blob} = quod_atomic:encode_control(C),
    Bytes = wire_block({batch, [{dtx, Blob}]}),
    {ok, Block} = quod_ledger:new_block(2, 1, {batch, [{dtx, C}]}, 2),
    ?assertEqual(Bytes, quod_ledger:block_bytes(Block)),
    ?assertEqual({ok, Block}, quod_ledger:decode_block(Bytes)),
    ?assertEqual(invalid, quod_ledger:classify({batch, [{dtx, Blob}]})),
    ?assertEqual({error, bad_block}, quod_ledger:new_block(2, 1, {batch, [{dtx, Blob}]}, 2)),
    %% An attacker can supply perfectly canonical bytes but cannot inject
    %% trusted native metadata or skip the own-plan signature check.
    Wire = binary_to_term(Blob, [safe]),
    Vote = binary_to_term(element(5, Wire), [safe]),
    Bundle = element(5, Vote),
    {ok, Plan} = quod_dtx:decode(element(3, Bundle)),
    {ok, BadPlan} = quod_dtx:encode(setelement(4, Plan, <<0:512>>)),
    BadVote = setelement(5, Vote, setelement(3, Bundle, BadPlan)),
    BadBlob = term_to_binary(setelement(5, Wire, term_to_binary(BadVote, [deterministic])), [deterministic]),
    ?assertEqual({error, bad_block}, quod_ledger:decode_block(wire_block({batch, [{dtx, BadBlob}]}))),
    ?assertEqual({error, bad_block}, quod_ledger:decode_block(wire_block({batch, [{dtx, C}]}))).

control_batches_reject_mixed_duplicate_unsorted_and_mixed_phase_test() ->
    Signer = signer(),
    Target = {<<"quod:ledger-order">>, key(30)},
    {First, _} = direct_abort(Target, key(31), key(32), 1, Signer),
    {Second, _} = direct_abort(Target, key(33), key(34), 2, Signer),
    Vote = direct_vote(Target, key(35), 3, Signer),
    {OtherTarget, _} = direct_abort({<<"quod:other-target">>, key(39)}, key(36), key(37), 3, Signer),
    {SameSequenceA, _} =
        direct_abort(Target, key(36), key(37), 7, Signer),
    {SameSequenceB, _} =
        direct_abort(Target, key(38), key(39), 7, Signer),
    SameSequence =
        lists:sort(
          fun(Left, Right) ->
              quod_atomic:control_order_key(Left) <
                  quod_atomic:control_order_key(Right)
          end, [SameSequenceA, SameSequenceB]),
    [SameSequenceFirst, SameSequenceSecond] = SameSequence,
    Invalid =
        [{batch, [{dtx, First}, {dtx, First}]},
         {batch, [{dtx, Second}, {dtx, First}]},
         {batch, [{dtx, First}, {dtx, Vote}]},
         {batch, [{dtx, First}, {dtx, OtherTarget}]},
         {batch, [{dtx, SameSequenceFirst}, {dtx, SameSequenceSecond}]},
         {batch, [{dtx, First}, tx(1)]}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual(invalid, quod_ledger:classify(Data)),
          ?assertEqual(error, quod_ledger:payload(Data))
      end, Invalid).

%% Untrusted input reaches classify through catch-up windows and replay, so a
%% malformed batch is a tolerated classification rather than a crash.
malformed_is_invalid_test() ->
    Malformed = [{batch, []},
                 {batch, [tx(1) | not_a_list]},
                 {batch, [tx(1), not_a_transaction]},
                 {batch, not_a_list},
                 {batch, tx(1)}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual(invalid, quod_ledger:classify(Data)),
          ?assertEqual(error, quod_ledger:payload(Data))
      end, Malformed).

%% The contract the later distributed-control-record work depends on: a variant
%% this release does not know is `invalid` — never silently folded as content or
%% mistaken for the inert skip. Adding it means extending classify/1 here, which
%% makes every consumer's exhaustive dispatch fail loudly until it decides what
%% the new kind means.
unknown_variant_is_invalid_test() ->
    Unknown = [{control, anything},
               {batch, [tx(1)], extra},
               undefined,
               <<"bytes">>,
               42,
               []],
    lists:foreach(
      fun(Data) ->
          Kind = quod_ledger:classify(Data),
          ?assertEqual(invalid, Kind),
          ?assertNotMatch({content, _}, Kind),
          ?assertNotEqual(noop, Kind)
      end, Unknown).

%% Structural references, not a consensus-admission witness.
direct_abort(Target, ManifestDigest, VoteDigest, Sequence, Signer) ->
    {ok, VoteRef} =
        quod_dtx:certified_ref(
          <<"quod:ledger-origin">>, key(40), 7, key(41), VoteDigest,
          <<"vote-qc">>),
    Record = quod_ct:atomic_abort_record(Target, ManifestDigest, VoteRef),
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} =
        quod_atomic:sign_control(
          Target, Material, key(42), Sequence, Sequence, Signer),
    {TargetNs, TargetAnchor} = Target,
    {ok, Ref} =
        quod_dtx:certified_ref(
          TargetNs, TargetAnchor, 10 + Sequence, key(50 + Sequence),
          quod_atomic:record_digest(Control), <<"resolve-qc">>),
    {Control, Ref}.

direct_vote(Target, ProofId, Sequence, Signer) ->
    F = quod_ct:signed_atomic_fixture(#{target => Target, proof_id => ProofId,
                                      node_identity => Signer}),
    Material = quod_atomic:control_material(maps:get(vote_control, F)),
    {ok, Control} =
        quod_atomic:sign_control(
          Target, Material, key(61), Sequence, Sequence, Signer),
    Control.

wire_block(Payload) ->
    term_to_binary({quod_block, 1, 2, 1, Payload, 2}, [deterministic]).

signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    #{pubkey => Pubkey,
      key => quod_identity:key_term({Pubkey, Seed})}.

key(N) -> <<N:256>>.
