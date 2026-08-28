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
    {ok, FirstBlob} = quod_dtx:encode_control(First),
    {ok, SecondBlob} = quod_dtx:encode_control(Second),
    Data = {batch, [{dtx, FirstBlob}, {dtx, SecondBlob}]},
    ?assertEqual(
       {controls, [{finalize, First}, {finalize, Second}]},
       quod_ledger:classify(Data)),
    ?assertEqual(error, quod_ledger:payload(Data)),
    ?assertEqual(invalid, quod_ledger:classify({dtx, FirstBlob})).

control_batch_order_is_the_shared_signed_lane_order_test() ->
    Signer = signer(),
    %% Sequence 1 deliberately has the lexically later target and group. The
    %% valid order is the signing-journal lane order, not a second target/group
    %% order invented by the ledger.
    LaterTarget = {<<"quod:z-target">>, key(90)},
    EarlierTarget = {<<"quod:a-target">>, key(10)},
    {First, _} = direct_abort(
                   LaterTarget, key(91), key(92), 1, Signer),
    {Second, _} = direct_abort(
                    EarlierTarget, key(11), key(12), 2, Signer),
    {ok, FirstBlob} = quod_dtx:encode_control(First),
    {ok, SecondBlob} = quod_dtx:encode_control(Second),
    ?assertEqual(
       {controls, [{finalize, First}, {finalize, Second}]},
       quod_ledger:classify(
         {batch, [{dtx, FirstBlob}, {dtx, SecondBlob}]})).

%% DTX input is untrusted at catch-up/replay. Non-binary, malformed and
%% non-canonical blobs are invalid rather than exceptions or inert skips.
malformed_dtx_is_invalid_test() ->
    Signer = signer(),
    Target = {<<"quod:ledger-malformed">>, key(20)},
    {Control, _Ref} = direct_abort(Target, key(21), key(22), 1, Signer),
    {ok, Blob} = quod_dtx:encode_control(Control),
    Malformed = [{batch, [{dtx, not_a_binary}]},
                 {batch, [{dtx, <<>>}]},
                 {batch, [{dtx, <<"not etf">>}]},
                 {batch, [{dtx, <<Blob/binary, 0>>}]}],
    lists:foreach(
      fun(Data) ->
          ?assertEqual(invalid, quod_ledger:classify(Data)),
          ?assertEqual(error, quod_ledger:payload(Data))
      end, Malformed).

control_batches_reject_mixed_duplicate_unsorted_and_mixed_phase_test() ->
    Signer = signer(),
    Target = {<<"quod:ledger-order">>, key(30)},
    {First, _} = direct_abort(Target, key(31), key(32), 1, Signer),
    {Second, _} = direct_abort(Target, key(33), key(34), 2, Signer),
    Decision = direct_decision(Target, key(35), 3, Signer),
    {ok, FirstBlob} = quod_dtx:encode_control(First),
    {ok, SecondBlob} = quod_dtx:encode_control(Second),
    {ok, DecisionBlob} = quod_dtx:encode_control(Decision),
    {SameSequenceA, _} =
        direct_abort(Target, key(36), key(37), 7, Signer),
    {SameSequenceB, _} =
        direct_abort(Target, key(38), key(39), 7, Signer),
    SameSequence =
        lists:sort(
          fun(Left, Right) ->
              quod_dtx:control_order_key(Left) <
                  quod_dtx:control_order_key(Right)
          end, [SameSequenceA, SameSequenceB]),
    [SameSequenceFirst, SameSequenceSecond] = SameSequence,
    {ok, SameSequenceFirstBlob} =
        quod_dtx:encode_control(SameSequenceFirst),
    {ok, SameSequenceSecondBlob} =
        quod_dtx:encode_control(SameSequenceSecond),
    Invalid =
        [{batch, [{dtx, FirstBlob}, {dtx, FirstBlob}]},
         {batch, [{dtx, SecondBlob}, {dtx, FirstBlob}]},
         {batch, [{dtx, FirstBlob}, {dtx, DecisionBlob}]},
         {batch, [{dtx, SameSequenceFirstBlob},
                  {dtx, SameSequenceSecondBlob}]},
         {batch, [{dtx, FirstBlob}, tx(1)]}],
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

direct_abort(Target, GroupId, DecisionDigest, Sequence, Signer) ->
    {ok, DecisionRef} =
        quod_dtx:certified_ref(
          <<"quod:ledger-origin">>, key(40), 7, key(41), DecisionDigest,
          <<"decision-qc">>),
    {ok, Record} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, 0),
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Record, key(42), Sequence, Sequence, Signer),
    {TargetNs, TargetAnchor} = Target,
    {ok, Ref} =
        quod_dtx:certified_ref(
          TargetNs, TargetAnchor, 10 + Sequence, key(50 + Sequence),
          quod_dtx:record_digest(Control), <<"finalize-qc">>),
    {Control, Ref}.

direct_decision({TargetNs, TargetAnchor} = Target, GroupId, Sequence, Signer) ->
    {ok, BeginRef} =
        quod_dtx:certified_ref(
          TargetNs, TargetAnchor, 7, key(60), GroupId, <<"begin-qc">>),
    {ok, Record} =
        quod_dtx:new_decision(GroupId, BeginRef, {abort, [ledger_test]}, []),
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Record, key(61), Sequence, Sequence, Signer),
    Control.

signer() ->
    {Pubkey, Seed} = quod_identity:generate(),
    #{pubkey => Pubkey,
      key => quod_identity:key_term({Pubkey, Seed})}.

key(N) -> <<N:256>>.
