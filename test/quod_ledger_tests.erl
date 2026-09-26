-module(quod_ledger_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

%% Codec boundaries only: certificates here have well-shaped fixture
%% signatures, not finality authority. The shared history verifier must still
%% check committee signatures, ancestry and contiguous material projection.
era_genesis_is_fixed_before_its_derived_domain_test() ->
    {Identity, Genesis, Era, _Tx} = era_fixture(),
    ?assertMatch(#block{era = genesis, slot = 0, parent = none}, Genesis),
    Entry = quod_ledger:entry(1, Genesis, none),
    ?assertEqual(1, quod_ledger:entry_index(Entry)),
    ?assertEqual(Era, quod_ledger:initial_era(Identity)),
    ?assertNotEqual(Era, quod_ledger:initial_era({<<"other">>, element(2, Identity)})),
    ?assertEqual({error, bad_block}, quod_ledger:new_block({genesis, 0}, none, empty, 0)),
    ?assertEqual({error, bad_block}, quod_ledger:new_block({Era, 0}, none, empty, 0)).

gapped_protocol_view_keeps_material_height_and_exact_bytes_test() ->
    {Identity, _Genesis, Era, Tx} = era_fixture(),
    {ok, Block} = quod_ledger:new_block(
                    {Era, 19}, {Era, 0, element(2, Identity)}, {batch, [Tx]}, 40),
    Entry = quod_ledger:entry(2, Block, era_codec_cert(Block)),
    {ok, Bytes} = quod_ledger:encode_entry(Entry),
    {ok, Decoded} = quod_ledger:decode_entry(Bytes, wrapped),
    ?assertEqual(2, quod_ledger:entry_index(Decoded)),
    {ok, Restored} = quod_ledger:block_from_entry(Decoded),
    ?assertEqual(19, Restored#block.slot),
    ?assertEqual(Block#block.block_bytes, Restored#block.block_bytes),
    {ok, Selected} = quod_ledger:select_entry(Bytes, {application, Tx#transaction.tx_id}, wrapped),
    ?assertMatch({ok, 2, _, _, 1},
                 quod_ledger:record_commitment(Selected, quod_ledger:selected_record(Selected))),
    {ok, Reimported} = quod_ledger:from_entry_view(quod_ledger:entry_view(Entry)),
    ?assertEqual({ok, Bytes}, quod_ledger:encode_entry(Reimported)).

empty_carrier_cannot_become_a_material_entry_test() ->
    {Identity, _Genesis, Era, Tx} = era_fixture(),
    Parent = {Era, 0, element(2, Identity)},
    {ok, Material} = quod_ledger:new_block({Era, 1}, Parent, {batch, [Tx]}, 1),
    {ok, Carrier} = quod_ledger:new_block({Era, 2}, quod_ledger:block_ref(Material), empty, 1),
    ?assertEqual(empty, quod_ledger:classify(empty)),
    ?assertEqual(invalid, quod_ledger:classify(noop)),
    ?assertException(error, {badmatch, false},
                     quod_ledger:entry(3, Carrier, era_codec_cert(Carrier))),
    %% A real empty-diff application still occupies a material position.
    ?assertEqual([], Tx#transaction.diff),
    ?assertEqual(2, quod_ledger:entry_index(
                      quod_ledger:entry(2, Material, era_codec_cert(Material)))).

ancestor_head_has_one_compact_descriptor_test() ->
    {Identity, _Genesis, Era, Tx} = era_fixture(),
    {ok, Material} = quod_ledger:new_block(
                      {Era, 2}, {Era, 0, element(2, Identity)}, {batch, [Tx]}, 1),
    {ok, Carrier} = quod_ledger:new_block({Era, 9}, quod_ledger:block_ref(Material), empty, 1),
    Head = era_codec_cert(Carrier),
    Entry = quod_ledger:entry(2, Material, Head),
    {ok, Bytes} = quod_ledger:encode_entry(Entry),
    {ok, Decoded} = quod_ledger:decode_entry(Bytes),
    ?assertEqual(Head, (quod_ledger:entry_view(Decoded))#entry.cert),
    ?assertEqual(nomatch, binary:match(Bytes, Carrier#block.block_bytes)),
    ?assertException(error, {badmatch, false},
                     quod_ledger:entry(2, Material, Head#cert{era = <<99:256>>})).

era_roots_do_not_depend_on_finality_witnesses_test() ->
    {Identity, Genesis, Era, Tx} = era_fixture(),
    {ok, Material} = quod_ledger:new_block(
                      {Era, 3}, {Era, 0, element(2, Identity)}, {batch, [Tx]}, 1),
    {Era, 3, Hash} = quod_ledger:block_ref(Material),
    Next = quod_ledger:next_era(Identity, Era, Hash),
    ?assertNotEqual(Era, Next),
    ?assertNotEqual(Next, quod_ledger:next_era(Identity, <<99:256>>, Hash)),
    ?assertNotEqual(Next, quod_ledger:next_era(Identity, Era, element(2, Identity))),
    {ok, Child} = quod_ledger:new_block({Next, 1}, {Next, 0, Hash}, {batch, [Tx]}, 2),
    ?assertEqual({Next, 0, Hash}, Child#block.parent),
    ?assertEqual({Era, 3, Hash}, quod_ledger:block_ref(Material)),
    ?assertEqual(genesis, Genesis#block.era).

legacy_and_malformed_protocol_positions_are_rejected_test() ->
    {Identity, _Genesis, Era, _Tx} = era_fixture(),
    Hash = element(2, Identity),
    lists:foreach(fun({Position, Parent}) ->
        ?assertEqual({error, bad_block}, quod_ledger:new_block(Position, Parent, empty, 1))
    end, [{1, 0}, {{Era, 1}, 0}, {{Era, 1}, {Era, 1, Hash}},
          {{Era, 1}, {<<99:256>>, 0, Hash}}, {{Era, -1}, {Era, 0, Hash}},
          {{Era, 1 bsl 64}, {Era, 0, Hash}}]),
    ?assertEqual({error, bad_block}, quod_ledger:decode_block(
                   term_to_binary({quod_block, 1, 1, 0, empty, 0}, [deterministic]))),
    ?assertEqual({error, bad_entry}, quod_ledger:decode_entry(
                   term_to_binary({quod_entry, 1, 1, none, none}, [deterministic]))).

era_fixture() ->
    #{identity := Identity, genesis := Genesis, era := Era, transaction := Tx} =
        quod_ct:protocol_fixture(<<"quod:era-codec">>),
    {Identity, Genesis, Era, Tx}.

era_codec_cert(Block) ->
    {Era, View, Hash} = quod_ledger:block_ref(Block),
    #cert{kind = commit, era = Era, slot = View, block_hash = Hash,
          sigs = [{<<1:256>>, <<1:512>>}]}.

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

%% Complaint certificates advance protocol views; the retired material skip
%% representation is invalid.
legacy_noop_is_invalid_test() ->
    ?assertEqual(invalid, quod_ledger:classify(noop)),
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
    {ok, Block} = quod_ledger:new_block({key(70), 2}, {key(70), 1, key(71)}, {batch, [{dtx, C}]}, 2),
    ?assertEqual(Bytes, quod_ledger:block_bytes(Block)),
    ?assertEqual({ok, Block}, quod_ledger:decode_block(Bytes)),
    ?assertEqual(invalid, quod_ledger:classify({batch, [{dtx, Blob}]})),
    ?assertEqual({error, bad_block}, quod_ledger:new_block({key(70), 2}, {key(70), 1, key(71)}, {batch, [{dtx, Blob}]}, 2)),
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
%% mistaken for an empty carrier. Adding it means extending classify/1 here, which
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
          ?assertNotEqual(empty, Kind)
      end, Unknown).

%% Structural references, not a consensus-admission witness.
direct_abort(Target, ManifestDigest, VoteDigest, Sequence, Signer) ->
    {ok, VoteRef} =
        quod_dtx:certified_ref(
          <<"quod:ledger-origin">>, key(40), 7, key(41), VoteDigest,
          fixture_head(key(41))),
    Record = quod_ct:atomic_abort_record(Target, ManifestDigest, VoteRef),
    {ok, Material} = quod_atomic:admission_material(Record),
    {ok, Control} =
        quod_atomic:sign_control(
          Target, Material, key(42), Sequence, Sequence, Signer),
    {TargetNs, TargetAnchor} = Target,
    {ok, Ref} =
        quod_dtx:certified_ref(
          TargetNs, TargetAnchor, 10 + Sequence, key(50 + Sequence),
          quod_atomic:record_digest(Control), fixture_head(key(50 + Sequence))),
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
    term_to_binary({quod_block, 2, key(70), 2, {key(70), 1, key(71)}, Payload, 2}, [deterministic]).

signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    #{pubkey => Pubkey,
      key => quod_identity:key_term({Pubkey, Seed})}.

key(N) -> <<N:256>>.

fixture_head(Hash) ->
    {ok, Bytes} = quod_ledger:encode_finality_head(#cert{kind = commit,
        era = key(70), slot = 20, block_hash = Hash, sigs = [{key(72), <<0:512>>}]}), Bytes.
