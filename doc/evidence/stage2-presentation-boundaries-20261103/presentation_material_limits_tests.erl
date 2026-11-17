-module(presentation_material_limits_tests).
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

large_plan_uses_pinned_material_policy_test() ->
    quod_material_admission_tests:with_session([], fun(Session) ->
        quod_material_admission_tests:first(Session, {assertz,{payload,binary:copy(<<8>>,1100*1024)}}),
        {ok, Plan}=quod_proof_session:seal(Session,quod_material_admission_tests:binding()),
        {ok, Blob}=quod_dtx:encode(Plan),
        ?assert(byte_size(Blob)>1024*1024),
        ?assertEqual({ok,Plan},quod_dtx:decode(Blob)),
        ?assertEqual({ok,Plan},quod_proof_session:seal(Session,quod_material_admission_tests:binding()))
    end).

large_plan_preserves_authored_finite_refusal_test() ->
    quod_material_admission_tests:with_session([{material_limit_override,plan,canonical_bytes,1000}], fun(Session) ->
        quod_material_admission_tests:first(Session,{assertz,{payload,binary:copy(<<8>>,1100*1024)}}),
        ?assertMatch({error,{material_limit,plan,canonical_bytes,_,1000}},
            quod_proof_session:seal(Session,quod_material_admission_tests:binding()))
    end).

large_signed_transaction_and_block_roundtrip_test() ->
    F=quod_ledger_artifact_tests:fixture(quod_ledger),
    {Ns,Anchor}=Binding=maps:get(binding,F),
    Base=maps:get(transaction,F),
    T0=Base#transaction{diff=[{assert,{{payload,binary:copy(<<7>>,1100*1024)},true}}],sig=none,signed_bytes=none},
    T1=quod_transaction:bind_id(Binding,T0),
    {ok,T}=quod_transaction:sign({Ns,Anchor,maps:get(admission,F)},T1,maps:get(signer,F)),
    ?assert(quod_transaction:verify({Ns,Anchor,maps:get(admission,F)},T)),
    {ok,Blob}=quod_transaction:encode_ledger_transaction(T),
    ?assert(byte_size(Blob)>1024*1024),
    {ok,B}=quod_ledger:new_block({maps:get(era,F),5},quod_ledger:block_ref(maps:get(parent,F)),4,{batch,[T]},103),
    ?assert(quod_ledger:valid_block_view(B)).

committee_shape_is_not_population_policy_test() ->
    Members=[<<N:256>> || N<-lists:seq(1,80)],
    ?assertEqual({ok,80},quod_quorum:committee_size(Members)),
    ?assertEqual(error,quod_quorum:committee_size([hd(Members)|Members])),
    ?assertEqual(error,quod_quorum:committee_size([<<1:248>>|Members])).

reservation_population_preserves_exact_tokens_test() ->
    Rows=[{make_ref(),quod_atomic_admission_tests:material()} || _<-lists:seq(1,520)],
    Q=lists:foldl(fun({Token,M},Acc)->
        {ok,Next}=quod_atomic_admission:reserve(self(),Token,M,#{},Acc),Next
    end,quod_atomic_admission:new(),Rows),
    ?assertEqual({0,520},quod_atomic_admission:counts(Q)),
    {Token,M}=lists:last(Rows),
    ?assertEqual({error,invalid_dtx_intent},quod_atomic_admission:reserve(self(),Token,M,#{},Q)),
    {M,Active}=quod_atomic_admission:activate(self(),Token,Q),
    ?assertEqual({1,519},quod_atomic_admission:counts(Active)).
