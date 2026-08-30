-module(quod_simplex_tests).
-moduledoc """
Pure-logic unit tests for `quod_simplex`'s DispersedSimplex consensus core — the parts that must be
correct independently of the network: quorum math, share signing, certificate formation + trustless
verification (incl. the Byzantine rejections), and the commit-vs-complaint guard. Uses real Ed25519
keypairs, so the crypto path is exercised end-to-end. Real multi-node QUIC behavior and restart recovery
are covered by `simplex_SUITE`.
""".
-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

%% Every ordinary consensus fixture belongs to one explicit chain domain. Tests
%% that exercise cross-namespace/genesis replay derive their foreign domains
%% separately and must never rely on an implicit/default signature context.
-define(DOMAIN, <<16#51:256>>).

%% a fresh validator identity {Pubkey, IdentityMap}
id() ->
    {Pub, Seed} = quod_identity:generate(),
    {Pub, #{pubkey => Pub, key => quod_identity:key_term({Pub, Seed})}}.

blk(Slot) -> #block{slot = Slot, parent = Slot - 1,
                    payload = {batch,
                               [tx([{assert, {{fact, Slot}, true}}])]}}.

%%%===================================================================
%%% quorum
%%%===================================================================

quorum_test() ->
    ?assertEqual(1, quod_simplex:quorum(1)),   %% sole validator
    ?assertEqual(3, quod_simplex:quorum(3)),   %% f=0
    ?assertEqual(3, quod_simplex:quorum(4)),   %% f=1
    ?assertEqual(5, quod_simplex:quorum(7)),   %% f=2
    ?assertEqual(7, quod_simplex:quorum(10)).  %% f=3

%%%===================================================================
%%% block hashing
%%%===================================================================

block_hash_deterministic_test() ->
    ?assertEqual(quod_simplex:block_hash(blk(5)), quod_simplex:block_hash(blk(5))),
    ?assertNotEqual(quod_simplex:block_hash(blk(5)), quod_simplex:block_hash(blk(6))).

%% The committee view is the membership set PLUS the exact committed block that adopted it. Boot replay
%% and catch-up both fold the same per-entry projector, and the live path feeds the same formula with the
%% engine-captured block hash. Content/noop slots do not invent revisions.
committee_view_projection_test() ->
    Ns = <<"committee:view">>,
    [A, B, C] = lists:sort(pubs(committee(3))),
    Genesis = #entry{index = 1,
                     data = {batch, [tx([pa(B), pa(A)])]}},
    Content = #entry{index = 2,
                     data = {batch,
                             [tx([{assert, {{content, kept}, true}}])]},
                     timestamp = 123},
    Skipped = #entry{index = 3, data = noop},
    AdmitC = #entry{index = 4,
                    data = {batch, [tx([pa(C)])]},
                    timestamp = 456},
    {ok, GenesisBlock} = quod_simplex:block_from_entry(Genesis),
    GenesisHash = quod_simplex:block_hash(GenesisBlock),
    ExpectedGenesisId =
        crypto:hash(
          sha256,
          term_to_binary(
            {quod_committee_view, 2, Ns, 1, GenesisHash,
             lists:sort([A, B])},
            [deterministic])),
    Seed = quod_simplex:history_projection(),
    Projection1 = quod_simplex:test_log_projection(Ns, [Genesis], Seed),
    ?assertEqual([A, B], quod_simplex:history_committee(Projection1)),
    GenesisId = maps:get(committee_id, Projection1),
    ?assertEqual(32, byte_size(GenesisId)),
    ?assertEqual(ExpectedGenesisId, GenesisId),
    ?assertEqual(
       GenesisId,
       quod_simplex:committee_view_id(Ns, 1, GenesisHash, [B, A])),

    %% Folding a window in one call and streaming it entry-by-entry are identical.
    AfterStable =
        quod_simplex:test_log_projection(
          Ns, [Content, Skipped], Projection1),
    ?assertEqual([A, B], quod_simplex:history_committee(AfterStable)),
    ?assertEqual(GenesisId, maps:get(committee_id, AfterStable)),
    ?assertEqual(123, maps:get(timestamp, AfterStable)),
    Full = quod_simplex:test_log_projection(
             Ns, [Genesis, Content, Skipped, AdmitC], Seed),
    Streamed = quod_simplex:test_log_projection(
                 Ns, [AdmitC], AfterStable),
    ?assertEqual(Full, Streamed),
    ?assertEqual([A, B, C], quod_simplex:history_committee(Full)),
    AdmitCId = maps:get(committee_id, Full),
    ?assertEqual(456, maps:get(timestamp, Full)),
    {ok, AdmitCBlock} = quod_simplex:block_from_entry(AdmitC),
    ?assertEqual(
       quod_simplex:committee_view_id(
       Ns, 4, quod_simplex:block_hash(AdmitCBlock), [A, B, C]),
       AdmitCId),
    ?assertNotEqual(GenesisId, AdmitCId),
    %% Exact-reference consumers select by slot, not by the projection's
    %% current head. Stable content and noop slots remain in the prior era.
    lists:foreach(
      fun(Slot) ->
          ?assertMatch(
             {ok, [A, B], GenesisId, _},
             quod_simplex:history_committee_view(Slot, Full))
      end,
      [1, 2, 3]),
    ?assertMatch(
       {ok, [A, B, C], AdmitCId, _},
       quod_simplex:history_committee_view(4, Full)),
    ?assertEqual(error, quod_simplex:history_committee_view(5, Full)).

committee_view_is_not_invented_before_membership_test() ->
    Ns = <<"committee:unfounded">>,
    Entry = #entry{index = 1,
                   data = {batch,
                           [tx([{assert, {{ordinary, fact}, true}}])]}},
    Projection = quod_simplex:test_log_projection(
                   Ns, [Entry], quod_simplex:history_projection()),
    ?assertEqual(undefined, maps:get(committee_id, Projection)),
    ?assertEqual([], maps:get(committee_views, Projection)),
    ?assertEqual(error, quod_simplex:history_committee_view(1, Projection)).

%% Returning to the same validator set after a leave/rejoin is a new view.
%% Reasserting a current member (for example to refresh its endpoint) retains
%% the current view and admission generation.
committee_view_recurring_set_revision_test() ->
    Ns = <<"committee:recurring">>,
    [A, B] = lists:sort(pubs(committee(2))),
    Entries =
        [#entry{index = 1,
                data = {batch, [tx([pa(A), pa(B)])]}},
         #entry{index = 2,
                data = {batch,
                        [(tx([{assert, {{b_wrote, true}, true}}]))#transaction{
                           author = B, author_seq = 9}]},
                timestamp = 9},
         #entry{index = 3,
                data = {batch, [tx([rm(B)])]},
                timestamp = 10},
         #entry{index = 4,
                data = {batch, [tx([pa(B)])]},
                timestamp = 11}],
    [Genesis, BWrite, Removed, Readded] = Entries,
    Projection1 =
        quod_simplex:test_log_projection(
          Ns, [Genesis], quod_simplex:history_projection()),
    ProjectionWritten =
        quod_simplex:test_log_projection(Ns, [BWrite], Projection1),
    ?assertEqual(9, maps:get(B, maps:get(sequences, ProjectionWritten))),
    Projection2 =
        quod_simplex:test_log_projection(Ns, [Removed], ProjectionWritten),
    Projection3 =
        quod_simplex:test_log_projection(Ns, [Readded], Projection2),
    Set1 = quod_simplex:history_committee(Projection1),
    Set2 = quod_simplex:history_committee(Projection2),
    Set3 = quod_simplex:history_committee(Projection3),
    Id1 = maps:get(committee_id, Projection1),
    Id2 = maps:get(committee_id, Projection2),
    Id3 = maps:get(committee_id, Projection3),
    ?assertEqual([A, B], Set1),
    ?assertEqual([A], Set2),
    ?assertEqual([A, B], Set3),
    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Id1, Id3),
    ?assertNotEqual(Id2, Id3),
    Admissions1 = maps:get(admissions, Projection1),
    Admissions2 = maps:get(admissions, Projection2),
    Admissions3 = maps:get(admissions, Projection3),
    ?assertEqual(maps:get(A, Admissions1), maps:get(A, Admissions2)),
    ?assertEqual(maps:get(A, Admissions1), maps:get(A, Admissions3)),
    ?assertNot(maps:is_key(B, Admissions2)),
    ?assertNotEqual(maps:get(B, Admissions1), maps:get(B, Admissions3)),
    ?assertNot(maps:is_key(B, maps:get(sequences, Projection2))),
    ?assertEqual(2, map_size(Admissions3)),
    Reassert = #entry{index = 5,
                      data = {batch, [tx([pa(B)])]},
                      timestamp = 12},
    Reasserted = quod_simplex:test_log_projection(
                   Ns, [Reassert], Projection3),
    ?assertEqual([A, B], quod_simplex:history_committee(Reasserted)),
    ?assertEqual(Id3, maps:get(committee_id, Reasserted)),
    ?assertEqual(
       maps:get(B, Admissions3),
       maps:get(B, maps:get(admissions, Reasserted))),
    ?assertNot(maps:is_key(B, maps:get(sequences, Reasserted))),
    ?assertEqual(12, maps:get(timestamp, Reasserted)).

canonical_ledger_payload_test() ->
    Transaction = tx([{assert, {{fact, canonical}, true}}]),
    Data = {batch, [Transaction]},
    ?assertEqual({ok, [Transaction]}, quod_ledger:payload(Data)),
    ?assertEqual(error, quod_ledger:payload(Transaction)),
    ?assertEqual(error, quod_ledger:payload(noop)),
    ?assertEqual(error, quod_simplex:block_from_entry(#entry{index = 1, data = Transaction})),
    Fixture = quod_ct:dtx_prepare_fixture(),
    {ok, ControlBlob} = quod_dtx:encode_control(
                          maps:get(prepare_control, Fixture)),
    ControlData = {batch, [{dtx, ControlBlob}]},
    ?assertEqual(
       {ok, #block{slot = 2, parent = 1, payload = ControlData,
                   timestamp = 42}},
       quod_simplex:block_from_entry(
         #entry{index = 2, data = ControlData, timestamp = 42})).

%%%===================================================================
%%% gap detector — ahead_cert_ceiling/1 (Slice 1)
%%%===================================================================

%% The ceiling is the max FINALIZER (commit|complaint) cert slot above `base`, seeded with `base`.
ahead_cert_ceiling_test() ->
    C = fun(Base, KS) -> quod_simplex:ahead_cert_ceiling(quod_simplex:eng_with_certs(Base, KS)) end,
    ?assertEqual(0, C(0, [])),                                        %% empty pool -> base (no lists:max([]) crash)
    ?assertEqual(0, C(0, [{support, 9}, {support, 42}])),             %% support certs excluded (only notarize)
    ?assertEqual(7, C(0, [{commit, 7}, {complaint, 5}, {support, 9}])), %% max over finalizers, ignoring support
    ?assertEqual(5, C(5, [{commit, 3}, {commit, 5}, {complaint, 4}])), %% certs <= base excluded -> base
    ?assertEqual(12, C(10, [{commit, 12}, {commit, 8}])).            %% only the above-base finalizer counts

%%%===================================================================
%%% Slice 4 — boot-mode / sync / participation gate truth table
%%%===================================================================

%% Only a sole validator starts ready. Every other facts shape has one unambiguous recovery state.
initial_sync_test() ->
    Init = fun(Vs) -> quod_simplex:initial_sync(st(#{self => <<"me">>, validators => Vs})) end,
    ?assertEqual(ready, Init([<<"me">>])),
    ?assertEqual(unconfirmed, Init([])),
    ?assertEqual(unconfirmed, Init([<<"me">>, <<"b">>])),
    ?assertEqual(unconfirmed, Init([<<"b">>])).

proof_gate_requires_exact_ready_ack_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = unique_gate_namespace(<<"ready">>),
    Anchor = <<0:256>>,
    Projection = quod_dtx:initial_projection({Ns, Anchor}, 7),
    with_simplex_gate(
      Ns, quod_ct:proof_gate_row(false, 7, []),
      fun(_Tab) ->
          Owner = registered_prolog_owner(Ns),
          try
              S0 = st(#{ns => Ns,
                        consensus_domain =>
                            quod_simplex:consensus_domain(Ns, Anchor),
                        dtx_projection => Projection,
                        slot => 0, last_applied => 0,
                        sync => ready, prolog_ready => false,
                        eng => quod_simplex:eng_with_certs(0, [])}),
              ?assertMatch(
                 {error, {ontology_rebuilding, Ns}},
                 quod_simplex:acquire_proof_access(Ns)),

              %% A forged owner PID and a stale height are both inert.
              WrongOwner = result_state(
                             quod_simplex:running(
                               cast, {prolog_ready, self(), 0, []}, S0)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(WrongOwner))),
              WrongHeight = result_state(
                              quod_simplex:running(
                                cast, {prolog_ready, Owner, 1, []}, S0)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(WrongHeight))),

              Ready = result_state(
                        quod_simplex:running(
                          cast, {prolog_ready, Owner, 0, []}, S0)),
              ?assertEqual(true,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(Ready))),
              ?assertEqual(
                 {ok, {quod_proof_access, Ns, 7}},
                 quod_simplex:acquire_proof_access(Ns)),

              %% Rebuild closes the row synchronously; a queued mark_ready
              %% cannot reopen it without the later owner acknowledgement.
              Rebuilding = result_state(
                             quod_simplex:running(cast, rebuild, Ready)),
              ?assertEqual(false,
                           maps:get(prolog_ready,
                                    quod_simplex:stats_map(Rebuilding))),
              ?assertMatch(
                 {error, {ontology_rebuilding, Ns}},
                 quod_simplex:acquire_proof_access(Ns))
          after
              stop_registered_owner(Owner)
          end
      end).

finalize_applied_opens_only_the_exact_pending_fence_test() ->
    Ns = unique_gate_namespace(<<"finalize">>),
    Anchor = <<0:256>>,
    GroupId = <<73:256>>,
    Slot = 4,
    Generation = 2,
    Open = quod_dtx:initial_projection({Ns, Anchor}, 0),
    Pending = Open#{apply_fences :=
                        #{GroupId =>
                            #{slot => Slot, generation => Generation,
                              blocking => true}},
                    generation := Generation},
    with_simplex_gate(
      Ns,
      quod_ct:proof_gate_row(
        true, Generation, [{GroupId, Slot, Generation}]),
      fun(_Tab) ->
          S0 = st(#{ns => Ns,
                    consensus_domain =>
                        quod_simplex:consensus_domain(Ns, Anchor),
                    dtx_projection => Pending,
                    prolog_ready => true, sync => ready,
                    eng => quod_simplex:eng_with_certs(0, [])}),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:acquire_proof_access(Ns)),

          Stale = result_state(
                    quod_simplex:running(
                      cast,
                      {finalize_applied, GroupId, Slot, Generation - 1},
                      S0)),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:acquire_proof_access(Ns)),
          Applied = result_state(
                      quod_simplex:running(
                        cast,
                        {finalize_applied, GroupId, Slot, Generation},
                        Stale)),
          ?assertEqual(
             {ok, {quod_proof_access, Ns, Generation}},
             quod_simplex:acquire_proof_access(Ns)),

          %% A duplicate is a no-op, while installing a committed closed
          %% projection republishes the protected row from the same seam used
          %% by live history and catch-up.
          Duplicate = result_state(
                        quod_simplex:running(
                          cast,
                          {finalize_applied, GroupId, Slot, Generation},
                          Applied)),
          ClosedHistory =
              (quod_simplex:history_projection({Ns, Anchor}))#{
                dtx := Pending},
          _Closed = quod_simplex:test_install_projection(
                      ClosedHistory, Duplicate),
          ?assertEqual(
             {error, {transaction_pending, GroupId}},
             quod_simplex:acquire_proof_access(Ns))
      end).

%% DTX payloads remain outside the consensus engine until the exact parent
%% history and Prepare policy (when applicable) have been validated. A commit
%% certificate by itself is only retained evidence: without the block it can
%% neither notarize nor commit the slot.
dtx_certificate_cannot_bypass_parent_validation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    {Author, AuthorId} = id(),
    Ns = unique_gate_namespace(<<"dtx-cert-only">>),
    Anchor = <<0:256>>,
    Target = {Ns, Anchor},
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    Admission = quod_simplex:test_author_admission(Author),
    GroupId = crypto:hash(sha256, <<"dtx-cert-only">>),
    {ok, DecisionRef} =
        quod_dtx:certified_ref(
          <<"origin">>, <<1:256>>, 1, <<2:256>>, <<3:256>>, <<"qc">>),
    {ok, Finalize} =
        quod_dtx:new_finalize(GroupId, DecisionRef, abort, none, 0),
    {ok, Control} =
        quod_dtx:sign_control(
          Target, Finalize, Admission, 1, 1, AuthorId),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Block = #block{slot = 2, parent = 1,
                   payload = {batch, [{dtx, ControlBlob}]}, timestamp = 0},
    BH = quod_simplex:block_hash(Block),
    Eng0 = quod_simplex:eng_new(Domain, [Author], 1),
    S0 = st(#{ns => Ns, self => Author, id => AuthorId,
              consensus_domain => Domain, validators => [Author],
              slot => 1, approved => 1, sync => ready, eng => Eng0,
              dtx_projection => quod_dtx:initial_projection(Target, 0)}),

    SupportShare =
        quod_simplex:make_share(Domain, support, 2, BH, AuthorId),
    CommitShare =
        quod_simplex:make_share(Domain, commit, 2, BH, AuthorId),
    {ok, SupportCert} =
        quod_simplex:form_cert(
          Domain, support, 2, BH, [SupportShare], [Author]),
    {ok, CommitCert} =
        quod_simplex:form_cert(
          Domain, commit, 2, BH, [CommitShare], [Author]),
    WithCerts =
        quod_simplex:dispatch(
          Author, {cert, CommitCert},
          quod_simplex:dispatch(Author, {cert, SupportCert}, S0)),

    %% No Prolog owner exists for this unique namespace, so validation cannot
    %% start. Even with both finality certificates already retained, the exact
    %% candidate stays outside the engine and the durable height cannot move.
    S1 = quod_simplex:dispatch(Author, {propose, Block, []}, WithCerts),
    ?assertEqual(
       {none, none, {BH, Block}, none, undefined},
       quod_simplex:test_dtx_round(2, S1)),
    ?assertEqual(1, maps:get(slot, quod_simplex:stats_map(S1))).

%% Both an origin-retained control and a relayed control consult this one
%% slot-first leader seam.  Reversing leader/2's arguments either crashes or
%% sends the two ingress paths away from the deterministic slot owner.
dtx_local_and_relayed_controls_share_slot_leader_test() ->
    [A, B, C] = Validators = lists:sort(pubs(committee(3))),
    LocalSlot = hd([Slot || Slot <- lists:seq(1, 32),
                            quod_simplex:leader(Slot, Validators) =:= B]),
    RelaySlot = hd([Slot || Slot <- lists:seq(1, 32),
                            quod_simplex:leader(Slot, Validators) =/= B]),
    S = st(#{self => B, validators => Validators}),
    ?assertEqual(local,
                 quod_simplex:test_dtx_slot_route(LocalSlot, S)),
    ExpectedPeer = quod_simplex:leader(RelaySlot, Validators),
    ?assertEqual({relay, ExpectedPeer},
                 quod_simplex:test_dtx_slot_route(RelaySlot, S)),
    ?assert(lists:member(ExpectedPeer, [A, C])).

%% A fully caught-up holder keeps serving historical recovery reads after its
%% validator admission is retired, but it can no longer accept a signed DTX
%% submission.  This is the liveness distinction needed after committee churn.
dtx_endpoint_reads_survive_validator_retirement_test() ->
    {Self, _SelfId} = id(),
    {Other, _OtherId} = id(),
    Ns = <<"quod:dtx-retired-holder">>,
    S = st(#{ns => Ns, self => Self, validators => [Other],
             sync => ready, prolog_ready => true, store => memory}),
    Ref = dtx_test_ref({Ns, <<0:256>>}, 2, <<21:256>>),
    GroupId = <<22:256>>,
    GroupRef = {group, Ns, <<0:256>>, Other, <<23:256>>, GroupId},
    ?assertNot(
       quod_simplex:test_dtx_endpoint_ready(
         {submit, <<1:128>>, quod_ct:dtx_prepare_blob()}, S)),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {phase, <<2:128>>, GroupId, finalize}, S)),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {outcome, <<3:128>>, GroupRef, <<24:256>>, 1}, S)),
    ?assert(
       quod_simplex:test_dtx_endpoint_ready(
         {applied, <<4:128>>, GroupId, Ref, 3, commit}, S)).

dtx_outcome_facade_preserves_only_authoritative_results_test() ->
    TxRef = {transaction, <<"quod:remote">>, <<51:256>>, <<52:256>>},
    GroupRef = {group, <<"quod:remote">>, <<51:256>>, <<53:256>>,
                <<54:256>>, <<55:256>>},
    Status = #{status => committed, height => 7, ref => TxRef},
    ?assertEqual(
       {ok, Status},
       quod_simplex:test_dtx_outcome_result(TxRef, {ok, Status})),
    ?assertEqual(
       {error, {outcome_unknown, TxRef}},
       quod_simplex:test_dtx_outcome_result(TxRef, {error, retry})),
    ?assertEqual(
       {error, {outcome_unknown, TxRef}},
       quod_simplex:test_dtx_outcome_result(TxRef, {error, not_found})),
    ?assertEqual(
       {error, not_found},
       quod_simplex:test_dtx_outcome_result(GroupRef, {error, not_found})).

owner_terminal_results_follow_the_retired_row_not_the_wrapper_test() ->
    RequestId = <<4:128>>,
    ?assertEqual(
       busy,
       quod_simplex:test_endpoint_terminal_result(
         {ok, {error, RequestId, busy}, []})),
    ?assertEqual(
       timeout,
       quod_simplex:test_dtx_worker_terminal_result(
         {submit_result, <<5:256>>, {error, timeout}},
         {error, RequestId, not_ready})),
    %% Metrics classification must never turn a real re-envelope failure into
    %% a Simplex crash while the original caller error is being returned.
    ?assertEqual(
       error,
       quod_simplex:test_dtx_retirement_result(unexpected_signing_failure)).

operation_recovery_owner_replies_once_and_retains_exact_result_test() ->
    TargetRef = {transaction, <<"quod:target">>, <<1:256>>, <<2:256>>},
    ?assertMatch(
       #{reply := {committed, TargetRef},
         stored := {committed, TargetRef},
         waiters := 0,
         duplicate := {true, _}},
       quod_simplex:test_operation_target_result(committed, TargetRef)),
    ?assertMatch(
       #{reply := {{rejected, not_authorized}, TargetRef},
         stored := {{rejected, not_authorized}, TargetRef},
         waiters := 0,
         duplicate := {true, _}},
       quod_simplex:test_operation_target_result(
         {rejected, not_authorized}, TargetRef)).

%% Response ownership is the exact authenticated peer plus the exact request;
%% a valid response on the right namespace from any other peer is inert.
dtx_endpoint_response_correlation_is_exact_and_released_test() ->
    Ns = <<"quod:dtx-correlation">>,
    {ExpectedPeer, _} = id(),
    {WrongPeer, _} = id(),
    RequestId = <<5:128>>,
    Request = {phase, RequestId, <<24:256>>, prepare},
    Response = {phase, RequestId, 7, pending},
    {ok, Frame} = quod_dtx_endpoint:encode_response(Ns, Response, []),
    From = {self(), make_ref()},
    S0 = quod_simplex:test_seed_dtx_correlation(
           Ns, ExpectedPeer, Request, From, st(#{ns => Ns})),
    SeededStats = quod_simplex:test_owner_stats(S0),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_current, SeededStats)),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_peak, SeededStats)),
    {Wrong, []} = quod_simplex:test_dtx_endpoint_frame(
                    Ns, serve, WrongPeer, self(), Frame, S0),
    ?assertEqual(1, maps:get(correlations,
                            quod_simplex:test_dtx_endpoint_counts(Wrong))),
    {Done, Actions} = quod_simplex:test_dtx_endpoint_frame(
                        Ns, serve, ExpectedPeer, self(), Frame, Wrong),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(0, maps:get(correlations,
                            quod_simplex:test_dtx_endpoint_counts(Done))),
    DoneStats = quod_simplex:test_owner_stats(Done),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 0, inbound := 0}},
       maps:get(owner_current, DoneStats)),
    ?assertMatch(
       #{dtx_endpoint := #{outbound := 1, inbound := 0}},
       maps:get(owner_peak, DoneStats)).

dtx_endpoint_accepted_response_carries_exact_committed_entry_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Record = maps:get(prepare, Fixture),
    Control = maps:get(prepare_control, Fixture),
    {ok, RecordBlob} = quod_dtx:encode_record(Record),
    Digest = quod_dtx:record_digest(Record),
    {Entry, _Payload, Ref} =
        certified_dtx_test_entry(Target, Control, 7),
    RequestId = <<177:128>>,
    Request = {submit, RequestId, RecordBlob},
    ?assertEqual(
       {{accepted, RequestId, Digest, Ref}, [{Ref, Entry}]},
       quod_simplex:test_dtx_endpoint_result_with_hints(
         Request, {submit_result, Digest, {ok, Ref, Entry}},
         st(#{ns => Ns, genesis_hash => Anchor}))).

%% Replies travel back on the request's bidirectional stream.  An outbound
%% pinned link publishes its peer as the bare TLS-pinned key, whereas an
%% inbound link publishes the authenticated `{Key, Endpoint}` header.  Both
%% transport identities must reach the same exact correlation check; malformed
%% identities must neither reply nor release someone else's request.
dtx_outbound_response_normalizes_transport_identity_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-response-owner">>,
    TargetNs = <<"quod:dtx-response-target">>,
    {ExpectedPeer, _} = id(),
    RequestId = <<6:128>>,
    Request = {phase, RequestId, <<25:256>>, prepare},
    Response = {phase, RequestId, 3, pending},
    {ok, Frame} = quod_dtx_endpoint:encode_response(TargetNs, Response, []),
    From = {self(), make_ref()},
    Seeded = quod_simplex:test_seed_dtx_correlation(
               TargetNs, ExpectedPeer, Request, From,
               st(#{ns => OwnerNs})),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_outbound_message(
         malformed_identity, self(), Channel, Frame, Seeded)),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_outbound_message(
         ExpectedPeer, self(), <<"unrelated-channel">>, Frame, Seeded)),
    ?assertEqual(
       #{correlations => 1, channels => 1},
       maps:with([correlations, channels],
                 quod_simplex:test_dtx_endpoint_counts(Seeded))),
    WrongLink = spawn(fun test_blocked_process/0),
    {handled, StillCorrelated, []} =
        quod_simplex:test_dtx_outbound_message(
          ExpectedPeer, WrongLink, Channel, Frame, Seeded),
    ?assertEqual(
       1, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(StillCorrelated))),
    WrongLink ! stop,
    {handled, Done, Actions} = quod_simplex:test_dtx_outbound_message(
                                 ExpectedPeer, self(), Channel, Frame, Seeded),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(
       #{correlations => 0, channels => 0},
       maps:with([correlations, channels],
                 quod_simplex:test_dtx_endpoint_counts(Done))),

    %% A same-namespace remote fallback uses the namespace's permanent DTX
    %% subscription rather than a dynamically retained target channel.
    SameNs = <<"quod:dtx-response-same-ns">>,
    SameChannel = quod_dtx_endpoint:channel(SameNs),
    SameId = <<7:128>>,
    SameRequest = {phase, SameId, <<26:256>>, decision},
    SameResponse = {phase, SameId, 0, not_found},
    {ok, SameFrame} = quod_dtx_endpoint:encode_response(
                        SameNs, SameResponse, []),
    SameFrom = {self(), make_ref()},
    SameSeeded = quod_simplex:test_seed_dtx_correlation(
                   SameNs, ExpectedPeer, SameRequest, SameFrom,
                   st(#{ns => SameNs, dtx_chan => SameChannel})),
    {handled, SameDone, SameActions} =
        quod_simplex:test_dtx_outbound_message(
          {ExpectedPeer, {"127.0.0.1", 15970}},
          self(), SameChannel, SameFrame, SameSeeded),
    ?assertEqual([{reply, SameFrom, {ok, SameResponse, []}}], SameActions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(SameDone))).

%% A request is inert until its exact pinned open authenticates. The callback
%% then queues the frame asynchronously on the ordered link FIFO; crossed open
%% results cannot send or take ownership of the correlation.
dtx_endpoint_request_sends_only_after_exact_pinned_link_up_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-link-owner">>,
    TargetNs = <<"quod:dtx-link-target">>,
    {Peer, _} = id(),
    RequestId = <<71:128>>,
    Request = {phase, RequestId, <<72:256>>, prepare},
    From = {self(), make_ref()},
    {OpenRef, Opening} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Request, From, st(#{ns => OwnerNs})),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         make_ref(), Peer, Channel, self(), Opening)),
    receive
        {send_ordered, Unexpected0} -> error({crossed_open_sent, Unexpected0})
    after 0 -> ok
    end,
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef, <<73:256>>, Channel, self(), Opening)),
    receive
        {send_ordered, Unexpected1} -> error({wrong_peer_sent, Unexpected1})
    after 0 -> ok
    end,
    {handled, Sent, []} =
        quod_simplex:test_dtx_correlation_link_up(
          OpenRef, Peer, Channel, self(), Opening),
    SentFrame = receive_ordered_frame(),
    {ok, Request, []} = quod_dtx_endpoint:decode_request(TargetNs, SentFrame),
    Response = {phase, RequestId, 9, pending},
    {ok, ResponseFrame} =
        quod_dtx_endpoint:encode_response(TargetNs, Response, []),
    {handled, Done, Actions} = quod_simplex:test_dtx_outbound_message(
                                 Peer, self(), Channel, ResponseFrame, Sent),
    ?assertEqual([{reply, From, {ok, Response, []}}], Actions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))),
    Parent = self(),
    Orphan = spawn(
               fun() ->
                       receive close -> Parent ! {orphan_closed, self()} end
               end),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef, Peer, Channel, Orphan, Done)),
    receive {orphan_closed, Orphan} ->
        error(simplex_closed_transport_owned_stale_link)
    after 0 -> ok
    end,
    Orphan ! close,
    receive {orphan_closed, Orphan} -> ok
    after 1000 -> error(orphan_cleanup_failed)
    end.

%% Once authenticated, the exact link monitor is the terminal loss edge. It
%% releases the caller immediately and never waits for or manufactures a retry
%% timer; a replacement request belongs to the higher-level route wake.
dtx_endpoint_exact_link_down_releases_only_its_correlation_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-link-down-owner">>,
    TargetNs = <<"quod:dtx-link-down-target">>,
    {Peer, _} = id(),
    Request = {phase, <<74:128>>, <<75:256>>, finalize},
    From = {self(), make_ref()},
    {OpenRef, Opening} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Request, From, st(#{ns => OwnerNs})),
    Parent = self(),
    Link = spawn(
             fun() ->
                     receive
                         {send_ordered, Frame} ->
                             Parent ! {dtx_link_sent, self(), Frame},
                             test_blocked_process()
                     end
             end),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    {handled, Sent, []} =
        quod_simplex:test_dtx_correlation_link_up(
          OpenRef, Peer, Channel, Link, Opening),
    receive {dtx_link_sent, Link, _Frame} -> ok
    after 1000 -> error(dtx_request_not_sent)
    end,
    exit(Link, kill),
    LinkMRef = receive
                   {'DOWN', Ref, process, Link, killed} -> Ref
               after 1000 -> error(dtx_link_down_not_monitored)
               end,
    {true, Done, Actions} =
        quod_simplex:test_drop_dtx_endpoint_owner(LinkMRef, Link, Sent),
    ?assertEqual([{reply, From, {error, connection_lost}}], Actions),
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))).

%% A timed-out request releases its exact endpoint/ref lease. A link_up already
%% queued for that old ref is inert in Simplex: it neither sends nor closes a
%% transport-owned link, and a different endpoint lease still progresses.
dtx_endpoint_timeout_then_late_link_up_preserves_other_lease_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    OwnerNs = <<"quod:dtx-lease-owner">>,
    TargetNs = <<"quod:dtx-lease-target">>,
    {Peer, _} = id(),
    Channel = quod_dtx_endpoint:channel(TargetNs),
    Endpoint1 = {"127.0.0.1", 15972},
    Endpoint2 = {"127.0.0.1", 15973},
    Request1 = {phase, <<76:128>>, <<77:256>>, prepare},
    Request2 = {phase, <<78:128>>, <<79:256>>, prepare},
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    {OpenRef1, Opening1} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Endpoint1, Request1, From1,
          st(#{ns => OwnerNs})),
    {OpenRef2, Opening2} =
        quod_simplex:test_seed_opening_dtx_correlation(
          TargetNs, Peer, Endpoint2, Request2, From2, Opening1),
    {OneLeft, [{reply, From1, {error, timeout}}]} =
        quod_simplex:test_timeout_dtx_correlation(<<76:128>>, Opening2),
    Parent = self(),
    Link1 = spawn(fun() -> test_link_probe(Parent) end),
    Link2 = spawn(fun() -> test_link_probe(Parent) end),
    ?assertEqual(
       ignore,
       quod_simplex:test_dtx_correlation_link_up(
         OpenRef1, Peer, Channel, Link1, OneLeft)),
    receive
        {dtx_link_sent, Link1, _} -> error(timed_out_request_was_sent);
        {dtx_link_closed, Link1} -> error(simplex_closed_stale_leased_link)
    after 0 -> ok
    end,
    {handled, Sent, []} = quod_simplex:test_dtx_correlation_link_up(
                            OpenRef2, Peer, Channel, Link2, OneLeft),
    receive {dtx_link_sent, Link2, _} -> ok
    after 1000 -> error(second_dtx_link_did_not_send)
    end,
    ?assertEqual(
       1, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(OneLeft))),
    Response2 = {phase, <<78:128>>, 11, pending},
    {ok, Frame2} = quod_dtx_endpoint:encode_response(
                     TargetNs, Response2, []),
    {handled, Done, [{reply, From2, {ok, Response2, []}}]} =
        quod_simplex:test_dtx_outbound_message(
          Peer, Link2, Channel, Frame2, Sent),
    receive {dtx_link_closed, Link2} ->
        error(simplex_closed_completed_leased_link)
    after 0 -> ok
    end,
    ?assertEqual(
       0, maps:get(correlations,
                   quod_simplex:test_dtx_endpoint_counts(Done))),
    Link1 ! stop,
    Link2 ! stop.

%% Every terminal owner edge releases the immutable endpoint/OpenRef lease.
%% Wrong correlation data is inert, and termination releases both refs even
%% when their eventual transport stream would have been shared.
dtx_endpoint_terminal_paths_release_exact_request_leases_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    with_transport_stub(
      fun() ->
          OwnerNs = <<"quod:dtx-release-owner">>,
          TargetNs = <<"quod:dtx-release-target">>,
          {Peer, _} = id(),
          Endpoint = {"127.0.0.1", 15974},
          Channel = quod_dtx_endpoint:channel(TargetNs),
          From = {self(), make_ref()},

          TimeoutRequest = {phase, <<80:128>>, <<81:256>>, prepare},
          {TimeoutRef, TimeoutOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, TimeoutRequest, From,
                st(#{ns => OwnerNs})),
          ?assertEqual(
             ignore,
             quod_simplex:test_dtx_correlation_link_error(
               make_ref(), Peer, Channel, TimeoutOpening)),
          ?assertEqual(
             ignore,
             quod_simplex:test_dtx_correlation_link_error(
               TimeoutRef, <<82:256>>, Channel, TimeoutOpening)),
          assert_no_transport_cast(),
          {_AfterTimeout, [{reply, From, {error, timeout}}]} =
              quod_simplex:test_timeout_dtx_correlation(
                <<80:128>>, TimeoutOpening),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, TimeoutRef),

          CallerRequest = {phase, <<83:128>>, <<84:256>>, decision},
          {CallerRef, CallerOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, CallerRequest, From,
                st(#{ns => OwnerNs})),
          {true, _AfterCallerDown, []} =
              quod_simplex:test_drop_dtx_correlation_caller(
                <<83:128>>, CallerOpening),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, CallerRef),

          ResponseRequest = {phase, <<85:128>>, <<86:256>>, finalize},
          {ResponseRef, ResponseOpening} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, ResponseRequest, From,
                st(#{ns => OwnerNs})),
          Parent = self(),
          ResponseLink = spawn(fun() -> test_link_probe(Parent) end),
          {handled, ResponseSent, []} =
              quod_simplex:test_dtx_correlation_link_up(
                ResponseRef, Peer, Channel, ResponseLink,
                ResponseOpening),
          receive {dtx_link_sent, ResponseLink, _} -> ok
          after 1000 -> error(response_request_not_sent)
          end,
          Response = {phase, <<85:128>>, 12, pending},
          {ok, ResponseFrame} = quod_dtx_endpoint:encode_response(
                                  TargetNs, Response, []),
          {handled, _ResponseDone,
           [{reply, From, {ok, Response, []}}]} =
              quod_simplex:test_dtx_outbound_message(
                Peer, ResponseLink, Channel, ResponseFrame, ResponseSent),
          receive_exact_lease_release(
            Peer, Endpoint, Channel, ResponseRef),
          ResponseLink ! stop,

          Request1 = {phase, <<87:128>>, <<88:256>>, prepare},
          Request2 = {phase, <<89:128>>, <<90:256>>, prepare},
          {Ref1, Opening1} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, Request1,
                {self(), make_ref()}, st(#{ns => OwnerNs})),
          {Ref2, Opening2} =
              quod_simplex:test_seed_opening_dtx_correlation(
                TargetNs, Peer, Endpoint, Request2,
                {self(), make_ref()}, Opening1),
          ok = quod_simplex:test_close_dtx_endpoint(Opening2),
          Releases =
              [receive_any_lease_release(), receive_any_lease_release()],
          ?assertEqual(
             lists:sort([{Peer, Endpoint, Channel, Ref1},
                         {Peer, Endpoint, Channel, Ref2}]),
             lists:sort(Releases)),
          receive {_Tag1, {error, not_ready}} -> ok
          after 1000 -> error(first_terminate_reply_missing)
          end,
          receive {_Tag2, {error, not_ready}} -> ok
          after 1000 -> error(second_terminate_reply_missing)
          end
      end).

%% Repeated authenticated requests remain on the one readiness path; no hidden
%% rate counter changes their result or allocates a worker.
dtx_endpoint_requests_have_no_rate_gate_test() ->
    Ns = <<"quod:dtx-rate">>,
    {Peer, _} = id(),
    PeerIdentity = {Peer, {"127.0.0.1", 15971}},
    S0 = st(#{ns => Ns}),
    {S1, Replies} =
        lists:foldl(
          fun(N, {SAcc, Acc}) ->
                  Request = {phase, <<N:128>>, <<25:256>>, prepare},
                  {ok, Frame} = quod_dtx_endpoint:encode_request(
                                  Ns, Request, []),
                  {SNext, []} = quod_simplex:test_dtx_endpoint_frame(
                                  Ns, serve, PeerIdentity, self(), Frame, SAcc),
                  Reply = receive
                              {send_ordered, ReplyFrame} ->
                                  {ok, Decoded, []} =
                                      quod_dtx_endpoint:decode_response(
                                        Ns, ReplyFrame),
                                  Decoded
                          after 1000 ->
                              error(missing_dtx_endpoint_reply)
                          end,
                  {SNext, [Reply | Acc]}
          end, {S0, []}, lists:seq(1, 33)),
    [Last | Earlier] = Replies,
    ?assertMatch({error, <<33:128>>, not_ready}, Last),
    ?assert(lists:all(
              fun({error, _Id, not_ready}) -> true;
                 (_) -> false
              end, Earlier)),
    Counts = quod_simplex:test_dtx_endpoint_counts(S1),
    ?assertEqual(0, maps:get(workers, Counts)).

%% A deterministic Prepare refusal is returned byte-for-byte and closes the
%% worker.  It neither leaves an outbound correlation nor retains the rejected
%% semantic submission.
dtx_endpoint_prepare_refusal_replies_and_cleans_test() ->
    PrepareBlob = quod_ct:dtx_prepare_blob(),
    {ok, Prepare} = quod_dtx:decode_record(PrepareBlob),
    {ok, _Manifest, _PlanDigest, PlanBlob} =
        quod_dtx:prepare_payload(Prepare),
    {ok, Plan} = quod_dtx:decode(PlanBlob),
    Target = {Ns, Anchor} = quod_dtx:target(Plan),
    Digest = quod_dtx:record_digest(Prepare),
    RequestId = <<34:128>>,
    Request = {submit, RequestId, PrepareBlob},
    {ok, ReasonsBlob} = quod_wire_term:encode_failure_reasons(
                          [{prepare_refused,
                            {ontology, Ns, Anchor}},
                           {goal, {cannot_link, bob, tom}}]),
    Generation = 9,
    Worker = spawn(fun validation_owner/0),
    From = {self(), make_ref()},
    try
        {_Monitor, Seeded} = quod_simplex:test_seed_dtx_worker(
                               Worker, local, Request, {caller, From},
                               st(#{ns => Ns, genesis_hash => Anchor})),
        SeededStats = quod_simplex:test_owner_stats(Seeded),
        ?assertMatch(
           #{dtx_endpoint := #{outbound := 0, inbound := 1}},
           maps:get(owner_current, SeededStats)),
        ?assertMatch(
           #{dtx_endpoint := #{outbound := 0, inbound := 1}},
           maps:get(owner_peak, SeededStats)),
        Result =
            {submit_result, Digest,
             {error,
              {prepare_refused, Target, Digest, Generation, ReasonsBlob}}},
        {Done, Actions} = quod_simplex:test_finish_dtx_worker(
                            Worker, Result, Seeded),
        Expected =
            {refused, RequestId, Target, Digest, Generation, ReasonsBlob},
        ?assertEqual([{reply, From, {ok, Expected, []}}], Actions),
        ?assertEqual(
           #{correlations => 0, channels => 0, workers => 0,
             submissions => 0},
           quod_simplex:test_dtx_endpoint_counts(Done)),
        DoneStats = quod_simplex:test_owner_stats(Done),
        ?assertMatch(
           #{dtx_endpoint := #{outbound := 0, inbound := 0}},
           maps:get(owner_current, DoneStats)),
        ?assertMatch(
           #{dtx_endpoint := #{outbound := 0, inbound := 1}},
           maps:get(owner_peak, DoneStats))
    after
        Worker ! stop
    end.

%% Duplicate endpoint requests share one signed envelope while retaining their
%% distinct monitored workers. One certified commit releases both exactly once.
dtx_submission_shares_one_envelope_between_waiters_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Control = maps:get(prepare_control, Fixture),
    Record = maps:get(prepare, Fixture),
    Parent = self(),
    First = spawn(fun() -> dtx_waiter_probe(Parent, first) end),
    Second = spawn(fun() -> dtx_waiter_probe(Parent, second) end),
    S0 = quod_simplex:test_seed_dtx_submission(
           Control, [{dtx_endpoint, First}], st(#{})),
    try
        ?assertEqual(1, quod_simplex:test_dtx_submission_waiters(S0)),
        {ok, Shared} = quod_simplex:test_retain_dtx_record(
                         Record, {dtx_endpoint, Second}, S0),
        ?assertEqual(2, quod_simplex:test_dtx_submission_waiters(Shared)),
        {Entry, Payload} = committed_dtx_test_entry(Control, 1),
        Done = quod_simplex:test_resolve_committed_dtx(
                 Entry, Payload, Shared),
        receive {dtx_waiter_probe, first, {ok, _, #entry{}}} -> ok after 1000 ->
            error(missing_first_dtx_waiter_reply)
        end,
        receive {dtx_waiter_probe, second, {ok, _, #entry{}}} -> ok after 1000 ->
            error(missing_second_dtx_waiter_reply)
        end,
        ?assertEqual(0, quod_simplex:test_dtx_submission_waiters(Done))
    after
        exit(First, kill),
        exit(Second, kill)
    end.

dtx_waiter_probe(Parent, Label) ->
    receive
        {dtx_submit_result, Reply} ->
            Parent ! {dtx_waiter_probe, Label, Reply}
    end.

%% One FIFO admits every distinct ready group without a compiled population
%% cap. Activation moves only the selected groups into durable signing custody.
dtx_admission_has_no_dormant_population_cap_and_activates_exact_groups_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Author} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Rows = dtx_admission_variants(Fixture, 65),
    Deadline = quod_time:mono_ms() + 5000,
    Dir = relay_store_dir("dtx_admission_fifo"),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        {ok, Journal0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Author, id => Identity,
                  validators => [Author],
                  author_admissions => #{Author => Admission},
                  sync => ready, signing_journal => Journal0}),
        {Queued, Intents} = lists:foldl(
                              fun({Begin, GroupRef}, {S, Acc}) ->
                                      Intent = make_ref(),
                                      From = {self(), make_ref()},
                                      {ok, S1} =
                                          quod_simplex:test_enqueue_dtx_intent(
                                            From, self(), Intent, Begin,
                                            GroupRef, Deadline, S),
                                      {S1, [{From, Intent} | Acc]}
                              end, {S0, []}, Rows),
        {Dormant, Replies} = quod_simplex:test_progress_dtx_admission(Queued),
        ExpectedReplies =
            [{reply, From, {accepted, Intent}}
             || {From, Intent} <- lists:reverse(Intents)],
        ?assertEqual(ExpectedReplies, Replies),
        DormantState = maps:get(
                         dormant,
                         quod_simplex:test_dtx_admission_state(Dormant)),
        ?assertEqual(65, map_size(DormantState)),
        ?assertEqual([], maps:get(
                           waiting,
                           quod_simplex:test_dtx_admission_state(Dormant))),
        [{FirstBegin, _}, {SecondBegin, _} | _] = Rows,
        FirstGroup = quod_dtx:group_id(FirstBegin),
        SecondGroup = quod_dtx:group_id(SecondBegin),
        FirstIntent = maps:get(FirstGroup, DormantState),
        SecondIntent = maps:get(SecondGroup, DormantState),
        Activated1 = quod_simplex:test_activate_dtx_intent(
                       self(), FirstIntent, Dormant),
        Activated2 = quod_simplex:test_activate_dtx_intent(
                       self(), SecondIntent, Activated1),
        RemainingDormant = maps:get(
                             dormant,
                             quod_simplex:test_dtx_admission_state(Activated2)),
        ?assertEqual(63, map_size(RemainingDormant)),
        ?assertNot(maps:is_key(FirstGroup, RemainingDormant)),
        ?assertNot(maps:is_key(SecondGroup, RemainingDormant)),
        ?assertEqual(
           2,
           maps:get(submissions,
                    quod_simplex:test_dtx_endpoint_counts(
                      Activated2))),
        ?assertEqual(
           lists:sort([FirstGroup, SecondGroup]),
           lists:sort(maps:keys(
                        quod_signing_journal:pending_begins(
                          quod_simplex:test_signing_journal(Activated2))))),
        receive {'$gen_cast', {project_pending_begins, [_]}} -> ok
        after 1000 -> error(missing_first_pending_begins_projection)
        end,
        receive {'$gen_cast', {project_pending_begins, [_, _]}} -> ok
        after 1000 -> error(missing_second_pending_begins_projection)
        end,
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Activated2))
    after
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        _ = file:del_dir_r(Dir)
    end.

dtx_admission_cancellation_removes_only_the_exact_fifo_entry_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, _Begin, _GroupRef, S0) ->
          [{Begin1, GroupRef1}, {Begin2, GroupRef2},
           {Begin3, GroupRef3}, {Begin4, GroupRef4}] =
              dtx_admission_variants(Fixture, 4),
          [Intent1, Intent2, Intent3, Intent4] =
              [make_ref() || _ <- lists:seq(1, 4)],
          [From1, From2, From3, From4] =
              [{self(), make_ref()} || _ <- lists:seq(1, 4)],
          Deadline = quod_time:mono_ms() + 5000,
          {ok, Q1} = quod_simplex:test_enqueue_dtx_intent(
                       From1, self(), Intent1, Begin1, GroupRef1,
                       Deadline, S0),
          {ok, Q2} = quod_simplex:test_enqueue_dtx_intent(
                       From2, self(), Intent2, Begin2, GroupRef2,
                       Deadline, Q1),
          {ok, Q3} = quod_simplex:test_enqueue_dtx_intent(
                       From3, self(), Intent3, Begin3, GroupRef3,
                       Deadline, Q2),
          {ok, Q4} = quod_simplex:test_enqueue_dtx_intent(
                       From4, self(), Intent4, Begin4, GroupRef4,
                       Deadline, Q3),
          Unavailable = quod_simplex:test_state_set(sync, unconfirmed, Q4),
          {keep_state, WithoutMiddle, MiddleActions} =
              quod_simplex:running(
                cast, {cancel_dtx_begin, self(), Intent3}, Unavailable),
          ?assertEqual([], reply_actions(MiddleActions)),
          {keep_state, WithoutLast, LastActions} =
              quod_simplex:running(
                cast, {cancel_dtx_begin, self(), Intent4}, WithoutMiddle),
          ?assertEqual([], reply_actions(LastActions)),
          ?assertEqual(
             #{engine => self(), dormant => #{},
               waiting => [Intent1, Intent2]},
             quod_simplex:test_dtx_admission_state(WithoutLast)),
          Ready = quod_simplex:test_state_set(sync, ready, WithoutLast),
          {Promoted, HeadActions} =
              quod_simplex:test_progress_dtx_admission(Ready),
          ?assertEqual(
             [{reply, From1, {accepted, Intent1}},
              {reply, From2, {accepted, Intent2}}], HeadActions),
          ?assertEqual(
             #{engine => self(),
               dormant => #{quod_dtx:group_id(Begin1) => Intent1,
                            quod_dtx:group_id(Begin2) => Intent2},
               waiting => []},
             quod_simplex:test_dtx_admission_state(Promoted)),
          OnlySecond = quod_simplex:test_cancel_dtx_intent(
                         self(), Intent1, Promoted),
          ?assertEqual(
             #{engine => self(),
               dormant => #{quod_dtx:group_id(Begin2) => Intent2},
               waiting => []},
             quod_simplex:test_dtx_admission_state(OnlySecond)),
          _ = quod_simplex:test_cancel_dtx_intent(self(), Intent2, OnlySecond),
          ok
      end).

dtx_expired_non_head_is_cancelled_without_a_simplex_reply_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, _Begin, _GroupRef, S0) ->
          [{HeadBegin, HeadRef}, {ExpiredBegin, ExpiredRef},
           {TailBegin, TailRef}] = dtx_admission_variants(Fixture, 3),
          [Head, Expired, Tail] = [make_ref() || _ <- lists:seq(1, 3)],
          [HeadFrom, ExpiredFrom, TailFrom] =
              [{self(), make_ref()} || _ <- lists:seq(1, 3)],
          Deadline = quod_time:mono_ms() + 5000,
          {ok, Q1} = quod_simplex:test_enqueue_dtx_intent(
                       HeadFrom, self(), Head, HeadBegin, HeadRef,
                       Deadline, S0),
          {D1, [{reply, HeadFrom, {accepted, Head}}]} =
              quod_simplex:test_progress_dtx_admission(Q1),
          {ok, Q2} = quod_simplex:test_enqueue_dtx_intent(
                       ExpiredFrom, self(), Expired, ExpiredBegin, ExpiredRef,
                       Deadline, D1),
          {ok, Q3} = quod_simplex:test_enqueue_dtx_intent(
                       TailFrom, self(), Tail, TailBegin, TailRef,
                       Deadline, Q2),
          ExpiredQueue = quod_simplex:test_set_dtx_intent_deadline(
                           Expired, quod_time:mono_ms() - 1, Q3),
          Unavailable = quod_simplex:test_state_set(
                          sync, unconfirmed, ExpiredQueue),
          %% The proof worker owns non-head expiry. Its cancellation removes
          %% the exact alias first, then this cast removes the queue entry and
          %% Simplex emits no reply for the already-dead caller.
          {keep_state, Cancelled, Actions} =
              quod_simplex:running(
                cast, {cancel_dtx_begin, self(), Expired}, Unavailable),
          ?assertEqual([], reply_actions(Actions)),
          ?assertEqual(
             #{engine => self(),
               dormant => #{quod_dtx:group_id(HeadBegin) => Head},
               waiting => [Tail]},
             quod_simplex:test_dtx_admission_state(Cancelled)),
          _ = quod_simplex:test_cancel_dtx_intent(self(), Head, Cancelled),
          ok
      end).

dtx_admission_engine_down_drops_all_volatile_intents_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, _Begin, _GroupRef, S0) ->
          [{Begin1, GroupRef1}, {Begin2, GroupRef2}] =
              dtx_admission_variants(Fixture, 2),
          Intent1 = make_ref(),
          Intent2 = make_ref(),
          Deadline = quod_time:mono_ms() + 5000,
          From1 = {self(), make_ref()},
          From2 = {self(), make_ref()},
          {ok, Q1} = quod_simplex:test_enqueue_dtx_intent(
                       From1, self(), Intent1, Begin1, GroupRef1,
                       Deadline, S0),
          {D1, _} = quod_simplex:test_progress_dtx_admission(Q1),
          {ok, Q2} = quod_simplex:test_enqueue_dtx_intent(
                       From2, self(), Intent2, Begin2, GroupRef2,
                       Deadline, D1),
          {true, Cleared} =
              quod_simplex:test_drop_dtx_admission_owner(Q2),
          ?assertEqual(
             #{engine => none, dormant => #{}, waiting => []},
             quod_simplex:test_dtx_admission_state(Cleared))
      end).

dtx_admission_rechecks_binding_before_promotion_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, Begin, GroupRef, S0) ->
          #{pubkey := Author} = maps:get(node_identity, Fixture),
          OldAdmission = maps:get(admission, Fixture),
          Intent = make_ref(),
          From = {self(), make_ref()},
          Deadline = quod_time:mono_ms() + 5000,
          {ok, Queued} = quod_simplex:test_enqueue_dtx_intent(
                           From, self(), Intent, Begin, GroupRef,
                           Deadline, S0),
          ChangedAdmissions = #{Author => <<91:256>>},
          Changed0 = quod_simplex:test_set_author_admissions(
                       ChangedAdmissions, Queued),
          Changed = quod_simplex:test_retire_changed_admissions(
                      #{Author => OldAdmission}, ChangedAdmissions, Changed0),
          {Rejected,
           [{reply, From, {error, invalid_dtx_intent}}]} =
              quod_simplex:test_progress_dtx_admission(Changed),
          ?assertEqual(
             #{engine => none, dormant => #{}, waiting => []},
             quod_simplex:test_dtx_admission_state(Rejected))
      end).

%% A younger conflicting Begin is a normal pre-handoff OCC refusal, not an
%% unexpected state.  It leaves no dormant intent and cannot stop an
%% independent request behind it from advancing in the same progress pass.
dtx_admission_conflict_rejects_once_and_advances_fifo_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, _Begin, _GroupRef, S0) ->
          Origin = maps:get(target, Fixture),
          Identity = maps:get(node_identity, Fixture),
          Admission = maps:get(admission, Fixture),
          KeyPair = maps:get(key_pair, Fixture),
          Other = quod_ct:signed_dtx_begin_fixture(
                    #{target => Origin, node_identity => Identity,
                      admission => Admission, key_pair => KeyPair,
                      proof_id => <<301:256>>, operation_id => <<302:256>>,
                      submitted_at => 2}),
          [Holder, Contender] =
              lists:sort(
                fun(A, B) ->
                        quod_dtx:group_id(maps:get('begin', A)) <
                            quod_dtx:group_id(maps:get('begin', B))
                end, [Fixture, Other]),
          {_, _, HolderRef} = certified_dtx_test_entry(
                                Origin, maps:get(begin_control, Holder), 1),
          {ok, _History, Locked, _Effects} = quod_dtx:reduce(
                                                maps:get(begin_control, Holder),
                                                HolderRef,
                                                quod_dtx:initial_group_history(),
                                                quod_dtx:initial_projection(
                                                  Origin, 0)),
          ContenderBegin = maps:get('begin', Contender),
          {ok, ContenderRef} = quod_dtx:begin_group_ref(ContenderBegin),
          Independent = quod_ct:signed_dtx_begin_fixture(
                          #{target => Origin, node_identity => Identity,
                            admission => Admission, key_pair => KeyPair,
                            goal_text => <<"assertz(independent(ok)).">>,
                            proof_id => <<303:256>>,
                            operation_id => <<304:256>>, submitted_at => 3}),
          IndependentBegin = maps:get('begin', Independent),
          {ok, IndependentRef} = quod_dtx:begin_group_ref(IndependentBegin),
          ConflictIntent = make_ref(),
          IndependentIntent = make_ref(),
          ConflictFrom = {self(), make_ref()},
          IndependentFrom = {self(), make_ref()},
          Deadline = quod_time:mono_ms() + 5000,
          LockedState = quod_simplex:test_state_set(
                          dtx_projection, Locked, S0),
          {ok, Q1} = quod_simplex:test_enqueue_dtx_intent(
                       ConflictFrom, self(), ConflictIntent,
                       ContenderBegin, ContenderRef, Deadline, LockedState),
          {ok, Q2} = quod_simplex:test_enqueue_dtx_intent(
                       IndependentFrom, self(), IndependentIntent,
                       IndependentBegin, IndependentRef, Deadline, Q1),
          {Advanced, Actions} =
              quod_simplex:test_progress_dtx_admission(Q2),
          ?assertEqual(
             [{reply, ConflictFrom, {error, operation_conflict}},
              {reply, IndependentFrom, {accepted, IndependentIntent}}],
             Actions),
          ?assertEqual(
             #{engine => self(),
               dormant => #{quod_dtx:group_id(IndependentBegin) =>
                                  IndependentIntent},
               waiting => []},
             quod_simplex:test_dtx_admission_state(Advanced)),
          _ = quod_simplex:test_cancel_dtx_intent(
                self(), IndependentIntent, Advanced),
          ok
      end).

dtx_retained_begin_does_not_block_an_independent_group_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, Begin, GroupRef, S0) ->
          Control = maps:get(begin_control, Fixture),
          Retained = quod_simplex:test_seed_dtx_submission(
                       Control, [], S0),
          [{OtherBegin, OtherGroupRef}] =
              dtx_admission_variants(Fixture, 1),
          Intent = make_ref(),
          From = {self(), make_ref()},
          Deadline = quod_time:mono_ms() + 5000,
          {ok, Queued} = quod_simplex:test_enqueue_dtx_intent(
                           From, self(), Intent, OtherBegin, OtherGroupRef,
                           Deadline, Retained),
          {Promoted, [{reply, From, {accepted, Intent}}]} =
              quod_simplex:test_progress_dtx_admission(Queued),
          ?assertEqual(
             #{engine => self(),
               dormant => #{quod_dtx:group_id(OtherBegin) => Intent},
               waiting => []},
             quod_simplex:test_dtx_admission_state(Promoted)),
          _ = quod_simplex:test_cancel_dtx_intent(self(), Intent, Promoted),
          ?assertEqual(quod_dtx:group_id(Begin), element(6, GroupRef)),
          ok
      end).

dtx_expired_head_replies_once_and_advances_fifo_test() ->
    with_dtx_admission_fixture(
      fun(Fixture, _Begin, _GroupRef, S0) ->
          [{ExpiredBegin, ExpiredGroupRef}, {LiveBegin, LiveGroupRef}] =
              dtx_admission_variants(Fixture, 2),
          ExpiredIntent = make_ref(),
          LiveIntent = make_ref(),
          ExpiredFrom = {self(), make_ref()},
          LiveFrom = {self(), make_ref()},
          Soon = quod_time:mono_ms() + 5000,
          Later = Soon + 5000,
          {ok, Q1} = quod_simplex:test_enqueue_dtx_intent(
                       ExpiredFrom, self(), ExpiredIntent,
                       ExpiredBegin, ExpiredGroupRef, Soon, S0),
          {ok, Q2} = quod_simplex:test_enqueue_dtx_intent(
                       LiveFrom, self(), LiveIntent, LiveBegin, LiveGroupRef,
                       Later, Q1),
          ExpiredQueue = quod_simplex:test_set_dtx_intent_deadline(
                           ExpiredIntent, quod_time:mono_ms() - 1, Q2),
          TemporarilyUnavailable = quod_simplex:test_state_set(
                                     sync, unconfirmed, ExpiredQueue),
          {AfterExpiry,
           [{reply, ExpiredFrom,
             {error, {proof_limit_exceeded, _}}}]} =
              quod_simplex:test_progress_dtx_admission(
                TemporarilyUnavailable),
          ?assertEqual(
             #{engine => self(), dormant => #{}, waiting => [LiveIntent]},
             quod_simplex:test_dtx_admission_state(AfterExpiry)),
          Ready = quod_simplex:test_state_set(sync, ready, AfterExpiry),
          {Promoted, [{reply, LiveFrom, {accepted, LiveIntent}}]} =
              quod_simplex:test_progress_dtx_admission(Ready),
          {_Same, []} = quod_simplex:test_progress_dtx_admission(Promoted),
          _ = quod_simplex:test_cancel_dtx_intent(
                self(), LiveIntent, Promoted),
          ok
      end).

dtx_prepare_contact_is_bound_to_its_certified_origin_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    ?assertEqual(
       {ok, maps:get(origin, Fixture)},
       quod_simplex:test_dtx_source_identity(
         maps:get(prepare, Fixture), maps:get(target, Fixture))),
    %% A co-hosted origin needs no foreign bootstrap association, and record
    %% kinds without an authenticated source reference create none.
    ?assertEqual(
       none,
       quod_simplex:test_dtx_source_identity(
         maps:get(prepare, Fixture), maps:get(origin, Fixture))),
    ?assertEqual(
       none,
       quod_simplex:test_dtx_source_identity(
         maps:get('begin', Fixture), maps:get(target, Fixture))).

%% A keyed peer may claim any origin inside decode-only DTX material. The
%% authenticated endpoint is useful to the exact verification attempt, but it
%% must not become a reusable route before that attempt succeeds. A transient
%% history row is not the security boundary: an exact verifier or an unrelated
%% legitimate follower may own one while this asynchronous request is active.
dtx_unverified_endpoint_contacts_are_never_retained_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Dir = relay_store_dir("unverified_dtx_contact"),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> gen_server:stop(Existing);
        undefined -> ok
    end,
    Fetch = fun(_Peer, _Endpoint, _Ns, _From, _To) ->
                    {error, unavailable}
            end,
    {ok, ForeignLog} = quod_foreign_log:start_link(
                         #{cache_dir => Dir, fetch_fun => Fetch,
                           page_timeout_ms => 100}),
    EndpointSink = spawn(fun registered_prolog_sink_loop/0),
    {Peer, _PeerIdentity} = id(),
    Endpoint = {"127.0.0.1", 15972},
    PeerContact = {Peer, Endpoint},
    try
        Operation = quod_ct:remote_operation_fixture(#{}),
        {ok, ClaimEvidence} = quod_transaction:encode_evidence(
                                maps:get(certified_claim_ref, Operation),
                                maps:get(claim, Operation)),
        ApplyRequest = {apply_claim, <<72:128>>, ClaimEvidence},
        {TargetNs, _} = Target = maps:get(participant_target, Operation),
        ApplyState0 = ready_dtx_endpoint_state(
                        Target, maps:get(node_identity, Operation),
                        maps:get(admission, Operation)),
        {ok, ApplyFrame} = quod_dtx_endpoint:encode_request(
                             TargetNs, ApplyRequest, []),
        {ApplyState, []} = quod_simplex:test_dtx_endpoint_frame(
                             TargetNs, serve, PeerContact, EndpointSink,
                             ApplyFrame, ApplyState0),
        ?assertEqual(
           false,
           foreign_contact_is_routable(Target, PeerContact)),
        ?assertEqual(
           0,
           maps:get(bootstrap_candidates, quod_foreign_log:stats())),
        ok = quod_simplex:test_close_dtx_endpoint(ApplyState),

        PrepareFixture = quod_ct:dtx_prepare_fixture(),
        {PrepareNs, _} = PrepareTarget = maps:get(target, PrepareFixture),
        SubmitRequest = {submit, <<73:128>>,
                         maps:get(prepare_blob, PrepareFixture)},
        SubmitState0 = ready_dtx_endpoint_state(
                         PrepareTarget, maps:get(signer, PrepareFixture),
                         maps:get(admission, PrepareFixture),
                         %% Reject after decoding but before signing or
                         %% retaining. The old path had already persisted the
                         %% claimed source contact at this exact point.
                         #{dtx_projection => undefined}),
        {ok, SubmitFrame} = quod_dtx_endpoint:encode_request(
                              PrepareNs, SubmitRequest, []),
        {SubmitState, []} = quod_simplex:test_dtx_endpoint_frame(
                              PrepareNs, serve, PeerContact, EndpointSink,
                              SubmitFrame, SubmitState0),
        ?assertEqual(
           false,
           foreign_contact_is_routable(PrepareTarget, PeerContact)),
        ?assertEqual(
           0,
           maps:get(bootstrap_candidates, quod_foreign_log:stats())),
        ok = quod_simplex:test_close_dtx_endpoint(SubmitState)
    after
        stop_registered_prolog_sink(EndpointSink),
        gen_server:stop(ForeignLog),
        _ = file:del_dir_r(Dir)
    end.

%% Seen is shared across the candidate's requirements, but the reference kind
%% remains part of the proof obligation.  Identical bytes already verified as
%% a control entry cannot later satisfy a transaction requirement (or the
%% reverse) merely because both requirements use the same map key.
content_reference_seen_reuse_is_type_safe_test() ->
    Ref = {certified, <<74:256>>, 2, <<75:256>>, <<76:256>>},
    EntryEvidence = #{entry => #entry{index = 2, data = noop}},
    TransactionEvidence = #{transaction => #transaction{}},
    ?assertMatch(
       {valid, _},
       quod_simplex:test_verify_content_requirements(
         [{entry, Ref}, {entry, Ref}], #{Ref => EntryEvidence})),
    ?assertEqual(
       {invalid, foreign_reference},
       quod_simplex:test_verify_content_requirements(
         [{entry, Ref}, {transaction, Ref}], #{Ref => EntryEvidence})),
    ?assertEqual(
       {invalid, foreign_reference},
       quod_simplex:test_verify_content_requirements(
         [{transaction, Ref}, {entry, Ref}],
         #{Ref => TransactionEvidence})).

%% The authenticated endpoint is a request-scoped route hint for the claim
%% transaction only.  Read-certificate anchors in the same application must
%% be resolved and verified independently, never through that contact.
content_reference_contact_is_claim_only_test() ->
    Fixture = quod_ct:remote_operation_fixture(#{}),
    ClaimRef = maps:get(certified_claim_ref, Fixture),
    Application = maps:get(application, Fixture),
    Target = maps:get(participant_target, Fixture),
    {ok, EvidenceBlob} = quod_transaction:encode_evidence(
                           ClaimRef, maps:get(claim, Fixture)),
    Request = {apply_claim, <<77:128>>, EvidenceBlob},
    Worker = spawn(fun validation_owner/0),
    Peer = <<78:256>>,
    Endpoint = {"127.0.0.1", 15973},
    {_Monitor, State} = quod_simplex:test_seed_dtx_worker(
                          Worker, {Peer, Endpoint}, Request,
                          {link, self()}, st(#{})),
    EntryRef = {certified, <<79:256>>, 3, <<80:256>>, <<81:256>>},
    try
        Contacts = quod_simplex:test_content_reference_contacts(
                     [{Application,
                       [{transaction, ClaimRef}, {entry, EntryRef}]}],
                     Target, State),
        ?assertEqual(
           #{ClaimRef => {maps:get(origin, Fixture), {Peer, Endpoint}}},
           Contacts),
        ?assertEqual(false, maps:is_key(EntryRef, Contacts))
    after
        exit(Worker, kill)
    end.

foreign_contact_is_routable(Identity, {Peer, Endpoint}) ->
    case quod_foreign_log:route_hints(Identity, []) of
        {ok, Routes} ->
            lists:member(Endpoint, proplists:get_value(Peer, Routes, []));
        {error, unavailable} ->
            false
    end.

ready_dtx_endpoint_state(
  {Ns, Anchor}, #{pubkey := _} = Identity, Admission) ->
    ready_dtx_endpoint_state(
      {Ns, Anchor}, Identity, Admission, #{}).

ready_dtx_endpoint_state(
  {Ns, Anchor}, #{pubkey := Self} = Identity, Admission, Extra) ->
    st(maps:merge(
         #{ns => Ns, genesis_hash => Anchor,
           self => Self, id => Identity,
           validators => [Self],
           author_admissions => #{Self => Admission},
           sync => ready, prolog_ready => true},
         Extra)).

%% The endpoint deadline owns only its waiter, not the durable semantic
%% submission.  Once the owner dies, a later recovery request can attach one
%% fresh waiter instead of seeing `busy` forever or accumulating dead PIDs.
dtx_endpoint_owner_down_detaches_waiter_but_retains_submission_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Control = maps:get(prepare_control, Fixture),
    Record = maps:get(prepare, Fixture),
    {ok, RecordBlob} = quod_dtx:encode_record(Record),
    Request = {submit, <<211:128>>, RecordBlob},
    Worker = spawn(fun validation_owner/0),
    From = {self(), make_ref()},
    {Monitor, WithWorker} = quod_simplex:test_seed_dtx_worker(
                              Worker, local, Request, {caller, From}, st(#{})),
    Retained = quod_simplex:test_seed_dtx_submission(
                 Control, [{dtx_endpoint, Worker}], WithWorker),
    RetainedState = quod_simplex:test_retained_dtx_state(Retained),
    exit(Worker, kill),
    receive
        {'DOWN', Monitor, process, Worker, killed} -> ok
    after 1000 ->
        error(missing_endpoint_owner_down)
    end,
    {true, Detached, _Actions} = quod_simplex:test_drop_dtx_endpoint_owner(
                                   Monitor, Worker, Retained),
    ?assertEqual(0, quod_simplex:test_dtx_submission_waiters(Detached)),
    DetachedState = quod_simplex:test_retained_dtx_state(Detached),
    ?assertEqual(maps:get(bytes, RetainedState),
                 maps:get(bytes, DetachedState)),
    ?assertEqual(#{}, maps:get(waiter_index, DetachedState)),
    ?assertEqual(
       maps:get(retained, DetachedState),
       maps:get(ready, DetachedState) + maps:get(blocked, DetachedState)),
    ?assertEqual(
       1, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(Detached))),
    RetryOwner = spawn(fun validation_owner/0),
    try
        {ok, Retried} = quod_simplex:test_retain_dtx_record(
                          Record, {dtx_endpoint, RetryOwner}, Detached),
        ?assertEqual(1, quod_simplex:test_dtx_submission_waiters(Retried)),
        ?assertEqual(
           #{RetryOwner => quod_dtx:record_digest(Record)},
           maps:get(waiter_index,
                    quod_simplex:test_retained_dtx_state(Retried)))
    after
        RetryOwner ! stop
    end.

%% A co-hosted endpoint submit enters custody in its call turn, then one
%% self-message drives every control already waiting in the mailbox. This is
%% immediate and event-driven, but gives concurrent submissions one natural
%% Erlang scheduling edge in which to form a byte-bounded consensus wave.
dtx_endpoint_local_submit_drives_on_mailbox_edge_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = maps:get(prepare, Fixture),
    {ok, RecordBlob} = quod_dtx:encode_record(Record),
    Request = {submit, <<212:128>>, RecordBlob},
    {ok, [{_Phase, RequiredRef} | _]} =
        quod_foreign_log:required_references(Record),
    {ok, _Identity, RequiredSlot, _Digest} =
        quod_dtx:certified_ref_binding(RequiredRef),
    ValidationSidecar =
        [{RequiredRef, #entry{index = RequiredSlot, data = noop}}],
    From = {self(), make_ref()},
    Dir = relay_store_dir("dtx_local_immediate"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer,
                  validators => [Self],
                  author_admissions => #{Self => Admission},
                  sync => ready, prolog_ready => true,
                  slot => 0, approved => 0,
                  history_head => {0, <<0:256>>},
                  eng => quod_simplex:eng_new(?DOMAIN, [Self], 0),
                  store => memory, signing_journal => Journal}),
        {keep_state, Retained, _Actions0} =
            quod_simplex:running(
              {call, From},
              {dtx_endpoint_local, Request, ValidationSidecar, 1000}, S0),
        try
            ?assertEqual(
               0, maps:get(proposals, quod_simplex:stats_map(Retained))),
            receive dtx_drive -> ok
            after 0 -> error(missing_dtx_mailbox_wake)
            end,
            {keep_state, Proposed, _Actions1} =
                quod_simplex:running(info, dtx_drive, Retained),
            ?assertEqual(
               1, maps:get(proposals, quod_simplex:stats_map(Proposed))),
            {_, _, {_, #block{slot = 1}}, _, _} =
                quod_simplex:test_dtx_round(1, Proposed),
            ?assertEqual(ValidationSidecar,
                         quod_simplex:test_dtx_round_hints(1, Proposed))
        after
            ok = quod_simplex:terminate(test, running, Retained)
        end
    after
        _ = catch quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

%% Once a retained control is queued on a live ordered link, unrelated
%% progress turns must not enqueue it again.  The placement is tied to the
%% link pid, so replacing that link makes the same durable row eligible for
%% exactly one reconstruction send without a retry clock or relay queue.
dtx_reliable_relay_is_placed_once_per_link_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = maps:get(prepare, Fixture),
    {ok, RecordBlob} = quod_dtx:encode_record(Record),
    Request = {submit, <<213:128>>, RecordBlob},
    Peer = <<0:256>>,
    ?assertNotEqual(Peer, Self),
    Validators = lists:sort([Peer, Self]),
    Parent = self(),
    FirstLink = spawn(fun() -> receive_ordered_relay(Parent, first_link) end),
    From = {self(), make_ref()},
    Dir = relay_store_dir("dtx_reliable_placement"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer,
                  validators => Validators,
                  author_admissions => #{Self => Admission},
                  sync => ready, prolog_ready => true,
                  slot => 0, approved => 0,
                  history_head => {0, <<0:256>>},
                  eng => quod_simplex:eng_new(?DOMAIN, Validators, 0),
                  store => memory, signing_journal => Journal,
                  conns => #{Peer => {FirstLink, make_ref()}}}),
        {keep_state, Retained, _Actions0} =
            quod_simplex:running(
              {call, From},
              {dtx_endpoint_local, Request, [], 1000}, S0),
        receive dtx_drive -> ok
        after 0 -> error(missing_dtx_mailbox_wake)
        end,
        {keep_state, Placed, _Actions1} =
            quod_simplex:running(info, dtx_drive, Retained),
        FirstFrame =
            receive {first_link, Frame} -> Frame
            after 1000 -> error(missing_ordered_dtx_relay)
            end,
        [#{relay_placement := {Peer, LinkPid}}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Placed))),
        ?assertEqual(FirstLink, LinkPid),
        {keep_state, Unchanged, _Actions2} =
            quod_simplex:test_keep_progress_transition(Placed, Placed),
        receive
            {send_ordered, _DuplicateFrame} ->
                error(duplicate_ordered_dtx_relay)
        after 0 ->
            ok
        end,
        NewLink = spawn(fun() -> receive_ordered_relay(Parent, new_link) end),
        Reconnected = quod_simplex:test_state_set(
                        conns, #{Peer => {NewLink, make_ref()}}, Unchanged),
        {keep_state, Replaced, _Actions3} =
            quod_simplex:test_keep_progress_transition(
              Reconnected, Reconnected),
        receive
            {new_link, FirstFrame} -> ok
        after 1000 ->
            error(missing_reconnected_dtx_relay)
        end,
        [#{relay_placement := {Peer, NewLink}}] =
            maps:values(
              maps:get(rows,
                       quod_simplex:test_retained_dtx_state(Replaced)))
    after
        _ = catch quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

receive_ordered_relay(Parent, Tag) ->
    receive
        {send_ordered, Frame} -> Parent ! {Tag, Frame};
        _OtherLinkTraffic -> receive_ordered_relay(Parent, Tag)
    end.

%% A relayed control that reaches the current leader while an ordinary batch
%% is open used to be discarded by handle_dtx_submit/4. It now enters the one
%% retained DTX owner and shares the same mailbox wake as a local endpoint
%% submit; no retry tick or second relay queue is needed.
dtx_relay_received_while_leader_busy_is_retained_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Signer = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Control = maps:get(prepare_control, Fixture),
    {ok, Envelope} = quod_dtx:encode_control(Control),
    Dir = relay_store_dir("dtx_relay_retention"),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        Busy = quod_simplex:test_state_set(
                 collecting, {1, []},
                 st(#{ns => Ns, genesis_hash => Anchor,
                      self => Self, id => Signer,
                      validators => [Self],
                      author_admissions => #{Self => Admission},
                      signing_journal => Journal,
                      sync => ready, prolog_ready => true})),
        Retained = quod_simplex:dispatch(
                     Self, {dtx_submit, [Envelope], []}, Busy),
        ?assertMatch(
           #{retained := 1, ready := 1, waiters := 0},
           quod_simplex:test_retained_dtx_state(Retained)),
        ?assert(quod_simplex:test_dtx_drive_scheduled(Retained)),
        receive dtx_drive -> ok
        after 0 -> error(missing_relay_dtx_mailbox_wake)
        end
    after
        ok = quod_signing_journal:close(Journal),
        _ = file:del_dir_r(Dir)
    end.

dtx_semantic_commit_retires_an_equivalent_retained_envelope_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    Original = maps:get(begin_control, Fixture),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, Committed} =
        quod_dtx:sign_control(
          Origin, Begin, maps:get(admission, Fixture), 2, 2,
          maps:get(signer, Fixture)),
    {ok, Envelope} = quod_dtx:encode_control(Committed),
    Payload = {batch, [{dtx, Envelope}]},
    Block = #block{slot = 2, parent = 1, payload = Payload, timestamp = 0},
    BlockHash = quod_simplex:block_hash(Block),
    Entry = #entry{index = 2, data = Payload,
                   cert = #cert{kind = commit, slot = 2,
                                block_hash = BlockHash, sigs = []}},
    Seeded = quod_simplex:test_seed_dtx_submission(
               Original, [], st(#{ns => Ns, genesis_hash => Anchor})),
    Resolved = quod_simplex:test_resolve_committed_dtx(
                 Entry, Payload, Seeded),
    ?assertEqual(
       0, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(Resolved))).

%% The retained-control gauges expose the exact consensus owner rather than a
%% second accounting store.  A normal keep_progress pass remembers the peak;
%% the canonical committed-control reducer then removes the row while that
%% owner-lifetime peak and its byte high-water mark remain observable.
dtx_owner_stats_keep_peak_after_committed_cleanup_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Control = maps:get(prepare_control, Fixture),
    Seeded = quod_simplex:test_seed_dtx_submission(
               Control, [],
               st(#{eng => quod_simplex:eng_with_certs(0, [])})),
    SeededStats = quod_simplex:stats_map(Seeded),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_current, SeededStats))),
    RetainedBytes = maps:get(
                      dtx_control,
                      maps:get(owner_bytes_current, SeededStats)),
    ?assert(RetainedBytes > 0),

    {keep_state, Tracked, _Actions} =
        quod_simplex:test_keep_progress_transition(Seeded, Seeded),
    TrackedStats = quod_simplex:stats_map(Tracked),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_peak, TrackedStats))),
    ?assertEqual(
       RetainedBytes,
       maps:get(dtx_control, maps:get(owner_bytes_peak, TrackedStats))),

    {Entry, Payload} = committed_dtx_test_entry(Control, 1),
    Cleared = quod_simplex:test_resolve_committed_dtx(
                Entry, Payload, Tracked),
    ClearedStats = quod_simplex:stats_map(Cleared),
    ?assertEqual(
       #{retained => 0, ready => 0, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_current, ClearedStats))),
    ?assertEqual(
       #{retained => 1, ready => 1, blocked => 0, waiters => 0},
       maps:get(dtx_control, maps:get(owner_peak, ClearedStats))),
    ?assertEqual(
       0, maps:get(dtx_control,
                   maps:get(owner_bytes_current, ClearedStats))),
    ?assertEqual(
       RetainedBytes,
       maps:get(dtx_control,
                maps:get(owner_bytes_peak, ClearedStats))).

dtx_catchup_retires_retained_submission_and_replies_exact_ref_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    Original = maps:get(begin_control, Fixture),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, Committed} =
        quod_dtx:sign_control(
          Origin, Begin, maps:get(admission, Fixture), 1, 2,
          maps:get(signer, Fixture)),
    {ok, OriginalEnvelope} = quod_dtx:encode_control(Original),
    {ok, Envelope} = quod_dtx:encode_control(Committed),
    ?assertNotEqual(OriginalEnvelope, Envelope),
    Payload = {batch, [{dtx, Envelope}]},
    Block = #block{slot = 1, parent = 0, payload = Payload, timestamp = 0},
    BlockHash = quod_simplex:block_hash(Block),
    Entry = #entry{index = 1, data = Payload,
                   cert = #cert{kind = commit, slot = 1,
                                block_hash = BlockHash, sigs = []}},
    Dir = relay_store_dir("catchup_dtx_submission"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    try
        Seeded = quod_simplex:test_seed_dtx_submission(
                   Original, [{dtx_endpoint, self()}],
                   st(#{ns => Ns, genesis_hash => Anchor, store => Store0})),
        {Recovered, ok} =
            quod_simplex:test_apply_catchup_window(
              recovery, [Entry], quod_simplex:history_projection(Origin),
              Seeded),
        receive
            {dtx_submit_result, {ok, Ref, Entry}} ->
                ?assert(quod_dtx:validate_certified_ref(Ref)),
                {quod_dtx_ref, _Version, Ns, Anchor, 1, BlockHash,
                 RecordDigest, _FinalityProof} = Ref,
                ?assertEqual(quod_dtx:record_digest(Begin),
                             RecordDigest)
        after 0 ->
            ?assert(false)
        end,
        ?assertEqual(
           0, maps:get(submissions,
                       quod_simplex:test_dtx_endpoint_counts(Recovered))),
        {1, DurableStore} = quod_simplex:test_committed_store(Recovered),
        ?assertEqual({ok, Entry}, quod_ledger_store:read_at(DurableStore, 1))
    after
        quod_ledger_store:close(Store0),
        file:del_dir_r(Dir)
    end.

%% The catch-up callback itself must release the next sealed write. There is no
%% later tick in this test: a certified Complete clears the active group and
%% `sink_catchup` must pass that state through the common progress tail before
%% replying to its caller.
dtx_catchup_complete_promotes_fifo_on_a_quiet_namespace_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    Target = maps:get(target, Fixture),
    Signer = maps:get(signer, Fixture),
    Coordinator = maps:get(pubkey, Signer),
    Admission = maps:get(admission, Fixture),
    Begin = maps:get('begin', Fixture),
    BeginControl = maps:get(begin_control, Fixture),
    GroupId = quod_dtx:group_id(Begin),
    {BeginEntry, _BeginPayload, BeginRef} =
        certified_dtx_test_entry(Origin, BeginControl, 1),
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef,
                       {abort, [{test_abort, catchup_release}]},
                       [{Origin, BeginRef}]),
    {ok, DecisionControl} = quod_dtx:sign_control(
                              Origin, Decision, Admission, 2, 2, Signer),
    {DecisionEntry, _DecisionPayload, DecisionRef} =
        certified_dtx_test_entry(Origin, DecisionControl, 2),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, abort, none, 0),
    {ok, FinalizeControl} = quod_dtx:sign_control(
                              Target, Finalize, Admission, 1, 3, Signer),
    {_FinalizeEntry, _FinalizePayload, FinalizeRef} =
        certified_dtx_test_entry(Target, FinalizeControl, 1),
    {ok, _Manifest, _OriginPlanDigest, OriginPlanBlob} =
        quod_dtx:begin_participant_payload(Begin, Origin),
    {ok, OriginPlan} = quod_dtx:decode(OriginPlanBlob),
    OriginGeneration = quod_dtx:overlay_generation(OriginPlan),
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef,
                       [{Origin, DecisionRef, OriginGeneration},
                        {Target, FinalizeRef, 0}]),
    {ok, CompleteControl} = quod_dtx:sign_control(
                              Origin, Complete, Admission, 3, 4, Signer),
    {CompleteEntry, _CompletePayload, CompleteRef} =
        certified_dtx_test_entry(Origin, CompleteControl, 3),
    {ok, H1, P1, _} = quod_dtx:reduce(
                         BeginControl, BeginRef,
                         quod_dtx:initial_group_history(),
                         quod_dtx:initial_projection(Origin, 0)),
    {ok, H2, P2, _} = quod_dtx:reduce(
                         DecisionControl, DecisionRef, H1, P1),
    {ok, _H3, P3, _} = quod_dtx:reduce(
                          CompleteControl, CompleteRef, H2, P2),
    FutureSeed = quod_ct:signed_dtx_begin_fixture(
                   #{target => Origin, node_identity => Signer,
                     admission => Admission}),
    [{FutureBegin, FutureGroupRef}] =
        dtx_admission_variants(FutureSeed, 1),
    Dir = relay_store_dir("catchup_dtx_admission_release"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store2} = quod_ledger_store:append(
                     Store0, [BeginEntry, DecisionEntry]),
    PrologPid = start_registered_prolog_sink(Ns),
    try
        Base = st(#{ns => Ns, genesis_hash => Anchor, store => Store2,
                    slot => 2, self => Coordinator,
                    validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    dtx_projection => P2, sync => ready,
                    eng => quod_simplex:eng_with_certs(2, [])}),
        Intent = make_ref(),
        IntentFrom = {self(), make_ref()},
        {ok, Queued0} = quod_simplex:test_enqueue_dtx_intent(
                          IntentFrom, PrologPid, Intent,
                          FutureBegin, FutureGroupRef,
                          quod_time:mono_ms() + 5000, Base),
        Queued = Queued0,
        Projection =
            (quod_simplex:history_projection(
               [Coordinator], <<212:256>>,
               #{Coordinator => Admission}, #{Coordinator => 3}, 3))#{
              dtx := P3,
              dtx_lanes := #{{Admission, Coordinator} => 3},
              history_head := {3, element(6, CompleteRef)}},
        Pulling = quod_simplex:test_state_set(
                    sync, {pulling, self()}, Queued),
        SinkFrom = {self(), make_ref()},
        {keep_state, Recovered, Actions} =
            quod_simplex:running(
              {call, SinkFrom},
              {sink_catchup, {recovery, self()}, [CompleteEntry], Projection},
              Pulling),
        ?assert(lists:member({reply, SinkFrom, ok}, Actions)),
        ?assertNot(lists:member(
                     {reply, IntentFrom, {accepted, Intent}}, Actions)),
        ?assertEqual(
           #{engine => PrologPid, dormant => #{}, waiting => [Intent]},
           quod_simplex:test_dtx_admission_state(Recovered)),
        %% The recovery owner always follows its final verified sink call with
        %% this readiness result. It is the first point where signing is safe,
        %% and its existing keep_progress tail must promote without a timer or
        %% unrelated mailbox event.
        {keep_state, Ready, ReadyActions} =
            quod_simplex:running(
              cast, {sync_done, self(), {ready, 3}}, Recovered),
        ?assert(lists:member(
                  {reply, IntentFrom, {accepted, Intent}}, ReadyActions)),
        ?assertEqual(
           #{engine => PrologPid,
             dormant => #{quod_dtx:group_id(FutureBegin) => Intent},
             waiting => []},
           quod_simplex:test_dtx_admission_state(Ready))
    after
        stop_registered_prolog_sink(PrologPid),
        quod_ledger_store:close(Store0),
        file:del_dir_r(Dir)
    end.

unsigned_begin_history_replay_does_not_require_root_identity_test() ->
    SavedDesired = application:get_env(quod, namespace_desired),
    application:unset_env(quod, namespace_desired),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    Signer = maps:get(signer, Fixture),
    Pub = maps:get(pubkey, Signer),
    Admission = maps:get(admission, Fixture),
    Control = maps:get(begin_control, Fixture),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Data = {batch, [{dtx, ControlBlob}]},
    Block = #block{slot = 1, parent = 0, payload = Data, timestamp = 0},
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, 1, BlockHash, Signer),
    Entry = #entry{index = 1, data = Data, timestamp = 0,
                   cert = #cert{kind = commit, slot = 1,
                                block_hash = BlockHash,
                                sigs = [{Pub, Signature}]}},
    Projection0 =
        (quod_simplex:history_projection(
           [Pub], <<1:256>>, #{Pub => Admission}, #{}, 0))#{
          dtx := quod_dtx:initial_projection(Origin, 0)},
    Dir = relay_store_dir("unsigned_begin_history"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
    try
        ?assertMatch({error, _}, quod_ontology:network_identity()),
        ?assertMatch(
           {ok, _Projection1, _Effects},
           quod_simplex:history_advance(
             Origin, Entry, Projection0, PhaseIndex))
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        _ = file:del_dir_r(Dir),
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

signed_content_history_replay_waits_for_root_identity_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Target = maps:get(target, Fixture),
    Network = maps:get(network, Fixture),
    Transaction = maps:get(transaction, Fixture),
    #{pubkey := Author} = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    Deadline = maps:get(deadline, Fixture),
    Projection0 = quod_simplex:history_projection(
                    [Author], undefined, #{Author => Admission}, #{}, 0),
    Entry = #entry{index = 2, data = {batch, [Transaction]},
                   timestamp = Deadline},
    without_network_identity(
      fun() ->
          ?assertEqual(
             {error, {unavailable, network_identity, not_hosted}},
             quod_simplex:history_validate_advance(
               Target, Entry, Projection0))
      end),
    quod_ct:with_network_identity(
      Network,
      fun() ->
          ?assertMatch(
             {ok, _Projection1},
             quod_simplex:history_validate_advance(
               Target, Entry, Projection0))
      end).

signed_begin_history_replay_waits_for_root_identity_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Network = maps:get(network, Fixture),
    Control = maps:get(begin_control, Fixture),
    #{pubkey := Author} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    Data = {batch, [{dtx, ControlBlob}]},
    Block = #block{slot = 1, parent = 0, payload = Data, timestamp = 1},
    BlockHash = quod_simplex:block_hash(Block),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    #share{sig = Signature} = quod_simplex:make_share(
                                Domain, commit, 1, BlockHash, Identity),
    Entry = #entry{index = 1, data = Data, timestamp = 1,
                   cert = #cert{kind = commit, slot = 1,
                                block_hash = BlockHash,
                                sigs = [{Author, Signature}]}},
    Projection0 =
        (quod_simplex:history_projection(
           [Author], <<1:256>>, #{Author => Admission}, #{}, 0))#{
          dtx := quod_dtx:initial_projection(Target, 0)},
    Dir = relay_store_dir("signed_begin_history_identity"),
    {ok, PhaseIndex} = quod_dtx_phase_index:open(Dir, Ns),
    try
        without_network_identity(
          fun() ->
              ?assertEqual(
                 {error, {unavailable, network_identity, not_hosted}},
                 quod_simplex:history_advance(
                   Target, Entry, Projection0, PhaseIndex))
          end),
        quod_ct:with_network_identity(
          Network,
          fun() ->
              ?assertMatch(
                 {ok, _Projection1, _Effects},
                 quod_simplex:history_advance(
                   Target, Entry, Projection0, PhaseIndex))
          end)
    after
        ok = quod_dtx_phase_index:close(PhaseIndex),
        _ = file:del_dir_r(Dir)
    end.

dtx_retained_selection_skips_an_older_ineligible_group_test() ->
    [Older, Active] =
        lists:sort(
          fun(A, B) ->
                  quod_dtx:group_id(maps:get('begin', A)) <
                      quod_dtx:group_id(maps:get('begin', B))
          end,
          [quod_ct:dtx_prepare_fixture(),
           quod_ct:dtx_prepare_fixture()]),
    Origin = maps:get(origin, Active),
    Begin = maps:get('begin', Active),
    BeginRef = maps:get(begin_ref, Active),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, _H1, P1, _} = quod_dtx:reduce(
                         maps:get(begin_control, Active), BeginRef, H0, P0),
    Locked = P1,
    {ok, Decision} = quod_dtx:new_decision(
                       quod_dtx:group_id(Begin), BeginRef,
                       {abort, [{test_abort, eligible_selection}]},
                       [{Origin, BeginRef}]),
    {ok, DecisionControl} = quod_dtx:sign_control(
                              Origin, Decision,
                              maps:get(admission, Active), 3, 3,
                              maps:get(signer, Active)),
    S0 = st(#{ns => element(1, Origin), genesis_hash => element(2, Origin),
              dtx_projection => Locked,
              eng => quod_simplex:eng_with_certs(0, [])}),
    %% The committed multi-group projection alone authorizes the origin's
    %% next Decision; Simplex carries no parallel singular-group marker.
    ActiveMarked = S0,
    ?assert(
       quod_simplex:test_dtx_retain_admissible(Decision, ActiveMarked)),
    %% Only role-acquisition records may wait behind another active group.
    %% A direct-abort Finalize remains the sole reducer-authorised exception.
    OlderBegin = maps:get('begin', Older),
    OlderPrepare = maps:get(prepare, Older),
    {ok, OlderDecision} = quod_dtx:new_decision(
                            quod_dtx:group_id(OlderBegin),
                            maps:get(begin_ref, Older),
                            {abort, [{test_abort, wrong_group}]},
                            [{maps:get(origin, Older),
                              maps:get(begin_ref, Older)}]),
    ?assert(
       quod_simplex:test_dtx_retain_admissible(OlderBegin, ActiveMarked)),
    ?assert(
       quod_simplex:test_dtx_retain_admissible(OlderPrepare, ActiveMarked)),
    ?assertNot(
       quod_simplex:test_dtx_retain_admissible(OlderDecision, ActiveMarked)),
    Completed = quod_simplex:test_state_set(
                  dtx_projection, quod_dtx:initial_projection(Origin, 1),
                  ActiveMarked),
    ?assertNot(
       quod_simplex:test_dtx_retain_admissible(Decision, Completed)),
    WithOlder = quod_simplex:test_seed_dtx_submission_at(
                  maps:get(begin_control, Older), [], 10, ActiveMarked),
    ?assertMatch(
       #{retained := 1, ready := 0, blocked := 1},
       quod_simplex:test_retained_dtx_state(WithOlder)),
    WithBoth = quod_simplex:test_seed_dtx_submission_at(
                 DecisionControl, [], 20, WithOlder),
    ?assert(quod_simplex:test_consensus_barrier(WithBoth)),
    ?assertNot(
       quod_simplex:test_dtx_consensus_barrier([Decision], WithBoth)),
    ?assertEqual(
       [{quod_dtx:record_digest(Decision), Decision}],
       quod_simplex:test_eligible_dtx_wave(WithBoth)),
    ?assertEqual(
       2, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(WithBoth))).

%% Retention is governed by phase readiness, not by a compiled row count. The
%% old nine-row guard would reject this exact tenth insertion with `busy`.
dtx_retained_registry_has_no_population_cap_test() ->
    {Self, Seed} = quod_identity:generate(),
    Signer = #{pubkey => Self,
               key => quod_identity:key_term({Self, Seed})},
    Origin = {Ns, Anchor} = {<<"quod:dtx-unlimited">>, <<151:256>>},
    Admission = <<152:256>>,
    Fixtures =
        [quod_ct:signed_dtx_begin_fixture(
           #{target => Origin, node_identity => Signer,
             admission => Admission, proof_id => <<(153 + I):256>>})
         || I <- lists:seq(0, 12)],
    [Active | FutureFixtures] =
        lists:reverse(
          lists:sort(
            fun(A, B) ->
                    quod_dtx:group_id(maps:get('begin', A)) <
                        quod_dtx:group_id(maps:get('begin', B))
            end, Fixtures)),
    Begin = maps:get('begin', Active),
    BeginRef = dtx_test_ref(Origin, 1, quod_dtx:record_digest(Begin)),
    H0 = quod_dtx:initial_group_history(),
    P0 = quod_dtx:initial_projection(Origin, 0),
    {ok, _H1, P1, _} = quod_dtx:reduce(
                         maps:get(begin_control, Active), BeginRef, H0, P0),
    Locked = P1,
    FutureRows =
        [begin
             FutureBegin = maps:get('begin', Future),
             FutureBeginRef = dtx_test_ref(
                                Origin, I + 10,
                                quod_dtx:record_digest(FutureBegin)),
             {I, maps:get(begin_control, Future), FutureBegin,
              FutureBeginRef}
         end || {I, Future} <- lists:zip(
                                  lists:seq(1, 12), FutureFixtures)],
    Dir = relay_store_dir("dtx_unlimited_retention"),
    {ok, Journal0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer, validators => [Self],
                  sync => ready,
                  author_admissions => #{Self => Admission},
                  signing_journal => Journal0,
                  dtx_projection => Locked}),
        Retained = lists:foldl(
                     fun({I, _BeginControl, FutureBegin, _BeginRef}, S) ->
                             case quod_simplex:test_retain_dtx_record(
                                    FutureBegin, none, S) of
                                 {ok, S1} -> S1;
                                 {error, Reason} -> error({retain_failed, I, Reason})
                             end
                     end, S0, FutureRows),
        ?assertMatch(
           #{retained := 12, ready := 0, blocked := 12,
             waiters := 0, bytes := Bytes} when Bytes > 0,
           quod_simplex:test_retained_dtx_state(Retained)),
        %% Retained selection uses the signed control's canonical lane,
        %% sequence, group and target order. Local arrival time cannot make
        %% validators choose different controls. Once one Begin applies, the
        %% others block behind it; clearing it restores the canonical order.
        SeededBegins = lists:foldl(
                         fun({I, BeginControl, _Begin, _BeginRef}, S) ->
                                 quod_simplex:test_seed_dtx_submission_at(
                                   BeginControl, [], I, S)
                         end,
                         quod_simplex:test_state_set(
                           retained_dtx, empty, S0),
                         FutureRows),
        OrderedFutureRows =
            [Row || {_Order, Row} <-
                        lists:sort(
                          [{quod_dtx:control_order_key(BeginControl), Row}
                           || Row = {_I, BeginControl, _Begin, _BeginRef}
                                  <- FutureRows])],
        Open = quod_simplex:test_refresh_retained_readiness(
                 quod_simplex:test_state_set(
                   dtx_projection, P0, SeededBegins)),
        [{_I, FirstControl, FirstBegin, FirstRef} | _] = OrderedFutureRows,
        FirstDigest = quod_dtx:record_digest(FirstBegin),
        ?assertEqual(
           [{FirstDigest, FirstBegin}],
           quod_simplex:test_eligible_dtx_wave(Open)),
        {ok, _History, ActiveProjection, _Effects} =
            quod_dtx:reduce(
              FirstControl, FirstRef, quod_dtx:initial_group_history(), P0),
        %% Wait-die is deterministic: after the oldest GroupId wins, every
        %% younger conflicting Begin is refused rather than parked forever.
        AfterFirst = quod_simplex:test_refresh_retained_readiness(
                       quod_simplex:test_state_set(
                         dtx_projection, ActiveProjection, Open)),
        ?assertMatch(
           #{retained := 0, ready := 0, blocked := 0},
           quod_simplex:test_retained_dtx_state(AfterFirst))
    after
        _ = catch quod_signing_journal:close(Journal0),
        _ = file:del_dir_r(Dir)
    end.

%% Re-signing replaces one row through the same registry mutation path: its
%% scheduling age and exact envelope bytes change, while its observation age
%% and semantic digest remain stable.
dtx_retained_resign_updates_exact_bytes_and_preserves_observation_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Target = {Ns, Anchor} = maps:get(target, Fixture),
    Signer = #{pubkey := Self} = maps:get(signer, Fixture),
    Admission = maps:get(admission, Fixture),
    Record = maps:get(prepare, Fixture),
    Control = maps:get(prepare_control, Fixture),
    Digest = quod_dtx:record_digest(Record),
    Meta = quod_dtx:control_metadata(Control),
    Lane = {maps:get(author_admission, Meta), maps:get(author, Meta)},
    Dir = relay_store_dir("dtx_resign_accounting"),
    {ok, Journal0} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Self, id => Signer, validators => [Self],
                  sync => ready,
                  author_admissions => #{Self => Admission},
                  signing_journal => Journal0,
                  dtx_projection => quod_dtx:initial_projection(Target, 0),
                  dtx_lanes => #{Lane => maps:get(sequence, Meta)}}),
        Seeded = quod_simplex:test_seed_dtx_submission_at(
                   Control, [], 10, S0),
        Before = quod_simplex:test_retained_dtx_state(Seeded),
        BeforeRow = maps:get(Digest, maps:get(rows, Before)),
        Renewed = quod_simplex:test_refresh_retained_dtx_signatures(Seeded),
        After = quod_simplex:test_retained_dtx_state(Renewed),
        AfterRow = maps:get(Digest, maps:get(rows, After)),
        ?assertEqual(10, maps:get(observation_started_at, AfterRow)),
        ?assertNotEqual(10, maps:get(inserted_at, AfterRow)),
        ?assertNotEqual(maps:get(envelope, BeforeRow),
                        maps:get(envelope, AfterRow)),
        ?assertEqual(
           maps:get(bytes, Before) - maps:get(bytes, BeforeRow)
             + maps:get(bytes, AfterRow),
           maps:get(bytes, After)),
        ?assertEqual(1, maps:get(ready, After)),
        ?assertEqual(0, maps:get(blocked, After))
    after
        _ = catch quod_signing_journal:close(Journal0),
        _ = file:del_dir_r(Dir)
    end.

%% The owner starts recovery from the journal-retained Begin immediately. A
%% crashed volatile worker is replaced from that same durable source by the
%% exact DOWN event; no unrelated tick or retry delay discovers progress.
%% The exact GroupId has one owner while other groups remain independent.
dtx_origin_coordinator_is_group_scoped_and_restarts_from_retained_begin_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    BeginControl = maps:get(begin_control, Fixture),
    {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_dtx:begin_group_ref(Begin),
    SBase = st(#{ns => Ns, genesis_hash => Anchor,
                 self => Coordinator, validators => [Coordinator],
                 sync => ready, prolog_ready => true}),
    S0 = quod_simplex:test_state_set(
           author_admissions, #{Coordinator => Admission}, SBase),
    Pending = quod_simplex:test_seed_dtx_submission(
                BeginControl, [], S0),
    Running = quod_simplex:test_reconcile_dtx_coordinator(Pending),
    #{status := running, group_id := GroupId,
      pid := Pid, monitor := Monitor} =
        maps:get(GroupId, quod_simplex:test_dtx_coordinator_state(Running)),
    ?assert(is_process_alive(Pid)),
    %% Reconciliation is idempotent while this exact owner is live.
    ?assertEqual(
       Pid,
       maps:get(
         pid,
         maps:get(
           GroupId,
           quod_simplex:test_dtx_coordinator_state(
             quod_simplex:test_reconcile_dtx_coordinator(Running))))),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, killed} -> ok
    after 1000 ->
        error(missing_coordinator_down)
    end,
    {true, Restarted} = quod_simplex:test_drop_dtx_coordinator(
                          Monitor, Pid, killed, Running),
    #{status := running, pid := Pid2} =
        maps:get(GroupId,
                 quod_simplex:test_dtx_coordinator_state(Restarted)),
    ?assert(Pid2 =/= Pid),
    ?assert(is_process_alive(Pid2)),
    _ = quod_simplex:test_stop_dtx_coordinator(Restarted),
    ok.

%% Certification changes the durable representation, not the recovery owner.
%% The commit path installs the exact Begin reference into the existing owner
%% before retiring its retained row; reconciliation must therefore preserve
%% the live process instead of killing it and rereading the just-committed
%% entry from disk.
dtx_committed_begin_is_adopted_by_live_coordinator_test() ->
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    BeginControl = maps:get(begin_control, Fixture),
    {Ns, Anchor} = Origin = maps:get(origin, Fixture),
    {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_dtx:begin_group_ref(Begin),
    S0 = quod_simplex:test_state_set(
           author_admissions, #{Coordinator => Admission},
           st(#{ns => Ns, genesis_hash => Anchor,
                self => Coordinator, validators => [Coordinator],
                sync => ready, prolog_ready => true})),
    Pending = quod_simplex:test_seed_dtx_submission(
                BeginControl, [], S0),
    PreBegin = quod_simplex:test_reconcile_dtx_coordinator(Pending),
    #{status := running, pid := OldPid, begin_ref := none} =
        maps:get(GroupId,
                 quod_simplex:test_dtx_coordinator_state(PreBegin)),
    {Entry, Payload, BeginRef} =
        certified_dtx_test_entry(Origin, BeginControl, 1),
    Resolved = quod_simplex:test_resolve_committed_dtx(
                 Entry, Payload, PreBegin),
    #{status := running, pid := OldPid, begin_ref := BeginRef} =
        maps:get(GroupId,
                 quod_simplex:test_dtx_coordinator_state(Resolved)),
    ?assertEqual(
       0, maps:get(submissions,
                   quod_simplex:test_dtx_endpoint_counts(Resolved))),
    {ok, _History, Projection, _} = quod_dtx:reduce(
                                      BeginControl, BeginRef,
                                      quod_dtx:initial_group_history(),
                                      quod_dtx:initial_projection(Origin, 0)),
    Committed = quod_simplex:test_state_set(
                  dtx_projection, Projection, Resolved),
    Reconciled = quod_simplex:test_reconcile_dtx_coordinator(Committed),
    #{status := running, group_id := GroupId,
      begin_ref := BeginRef, pid := OldPid} =
        maps:get(GroupId,
                 quod_simplex:test_dtx_coordinator_state(Reconciled)),
    ?assert(is_process_alive(OldPid)),
    _ = quod_simplex:test_stop_dtx_coordinator(Reconciled),
    ok.

%% Historical-Begin recovery already runs under the Simplex owner that holds
%% the immutable ledger root.  It must verify that ledger directly rather than
%% call back into the same statem and turn a busy startup mailbox into
%% `not_ready`.  No Simplex is registered for Ns here, so the former callback
%% path necessarily returned not_ready while the owner-provided path succeeds.
dtx_committed_begin_bootstrap_uses_owned_ledger_source_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    BeginControl = maps:get(begin_control, Fixture),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_dtx:begin_group_ref(Begin),
    {_Entry, _Payload, BeginRef} =
        certified_dtx_test_entry(Origin, BeginControl, 1),
    {ok, _History, Projection, _} = quod_dtx:reduce(
                                      BeginControl, BeginRef,
                                      quod_dtx:initial_group_history(),
                                      quod_dtx:initial_projection(Origin, 0)),
    Dir = relay_store_dir("committed_begin_owned_source"),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> gen_server:stop(Existing);
        undefined -> ok
    end,
    Parent = self(),
    ForeignLog = spawn(
                   fun() ->
                       true = quod_reg:reg({foreign_log, node}),
                       Parent ! {foreign_log_ready, self()},
                       receive
                           {'$gen_call', {Caller, Tag},
                            {verify_local, Dir, BeginRef, 'begin', Timeout}}
                             when is_integer(Timeout), Timeout > 0 ->
                               Caller !
                                   {Tag,
                                    {ok, #{phase => 'begin',
                                           control => BeginControl}}},
                               receive stop -> ok end
                       end
                   end),
    receive {foreign_log_ready, ForeignLog} -> ok after 1000 ->
        error(foreign_log_registration_timeout)
    end,
    try
        undefined = quod_reg:where({quod_simplex, Ns}),
        Base = st(#{ns => Ns, genesis_hash => Anchor,
                    ledger_root => Dir, slot => 1,
                    self => Coordinator, validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    sync => ready, prolog_ready => true,
                    dtx_projection => Projection}),
        Recovering = quod_simplex:test_reconcile_dtx_coordinator(Base),
        #{status := recovering, pid := Worker} =
            maps:get(GroupId,
                     quod_simplex:test_dtx_coordinator_state(Recovering)),
        receive
            {dtx_coordinator_bootstrap, Worker, GroupId, BeginRef,
             {ok, #{phase := 'begin', control := BeginControl}}} ->
                ok;
            {dtx_coordinator_bootstrap, Worker, GroupId, BeginRef, Other} ->
                error({unexpected_begin_bootstrap_result, Other})
        after 5000 ->
            error(committed_begin_bootstrap_timeout)
        end,
        _ = quod_simplex:test_stop_dtx_coordinator(Recovering)
    after
        ForeignLog ! stop,
        file:del_dir_r(Dir)
    end.

%% One ontology's certified-history cache has one writer.  Starting every
%% historical Begin check together only moves that same-identity work into the
%% verifier queue, where their caller deadlines expire together.  Recovery
%% must admit one check and let its completion message start the next; this
%% fixture holds the first verifier call open and proves no second call or
%% recovery owner is created meanwhile.
dtx_committed_begin_bootstrap_respects_foreign_history_lane_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    BeginControl = maps:get(begin_control, Fixture),
    Origin = {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId1}} =
        quod_dtx:begin_group_ref(Begin),
    {_Entry, _Payload, BeginRef} =
        certified_dtx_test_entry(Origin, BeginControl, 1),
    GroupId2 = crypto:hash(sha256, <<GroupId1/binary, "next">>),
    Desired =
        #{GroupId1 => {reference, GroupId1, BeginRef},
          GroupId2 => {reference, GroupId2, BeginRef}},
    Dir = relay_store_dir("committed_begin_history_lane"),
    case quod_reg:where({foreign_log, node}) of
        Existing when is_pid(Existing) -> gen_server:stop(Existing);
        undefined -> ok
    end,
    Parent = self(),
    ForeignLog = spawn(
                   fun() ->
                       true = quod_reg:reg({foreign_log, node}),
                       Parent ! {foreign_log_ready, self()},
                       foreign_log_hold_verifications(Parent, Dir, BeginRef)
                   end),
    receive {foreign_log_ready, ForeignLog} -> ok after 1000 ->
        error(foreign_log_registration_timeout)
    end,
    try
        Base = st(#{ns => Ns, genesis_hash => Anchor,
                    ledger_root => Dir, slot => 1,
                    self => Coordinator, validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    sync => ready, prolog_ready => true}),
        Recovering = quod_simplex:test_reconcile_dtx_coordinators(
                       Desired, Base),
        ?assertEqual(
           1,
           map_size(quod_simplex:test_dtx_coordinator_state(Recovering))),
        receive {verify_local_started, ForeignLog} -> ok after 1000 ->
            error(first_begin_bootstrap_not_started)
        end,
        receive
            {verify_local_started, ForeignLog} ->
                error(second_begin_bootstrap_started_concurrently)
        after 100 ->
            ok
        end,
        _ = quod_simplex:test_stop_dtx_coordinator(Recovering)
    after
        ForeignLog ! stop,
        file:del_dir_r(Dir)
    end.

foreign_log_hold_verifications(Parent, Dir, BeginRef) ->
    receive
        {'$gen_call', _From,
         {verify_local, Dir, BeginRef, 'begin', _Timeout}} ->
            Parent ! {verify_local_started, self()},
            foreign_log_hold_verifications(Parent, Dir, BeginRef);
        stop -> ok
    end.

%% The generic state builder has one dependency: `validators` supplies default
%% admission ids, but a test's explicit admission view is authoritative.  This
%% must not depend on maps:fold/3 traversal order (which differs as the VM atom
%% table and map representation change across the full suite).
test_state_explicit_admissions_override_validator_defaults_test() ->
    {Validator, _Identity} = id(),
    ExplicitAdmission = <<16#A5:256>>,
    ?assertNotEqual(
       quod_simplex:test_author_admission(Validator), ExplicitAdmission),
    State = st(#{validators => [Validator],
                 author_admissions => #{Validator => ExplicitAdmission}}),
    ?assertEqual(
       #{Validator => ExplicitAdmission},
       quod_simplex:test_author_admissions(State)).

%% Reconciliation is the one retirement boundary for a journaled Begin. A
%% new admission for the same node must not inherit or re-sign the old
%% admission-bound GroupRef: clear the pending outcome before applying the
%% membership entry, retire its exact envelope, stop its volatile coordinator,
%% then recheck the exact waiter only after the ordered apply.
pending_begin_reconciliation_retires_old_admission_in_order_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    Control = maps:get(begin_control, Fixture),
    Signer = maps:get(signer, Fixture),
    {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, GroupRef =
           {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_dtx:begin_group_ref(Begin),
    Meta = quod_dtx:control_metadata(Control),
    Sequence = maps:get(sequence, Meta),
    Lane = {Admission, Coordinator},
    Dir = relay_store_dir("pending_begin_retirement"),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1, _Envelope} =
            quod_signing_journal:record_dtx(Journal0, Control),
        Base = st(#{ns => Ns, genesis_hash => Anchor,
                    self => Coordinator, id => Signer,
                    validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    sync => ready, prolog_ready => true, slot => 1,
                    signing_journal => Journal1,
                    dtx_pending => #{GroupId => Lane},
                    dtx_lanes => #{Lane => Sequence}}),
        Pending = quod_simplex:test_seed_dtx_submission(
                    Control, [{dtx_endpoint, self()}], Base),
        Running = quod_simplex:test_reconcile_dtx_coordinator(Pending),
        #{status := running, pid := CoordinatorPid} =
            maps:get(GroupId,
                     quod_simplex:test_dtx_coordinator_state(Running)),
        ?assert(is_process_alive(CoordinatorPid)),

        NewAdmission = crypto:hash(sha256, <<Admission/binary, "readmitted">>),
        ?assertNotEqual(Admission, NewAdmission),
        Readmitted = quod_simplex:test_state_set(
                       author_admissions,
                       #{Coordinator => NewAdmission}, Running),
        {Reconciled, Transition} =
            quod_simplex:test_reconcile_signing_state(Readmitted),
        ?assertEqual({cleared_pending_begins, [GroupRef]}, Transition),
        ?assertEqual(
           #{},
           quod_signing_journal:pending_begins(
             quod_simplex:test_signing_journal(Reconciled))),
        ?assertEqual(
           0, maps:get(submissions,
                       quod_simplex:test_dtx_endpoint_counts(Reconciled))),
        receive
            {'$gen_cast', {project_pending_begins, []}} -> ok
        after 1000 ->
            error(pending_begin_was_not_cleared)
        end,
        receive
            {dtx_submit_result, {error, not_in_charge}} -> ok
        after 1000 ->
            error(old_admission_submission_was_not_retired)
        end,

        Stopped = quod_simplex:test_reconcile_dtx_coordinator(Reconciled),
        ?assertEqual(#{}, quod_simplex:test_dtx_coordinator_state(Stopped)),
        ok = quod_ct:wait_until(
               fun() -> not is_process_alive(CoordinatorPid) end, 1000),

        MembershipEntry = #entry{index = 1, data = noop},
        ok = quod_prolog:apply_entry(Ns, MembershipEntry, live),
        _ = quod_simplex:test_finish_pending_begins_reconciliation(
              Transition, Stopped),
        receive
            {'$gen_cast', FirstAfterClear} ->
                ?assertEqual(
                   {apply_entry, MembershipEntry, live}, FirstAfterClear)
        after 1000 ->
            error(membership_apply_was_not_ordered)
        end,
        receive
            {'$gen_cast', SecondAfterClear} ->
                ?assertEqual(
                   {dtx_group_resolved, GroupRef}, SecondAfterClear)
        after 1000 ->
            error(group_waiter_was_not_rechecked)
        end,
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Stopped))
    after
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        file:del_dir_r(Dir)
    end.

%% A committed high-water under the same admission only invalidates the old
%% outer envelope. Reconciliation retains the semantic Begin and its waiter
%% while allocating one fresh sequence under that exact same lane.
pending_begin_same_admission_stale_sequence_reenvelopes_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:dtx_prepare_fixture(),
    Begin = maps:get('begin', Fixture),
    Control = maps:get(begin_control, Fixture),
    Signer = maps:get(signer, Fixture),
    {Ns, Anchor} = maps:get(origin, Fixture),
    {ok, {group, Ns, Anchor, Coordinator, Admission, GroupId}} =
        quod_dtx:begin_group_ref(Begin),
    Meta = quod_dtx:control_metadata(Control),
    Sequence = maps:get(sequence, Meta),
    Lane = {Admission, Coordinator},
    Dir = relay_store_dir("pending_begin_reenvelope"),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1, OldEnvelope} =
            quod_signing_journal:record_dtx(Journal0, Control),
        Base = st(#{ns => Ns, genesis_hash => Anchor,
                    self => Coordinator, id => Signer,
                    validators => [Coordinator],
                    author_admissions => #{Coordinator => Admission},
                    sync => ready, prolog_ready => true, slot => 1,
                    signing_journal => Journal1,
                    dtx_pending => #{GroupId => Lane},
                    dtx_lanes => #{Lane => Sequence}}),
        Pending = quod_simplex:test_seed_dtx_submission(
                    Control, [{dtx_endpoint, self()}], Base),
        {Reconciled, Transition} =
            quod_simplex:test_reconcile_signing_state(Pending),
        ?assertEqual(none, Transition),
        #{lane := Lane, sequence := NewSequence,
          envelope := NewEnvelope} =
            maps:get(
              GroupId,
              quod_signing_journal:pending_begins(
                quod_simplex:test_signing_journal(Reconciled))),
        ?assertEqual(Sequence + 1, NewSequence),
        ?assertNotEqual(OldEnvelope, NewEnvelope),
        {ok, NewControl} = quod_dtx:decode_control(NewEnvelope),
        ?assertEqual(Begin, quod_dtx:control_body(NewControl)),
        ?assertEqual(
           1, maps:get(submissions,
                       quod_simplex:test_dtx_endpoint_counts(Reconciled))),
        ?assertEqual(1, quod_simplex:test_dtx_submission_waiters(Reconciled)),
        receive
            {'$gen_cast',
             {project_pending_begins,
              [#{lane := Lane, sequence := NewSequence,
                 group_id := GroupId}]}} -> ok
        after 1000 ->
            error(reenveloped_begin_was_not_projected)
        end,
        receive
            {dtx_submit_result, _Unexpected} ->
                error(still_valid_waiter_was_replied)
        after 0 ->
            ok
        end,
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Reconciled))
    after
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns})),
        file:del_dir_r(Dir)
    end.

%% Applied corroboration is bound to the exact committee that certified the
%% Finalize. A later committee change must not rewrite that historical claim.
dtx_endpoint_applied_uses_finalize_committee_test() ->
    {Author, AuthorId} = id(),
    Ns = <<"quod:dtx-applied-history">>,
    Anchor = <<35:256>>,
    Target = {Ns, Anchor},
    DecisionOrigin = {<<"quod:dtx-applied-origin">>, <<34:256>>},
    GroupId = <<36:256>>,
    Generation = 4,
    DecisionRef = dtx_test_ref(DecisionOrigin, 2, <<37:256>>),
    PrepareRef = dtx_test_ref(Target, 3, <<38:256>>),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, commit,
                       PrepareRef, Generation),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Finalize, <<39:256>>, 1, 1, AuthorId),
    FinalizeRef = dtx_test_ref(
                    Target, 4, quod_dtx:record_digest(Control)),
    HistoricalCommitteeId = <<40:256>>,
    CurrentCommitteeId = <<41:256>>,
    Evidence = #{identity => Target, phase => finalize, control => Control,
                 committee => [Author],
                 committee_id => HistoricalCommitteeId},
    Snapshot =
        #{applied_floor => 8, generation => 11, history => none,
          applied => #{finalize_ref => FinalizeRef,
                       generation => Generation, verdict => commit}},
    S = st(#{ns => Ns, genesis_hash => Anchor, self => Author, id => AuthorId,
             validators => [Author], committee_id => CurrentCommitteeId,
             slot => 8, sync => ready, prolog_ready => true, store => memory,
             dtx_projection => quod_dtx:initial_projection(Target, 11)}),
    RequestId = <<42:128>>,
    Request = {applied, RequestId, GroupId, FinalizeRef,
               Generation, commit},
    NetworkIdentity = <<43:256>>,
    with_network_identity(
      NetworkIdentity,
      fun() ->
          {ok, {Author, Signature}} =
              quod_dtx_current_view:sign_applied_vote(
                NetworkIdentity, Target, HistoricalCommitteeId, GroupId,
                FinalizeRef, Generation, commit, AuthorId),
          ?assertEqual(
             {applied, RequestId, Target, HistoricalCommitteeId, GroupId,
              FinalizeRef, Generation, commit, Author, Signature},
             quod_simplex:test_dtx_endpoint_result(
               Request, {applied_state, Evidence, Snapshot}, S))
      end).

read_attest_observer_returns_typed_unavailable_without_signing_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    {Ns, Anchor} = quod_dtx:target(Plan),
    {Self, Identity} = id(),
    {Validator, _ValidatorIdentity} = id(),
    Applied = 8,
    State = st(#{ns => Ns, genesis_hash => Anchor,
                 self => Self, id => Identity,
                 validators => [Validator], slot => Applied,
                 last_applied => Applied, sync => ready,
                 prolog_ready => true, store => memory}),
    RequestId = <<58:128>>,
    ?assertEqual(
       {error, RequestId, read_certificate_unavailable},
       quod_simplex:test_dtx_endpoint_result(
         {read_attest, RequestId, PlanBlob},
         {read_plan_valid, Plan, Applied}, State)).

history_source_role_requirement_is_checked_by_the_consensus_owner_test() ->
    Ns = <<"quod:history-role">>,
    Anchor = crypto:hash(sha256, <<1501:64>>),
    Self = crypto:hash(sha256, <<1502:64>>),
    LedgerRoot = <<"/tmp/quod-history-role">>,
    Base = quod_simplex:test_state(
             #{ns => Ns, self => Self, genesis_hash => Anchor,
               ledger_root => LedgerRoot, store => ready,
               sync => ready, prolog_ready => true, validators => []}),
    Identity = {Ns, Anchor},
    ?assertEqual(
       {ok, LedgerRoot},
       quod_simplex:test_local_history_source(Identity, any, Base)),
    ?assertEqual(
       {error, read_certificate_unavailable},
       quod_simplex:test_local_history_source(Identity, validator, Base)),
    Validator = quod_simplex:test_state_set(validators, [Self], Base),
    ?assertEqual(
       {ok, LedgerRoot},
       quod_simplex:test_local_history_source(
         Identity, validator, Validator)).

read_attest_stale_token_refusal_remains_typed_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    RequestId = <<59:128>>,
    ?assertEqual(
       {error, RequestId, conflict_retry},
       quod_simplex:test_dtx_endpoint_result(
         {read_attest, RequestId, PlanBlob},
         {error, conflict_retry}, st(#{}))).

read_attest_requires_one_exact_applied_height_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    RequestId = <<60:128>>,
    Request = {read_attest, RequestId, PlanBlob},
    Refusal = {error, RequestId, read_certificate_unavailable},
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 8},
         st(#{slot => 9, last_applied => 8}))),
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 8},
         st(#{slot => 8, last_applied => 9}))),
    ?assertEqual(
       Refusal,
       quod_simplex:test_dtx_endpoint_result(
         Request, {read_plan_valid, Plan, 9},
         st(#{slot => 8, last_applied => 8}))).

read_attest_validator_signs_the_exact_current_ledger_anchor_test() ->
    {Self, Identity} = id(),
    Target = {Ns, Anchor} =
        {<<"quod:read-attest-validator">>, <<60:256>>},
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{target => Target, node_identity => Identity,
                  goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Control = maps:get(begin_control, Fixture),
    {Entry1, _} = committed_dtx_test_entry(Control, 1),
    {Entry2, _} = committed_dtx_test_entry(Control, 2),
    Noop = #entry{index = 3, data = noop},
    Dir = relay_store_dir("read_attest_validator"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store3} = quod_ledger_store:append(
                     Store0, [Entry1, Entry2, Noop]),
    try
        State = st(#{ns => Ns, genesis_hash => Anchor,
                     self => Self, id => Identity,
                     validators => [Self], slot => 3, last_applied => 3,
                     sync => ready, prolog_ready => true, store => Store3}),
        RequestId = <<61:128>>,
        {read_attest, RequestId, Target, ProofId, PlanDigest, AnchorRef,
         CommitteeId, Self, Signature} =
            quod_simplex:test_dtx_endpoint_result(
              {read_attest, RequestId, PlanBlob},
              {read_plan_valid, Plan, 3}, State),
        ?assertEqual(quod_dtx:proof_id(Plan), ProofId),
        ?assertEqual(quod_dtx:digest(Plan), PlanDigest),
        ?assertMatch({ok, Target, 2, _},
                     quod_dtx:certified_ref_binding(AnchorRef)),
        ?assert(quod_read_certificate:verify_vote(
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                  Self, Signature))
    after
        quod_ledger_store:close(Store3),
        file:del_dir_r(Dir)
    end.

read_attest_validator_signs_the_pinned_genesis_anchor_test() ->
    {Self, Identity} = id(),
    Ns = <<"quod:read-attest-genesis">>,
    Genesis = quod_simplex:test_genesis_tx(
                #{external_predicate_modules => []}, Ns, Self, <<62:256>>),
    Entry = #entry{index = 1, data = {batch, [Genesis]},
                   timestamp = 0, cert = none},
    {ok, Block} = quod_simplex:block_from_entry(Entry),
    Anchor = quod_simplex:block_hash(Block),
    Target = {Ns, Anchor},
    Fixture = quod_ct:signed_dtx_begin_fixture(
                #{target => Target, node_identity => Identity,
                  goal_text => <<"\\+(missing(ok)).">>}),
    Plan = maps:get(plan, Fixture),
    {ok, PlanBlob} = quod_dtx:encode(Plan),
    Dir = relay_store_dir("read_attest_genesis"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ledger_store:append(Store0, [Entry]),
    try
        ?assertMatch({ok, _},
                     quod_dtx:certified_entry_ref(Target, Entry, Genesis)),
        State = st(#{ns => Ns, genesis_hash => Anchor,
                     self => Self, id => Identity,
                     validators => [Self], slot => 1, last_applied => 1,
                     sync => ready, prolog_ready => true, store => Store1}),
        RequestId = <<63:128>>,
        {read_attest, RequestId, Target, ProofId, PlanDigest, AnchorRef,
         CommitteeId, Self, Signature} =
            quod_simplex:test_dtx_endpoint_result(
              {read_attest, RequestId, PlanBlob},
              {read_plan_valid, Plan, 1}, State),
        ?assertMatch({ok, Target, 1, _},
                     quod_dtx:certified_ref_binding(AnchorRef)),
        ?assert(quod_read_certificate:verify_vote(
                  Target, ProofId, PlanDigest, AnchorRef, CommitteeId,
                  Self, Signature))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

dtx_endpoint_applied_waits_for_exact_projection_message_test() ->
    {Author, AuthorId} = id(),
    Ns = <<"quod:dtx-applied-wake">>,
    Anchor = <<47:256>>,
    Target = {Ns, Anchor},
    DecisionOrigin = {<<"quod:dtx-applied-wake-origin">>, <<46:256>>},
    GroupId = <<48:256>>,
    Generation = 5,
    DecisionRef = dtx_test_ref(DecisionOrigin, 2, <<49:256>>),
    PrepareRef = dtx_test_ref(Target, 3, <<50:256>>),
    {ok, Finalize} = quod_dtx:new_finalize(
                       GroupId, DecisionRef, commit,
                       PrepareRef, Generation),
    {ok, Control} = quod_dtx:sign_control(
                      Target, Finalize, <<51:256>>, 1, 1, AuthorId),
    Slot = 4,
    FinalizeRef = dtx_test_ref(
                    Target, Slot, quod_dtx:record_digest(Control)),
    FinalizeCommitteeId = <<55:256>>,
    Evidence = #{identity => Target, phase => finalize, control => Control,
                 committee => [Author], committee_id => FinalizeCommitteeId},
    RequestId = <<52:128>>,
    Request = {applied, RequestId, GroupId, FinalizeRef,
               Generation, commit},
    WaitingSnapshot =
        #{applied => none, applied_floor => Slot - 1,
          generation => Generation - 1},
    Key = {GroupId, FinalizeRef, Generation, commit},
    ?assertEqual(
       {wait, Key},
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, WaitingSnapshot})),
    AppliedSnapshot =
        #{applied => #{finalize_ref => FinalizeRef,
                       generation => Generation, verdict => commit},
          applied_floor => Slot, generation => Generation},
    ?assertEqual(
       ready,
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, AppliedSnapshot})),

    %% Applied confirmation is a durable level, not a transient edge.  Once
    %% the atomic projection floor covers the exact certified Finalize,
    %% releasing the group row cannot make the operation look pending again.
    %% The group-scoped AppliedGeneration and global proof epoch are distinct.
    ReleasedSnapshot =
        #{applied => none, applied_floor => Slot,
          generation => 1},
    ?assertEqual(
       ready,
       quod_simplex:test_waiting_applied_key(
         Request, {applied_state, Evidence, ReleasedSnapshot})),
    CurrentCommitteeId = <<56:256>>,
    ReleasedState = st(
                      #{ns => Ns, genesis_hash => Anchor, self => Author,
                        id => AuthorId,
                        validators => [Author], committee_id => CurrentCommitteeId,
                        slot => Slot, sync => ready, prolog_ready => true,
                        store => memory,
                        dtx_projection =>
                          quod_dtx:initial_projection(Target, 1)}),
    NetworkIdentity = <<57:256>>,
    with_network_identity(
      NetworkIdentity,
      fun() ->
          {ok, {Author, Signature}} =
              quod_dtx_current_view:sign_applied_vote(
                NetworkIdentity, Target, FinalizeCommitteeId, GroupId,
                FinalizeRef, Generation, commit, AuthorId),
          ?assertEqual(
             {applied, RequestId, Target, FinalizeCommitteeId, GroupId,
              FinalizeRef, Generation, commit, Author, Signature},
             quod_simplex:test_dtx_endpoint_result(
               Request, {applied_state, Evidence, ReleasedSnapshot},
               ReleasedState))
      end),

    Parent = self(),
    Matching = spawn(fun() -> Parent ! {matching, receive M -> M end} end),
    Other = spawn(fun() -> Parent ! {other, receive M -> M end} end),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, self => Author,
              validators => [Author], slot => Slot, sync => ready,
              prolog_ready => true, store => memory}),
    {_MatchingMonitor, S1} =
        quod_simplex:test_seed_dtx_worker(
          Matching, local, Request, {link, self()}, S0),
    OtherRequest =
        {applied, <<53:128>>, <<54:256>>, FinalizeRef,
         Generation, commit},
    {_OtherMonitor, S2} =
        quod_simplex:test_seed_dtx_worker(
          Other, local, OtherRequest, {link, self()}, S1),
    %% The apply notification also wakes an exact waiter when this Finalize
    %% had no proof fence.  That is the ordinary no-write/abort path.
    _ = result_state(
          quod_simplex:running(
            cast, {finalize_applied, GroupId, Slot, Generation}, S2)),
    receive
        {matching, {dtx_finalize_applied, Key}} -> ok
    after 1000 ->
        error(exact_applied_worker_was_not_woken)
    end,
    receive
        {other, _Unexpected} ->
            error(unrelated_applied_worker_was_woken)
    after 0 ->
        ok
    end,
    exit(Other, kill).

%% Public outcomes are authoritative only when the responder is a member of
%% the requested frozen committee and its Prolog publication floor exactly
%% matches its current Simplex slot. A stale view, lagging projection, or
%% retired holder returns no status.
dtx_endpoint_outcome_is_current_view_and_floor_bound_test() ->
    {Self, _SelfId} = id(),
    {Other, _OtherId} = id(),
    Ns = <<"quod:dtx-outcome-view">>,
    Anchor = <<43:256>>,
    Target = {Ns, Anchor},
    CommitteeId = <<44:256>>,
    Ref = {transaction, Ns, Anchor, <<45:256>>},
    Status = #{status => pending, ref => Ref},
    Snapshot = #{applied_floor => 8, outcome => Status},
    S = st(#{ns => Ns, genesis_hash => Anchor, self => Self,
             validators => [Self], committee_id => CommitteeId,
             slot => 8, sync => ready, prolog_ready => true,
             store => memory}),
    RequestId = <<46:128>>,
    Request = {outcome, RequestId, Ref, CommitteeId, 7},
    ?assertEqual(
       {outcome, RequestId, Target, CommitteeId, 8, Status},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         setelement(4, Request, <<47:256>>),
         {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         setelement(5, Request, 9), {outcome_state, Snapshot}, S)),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot#{applied_floor => 7}}, S)),
    Ahead = quod_simplex:test_state_set(slot, 9, S),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, Ahead)),
    Retired = st(#{ns => Ns, genesis_hash => Anchor, self => Self,
                   validators => [Other], committee_id => CommitteeId,
                   slot => 8, sync => ready, prolog_ready => true,
                   store => memory}),
    ?assertEqual(
       {error, RequestId, not_ready},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, Snapshot}, Retired)).

%% Quorum-certified absence is not enough for a group that may still be in
%% the origin handoff. The exact coordinator barrier distinguishes its
%% retained Begin, definite pre-handoff absence, and changed admission.
dtx_endpoint_group_absence_barrier_is_exact_and_admission_bound_test() ->
    F = quod_ct:dtx_prepare_fixture(),
    Origin = {Ns, Anchor} = maps:get(origin, F),
    Begin = maps:get('begin', F),
    BeginControl = maps:get(begin_control, F),
    Coordinator = maps:get(pubkey, maps:get(signer, F)),
    Admission = maps:get(admission, F),
    {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
    CommitteeId = <<48:256>>,
    S0 = st(#{ns => Ns, genesis_hash => Anchor, self => Coordinator,
              validators => [Coordinator], committee_id => CommitteeId,
              slot => 8, sync => ready, prolog_ready => true,
              store => memory}),
    S = quod_simplex:test_state_set(
          author_admissions, #{Coordinator => Admission}, S0),
    Pending = quod_simplex:test_seed_dtx_submission(
                BeginControl, [], S),
    RequestId = <<49:128>>,
    Request = {outcome_barrier, RequestId, GroupRef, CommitteeId, 8},
    PendingSnapshot =
        #{applied_floor => 8,
          outcome => #{status => pending, phase => pending_begin,
                       ref => GroupRef}},
    ?assertEqual(
       {outcome_barrier, RequestId, Origin, CommitteeId, 8,
        pending_begin},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, PendingSnapshot}, Pending)),
    AbsentSnapshot = #{applied_floor => 8, outcome => not_found},
    ?assertEqual(
       {outcome_barrier, RequestId, Origin, CommitteeId, 8, not_found},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, AbsentSnapshot}, S)),
    Readmitted = quod_simplex:test_state_set(
                   author_admissions, #{Coordinator => <<50:256>>}, S),
    ?assertEqual(
       {outcome_barrier, RequestId, Origin, CommitteeId, 8,
        coordinator_retired},
       quod_simplex:test_dtx_endpoint_result(
         Request, {outcome_state, AbsentSnapshot}, Readmitted)).

%% A remote prepared participant still needs f+1 Finalize-era validators to
%% attest that its hidden plan was published. The coordinator carries that
%% bounded certificate beside Complete; each source validator verifies it
%% locally, without repeating a target network fan-out.
dtx_complete_verifies_remote_applied_certificate_locally_test() ->
    F = quod_ct:dtx_prepare_fixture(),
    Origin = maps:get(origin, F),
    Target = maps:get(target, F),
    Signer = maps:get(signer, F),
    Admission = maps:get(admission, F),
    Begin = maps:get('begin', F),
    BeginRef = maps:get(begin_ref, F),
    GroupId = quod_dtx:group_id(Begin),
    TargetPrepareControl = maps:get(prepare_control, F),
    TargetPrepare = maps:get(prepare, F),
    {ok, _TargetManifest, _TargetPlanDigest, TargetPlanBlob} =
        quod_dtx:prepare_payload(TargetPrepare),
    {ok, TargetPlan} = quod_dtx:decode(TargetPlanBlob),
    TargetGeneration = quod_dtx:overlay_generation(TargetPlan),
    {ok, _OriginManifest, _OriginPlanDigest, OriginPlanBlob} =
        quod_dtx:begin_participant_payload(Begin, Origin),
    {ok, OriginPlan} = quod_dtx:decode(OriginPlanBlob),
    OriginGeneration = quod_dtx:overlay_generation(OriginPlan),
    TargetPrepareRef = dtx_test_ref(
                         Target, 2,
                         quod_dtx:record_digest(TargetPrepareControl)),
    {ok, Decision} = quod_dtx:new_decision(
                       GroupId, BeginRef,
                       {abort, [{test_abort, mixed_finalize}]},
                       [{Origin, BeginRef},
                        {Target, TargetPrepareRef}]),
    {ok, DecisionControl} = quod_dtx:sign_control(
                              Origin, Decision, Admission, 3, 3, Signer),
    DecisionRef = dtx_test_ref(
                    Origin, 3, quod_dtx:record_digest(DecisionControl)),
    {ok, PreparedFinalize} = quod_dtx:new_finalize(
                               GroupId, DecisionRef, abort,
                               TargetPrepareRef, TargetGeneration),
    {ok, PreparedFinalizeControl} = quod_dtx:sign_control(
                                      Target, PreparedFinalize, Admission,
                                      4, 4, Signer),
    {PreparedFinalizeEntry, _FinalizePayload, PreparedFinalizeRef} =
        certified_dtx_test_entry(Target, PreparedFinalizeControl, 4),
    {ok, Complete} = quod_dtx:new_complete(
                       GroupId, DecisionRef,
                       [{Origin, DecisionRef, OriginGeneration},
                        {Target, PreparedFinalizeRef, TargetGeneration}]),
    {ok, CompleteControl} = quod_dtx:sign_control(
                              Origin, Complete, Admission, 5, 5, Signer),
    ?assertEqual(
       ok,
       quod_simplex:test_validate_dtx_reference_evidence(
         CompleteControl,
         [{decision, DecisionRef, DecisionControl},
          {finalize, PreparedFinalizeRef, PreparedFinalizeControl}])),
    Evidence =
        [{decision, DecisionRef,
          #{identity => Origin, control => DecisionControl}},
         {finalize, PreparedFinalizeRef,
          #{identity => Target, control => PreparedFinalizeControl,
            phase => finalize, entry => PreparedFinalizeEntry}}],
    NetworkIdentity = <<71:256>>,
    CommitteeId = <<72:256>>,
    Identities = [id(), id(), id(), id()],
    Committee = lists:sort([Key || {Key, _SignerIdentity} <- Identities]),
    Signers = maps:from_list(Identities),
    SignedRows =
        [begin
             {ok, Row} = quod_dtx_current_view:sign_applied_vote(
                           NetworkIdentity, Target, CommitteeId, GroupId,
                           PreparedFinalizeRef, TargetGeneration, abort,
                           maps:get(Key, Signers)),
             Row
         end || Key <- lists:sublist(Committee, 2)],
    Certificate =
        {quod_dtx_applied_certificate, 1, NetworkIdentity, Target,
         CommitteeId, GroupId, PreparedFinalizeRef, TargetGeneration,
         abort, SignedRows},
    CompleteEvidence =
        lists:keyreplace(
          finalize, 1, Evidence,
          {finalize, PreparedFinalizeRef,
           #{identity => Target, control => PreparedFinalizeControl,
             phase => finalize, entry => PreparedFinalizeEntry,
             committee => Committee, committee_id => CommitteeId}}),
    Sidecar = #{{applied, Target, PreparedFinalizeRef} => Certificate},
    ?assertEqual(
       abstain,
       quod_simplex:test_verify_complete_applied(
         CompleteControl, CompleteEvidence, #{}, NetworkIdentity)),
    ?assertEqual(
       valid,
       quod_simplex:test_verify_complete_applied(
         CompleteControl, CompleteEvidence, Sidecar, NetworkIdentity)),
    [{FirstSigner, _} | RestRows] = SignedRows,
    BadCertificate = setelement(
                       10, Certificate,
                       [{FirstSigner, <<0:512>>} | RestRows]),
    ?assertEqual(
       abstain,
       quod_simplex:test_verify_complete_applied(
         CompleteControl, CompleteEvidence,
         #{{applied, Target, PreparedFinalizeRef} => BadCertificate},
         NetworkIdentity)),
    ?assertEqual(
       abstain,
       quod_simplex:test_verify_complete_applied(
         CompleteControl, CompleteEvidence, Sidecar, <<73:256>>)).

%% Applied certificates are replaceable validation evidence for one immutable
%% Complete block hash. A bad first candidate must not shadow a later good
%% redrive, and transport fitting may discard only optional entry acceleration.
dtx_complete_validation_sidecar_replaces_and_preserves_certificate_test() ->
    Target = {<<"quod:sidecar-target">>, <<81:256>>},
    Origin = {<<"quod:sidecar-origin">>, <<82:256>>},
    GroupId = <<83:256>>,
    DecisionRef = dtx_test_ref(Origin, 3, <<84:256>>),
    FinalizeRef = dtx_test_ref(Target, 4, <<85:256>>),
    Key = {applied, Target, FinalizeRef},
    Certificate0 =
        {quod_dtx_applied_certificate, 1, <<86:256>>, Target, <<87:256>>,
         GroupId, FinalizeRef, 5, commit, [{<<88:256>>, <<89:512>>}]},
    Certificate1 = setelement(
                     10, Certificate0, [{<<88:256>>, <<90:512>>}]),
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
              Certificate0)),
    ?assert(quod_dtx_current_view:valid_applied_certificate_shape(
              Certificate1)),
    Item0 = {Key, Certificate0},
    Item1 = {Key, Certificate1},
    ?assertEqual(
       [Item1],
       quod_simplex:test_merge_validation_sidecars([Item0], [Item1])),
    Complete =
        {quod_dtx_complete, 3, GroupId, DecisionRef,
         [{Origin, DecisionRef, 5}, {Target, FinalizeRef, 5}]},
    ?assertEqual(
       [Item1],
       quod_simplex:test_relevant_validation_sidecar(Complete, [Item1])),
    OversizedEntry =
        {DecisionRef,
         #entry{index = 3, data = <<0:(5 * 1024 * 1024 * 8)>>}},
    ?assertEqual(
       [Item1],
       quod_simplex:test_fit_consensus_validation_sidecar(
         <<"quod:sidecar-owner">>, [Item1, OversizedEntry])).

%% Per-reference finality is not enough: a fully valid Begin from another
%% group must not satisfy this Prepare's exact BeginRef/manifest chain.
dtx_foreign_reference_chain_rejects_cross_group_evidence_test() ->
    Expected = quod_ct:dtx_prepare_fixture(),
    Foreign = quod_ct:dtx_prepare_fixture(),
    PrepareControl = maps:get(prepare_control, Expected),
    BeginRef = maps:get(begin_ref, Expected),
    WrongBeginControl = maps:get(begin_control, Foreign),
    ?assertEqual(
       {error, invalid_references},
       quod_simplex:test_validate_dtx_reference_evidence(
         PrepareControl,
         [{'begin', BeginRef, WrongBeginControl}])),
    ?assertEqual(
       ok,
       quod_simplex:test_validate_dtx_reference_evidence(
         PrepareControl,
         [{'begin', BeginRef, maps:get(begin_control, Expected)}])).

%% A direct-abort Finalize built from an earlier generation can legitimately
%% lose its slot to a concurrently certified Prepare.  The invalid verdict
%% must retire that exact retained Finalize and wake recovery to re-query and
%% build the prepared-abort variant; it is not a target-policy refusal.
dtx_invalid_finalize_is_released_for_phase_replan_test() ->
    {Author, AuthorId} = id(),
    Target = {Ns, Anchor} =
        {<<"quod:dtx-finalize-race">>, <<43:256>>},
    DecisionOrigin = {<<"quod:dtx-finalize-race-origin">>, <<42:256>>},
    GroupId = <<44:256>>,
    DecisionRef = dtx_test_ref(DecisionOrigin, 2, <<45:256>>),
    {ok, DirectAbort} = quod_dtx:new_finalize(
                          GroupId, DecisionRef, abort, none, 0),
    {ok, Control} = quod_dtx:sign_control(
                      Target, DirectAbort, <<46:256>>, 1, 1, AuthorId),
    {ok, ControlBlob} = quod_dtx:encode_control(Control),
    S0 = st(#{ns => Ns, genesis_hash => Anchor, self => Author,
              validators => [Author], sync => ready,
              dtx_projection => quod_dtx:initial_projection(Target, 1)}),
    Retained = quod_simplex:test_seed_dtx_submission(
                 Control, [{dtx_endpoint, self()}], S0),
    Done = quod_simplex:test_retire_invalid_dtx(
             {batch, [{dtx, ControlBlob}]},
             [generation_changed], Retained),
    receive
        {dtx_submit_result, {error, retry}} -> ok
    after 1000 ->
        error(missing_finalize_replan_reply)
    end,
    ?assertEqual(0, maps:get(submissions,
                            quod_simplex:test_dtx_endpoint_counts(Done))).

%% A stale response must not tear down a newer validation for the same slot.
%% Conversely, an exact response that is unusable because the head/floor moved
%% discards that obsolete request and candidate together. It is never parked
%% for a timer-driven retry.
dtx_verdict_cleanup_discards_only_the_exact_stale_request_test() ->
    Ns = unique_gate_namespace(<<"dtx-verdict-cleanup">>),
    Target = {Ns, <<0:256>>},
    Slot = 2,
    CurrentBH = <<22:256>>,
    CurrentToken = {1, <<23:256>>},
    OldToken = {1, <<24:256>>},
    Candidate = #block{slot = Slot, parent = Slot - 1,
                       payload = {batch, [{dtx, <<>>}]}, timestamp = 0},
    CurrentOwner = spawn(fun validation_owner/0),
    OldOwner = spawn(fun validation_owner/0),
    try
        S0 = st(#{ns => Ns, slot => 1, approved => 1,
                  history_head => CurrentToken,
                  dtx_projection => quod_dtx:initial_projection(Target, 0),
                  eng => quod_simplex:eng_new(?DOMAIN, [], 1)}),
        {Monitor, Latched} =
            quod_simplex:test_latch_dtx_validation(
              Slot, CurrentBH, CurrentToken, CurrentOwner, Candidate, S0),
        ?assert(quod_simplex:test_consensus_barrier(Latched)),
        Expected =
            {CurrentBH,
             {dtx, CurrentToken, CurrentOwner, Monitor},
             {CurrentBH, Candidate}, none, undefined},
        ?assertEqual(Expected, quod_simplex:test_dtx_round(Slot, Latched)),

        %% This belongs to an older request and is therefore an exact no-op.
        AfterStale =
            quod_simplex:test_on_dtx_verdict(
              Slot, <<21:256>>, OldToken, OldOwner, 1, abstain, Latched),
        ?assertEqual(Expected, quod_simplex:test_dtx_round(Slot, AfterStale)),

        %% The exact active request is now below the required applied floor.
        %% It cannot be used, but it must not wedge all ordinary ingress.
        Released =
            quod_simplex:test_on_dtx_verdict(
              Slot, CurrentBH, CurrentToken, CurrentOwner, 0,
              abstain, AfterStale),
        ?assertEqual(
           {none, none, none, none, undefined},
           quod_simplex:test_dtx_round(Slot, Released)),
        ?assertNot(quod_simplex:test_consensus_barrier(Released)),
        ?assertNot(erlang:demonitor(Monitor, [info]))
    after
        CurrentOwner ! stop,
        OldOwner ! stop
    end.

%% is_participant is FACTS-ONLY now — Self ∈ active_validators, with no sync/boot coupling.
is_participant_test() ->
    P = fun(Self, Vs) -> quod_simplex:is_participant(st(#{self => Self, validators => Vs})) end,
    ?assert(P(<<"me">>, [<<"a">>, <<"me">>])),
    ?assertNot(P(<<"me">>, [<<"a">>, <<"b">>])),   %% observer
    ?assertNot(P(<<"me">>, [])).                    %% unfounded

%% Only `ready` is caught up; voting and leading share the same participant + recovery capability.
gate_truth_table_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),                 %% empty pool ⇒ not behind
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),   %% a finalizer cert well past slot+1 ⇒ behind
    Base = #{self => <<"me">>, validators => [<<"me">>], slot => 2, eng => EngIdle},

    S1 = st(Base#{sync => ready}),
    ?assert(quod_simplex:caught_up(S1)),
    ?assert(quod_simplex:may_vote(S1)),

    %% A resuming member remains a participant for ingress, but has no voting capability.
    S2 = st(Base#{sync => unconfirmed}),
    ?assert(quod_simplex:is_participant(S2)),
    ?assertNot(quod_simplex:caught_up(S2)),
    ?assertNot(quod_simplex:may_vote(S2)),

    ?assertNot(quod_simplex:caught_up(st(Base#{sync => {pulling, self()}}))),
    ?assertNot(quod_simplex:caught_up(st(Base#{sync => ready, eng => EngBehind}))),

    %% A ready observer may serve/follow, but cannot vote or lead.
    Obs = st(Base#{validators => [<<"a">>], sync => ready}),
    ?assert(quod_simplex:caught_up(Obs)),
    ?assertNot(quod_simplex:may_vote(Obs)).

%% Load-robust self-corroboration: applying a LIVE quorum-cert finalization (commit_block/skip_block)
%% flips an `unconfirmed` member to `ready` — so a member that keeps up with a busy head via the live
%% stream resumes voting without needing the tip probe to catch a quiet instant. Only `unconfirmed` flips;
%% an in-flight pull (`{pulling,_}`) and an already-`ready` node are left untouched (no double-latch, and a
%% still-behind head is re-gated by `caught_up = ready AND not behind`).
confirm_live_test() ->
    ?assertEqual(ready, quod_simplex:test_sync(
                          quod_simplex:confirm_live(st(#{sync => unconfirmed})))),
    ?assertMatch({pulling, _}, quod_simplex:test_sync(
                                 quod_simplex:confirm_live(st(#{sync => {pulling, self()}})))),
    ?assertEqual(ready, quod_simplex:test_sync(
                          quod_simplex:confirm_live(st(#{sync => ready})))),
    %% a CAUGHT-UP unconfirmed member self-corroborates on a live finality and RESUMES voting (the stall fix)
    CaughtUp = st(#{self => <<"me">>, validators => [<<"me">>], slot => 3, sync => unconfirmed,
                    eng => quod_simplex:eng_with_certs(0, [])}),
    ?assertNot(quod_simplex:may_vote(CaughtUp)),                          %% unconfirmed ⇒ cannot vote (the stall)
    ?assert(quod_simplex:may_vote(quod_simplex:confirm_live(CaughtUp))),  %% live finality ⇒ ready ⇒ votes
    %% a member confirmed-live over a head still behind the tip is NOT caught up (behind re-gates voting)
    Behind = st(#{self => <<"me">>, validators => [<<"me">>], slot => 2, sync => unconfirmed,
                  eng => quod_simplex:eng_with_certs(0, [{commit, 20}])}),
    Confirmed = quod_simplex:confirm_live(Behind),
    ?assertEqual(ready, quod_simplex:test_sync(Confirmed)),
    ?assertNot(quod_simplex:caught_up(Confirmed)),
    ?assertNot(quod_simplex:may_vote(Confirmed)).

%% Recovery intent and the externally visible syncing flag derive from the same enum.
should_sync_and_syncing_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),
    Settled = st(#{sync => ready, slot => 2, eng => EngIdle}),
    ?assertNot(quod_simplex:should_sync(Settled)),
    ?assertNot(quod_simplex:syncing(Settled)),
    Fresh = st(#{sync => unconfirmed, slot => 0, eng => EngIdle}),
    ?assert(quod_simplex:should_sync(Fresh)),
    ?assert(quod_simplex:syncing(Fresh)),
    ?assert(quod_simplex:should_sync(st(#{sync => ready, slot => 2, eng => EngBehind}))),
    ?assert(quod_simplex:syncing(st(#{sync => {pulling, self()}, slot => 2, eng => EngIdle}))).

%% A final certificate for the immediate next slot is already authoritative gap evidence when this node
%% never received the block. It must lose voting capability and enter normal durable-log recovery instead
%% of waiting for the network to advance a second slot.
next_slot_finalizer_revokes_stale_voting_test() ->
    Me = <<"me">>,
    FinalizedNext = quod_simplex:eng_with_certs(5, [{commit, 6}]),
    Stale = st(#{self => Me, validators => [Me], slot => 5, approved => 5,
                 eng => FinalizedNext, sync => ready}),
    ?assert(quod_simplex:should_sync(Stale)),
    ?assertNot(quod_simplex:caught_up(Stale)),
    ?assertNot(quod_simplex:may_vote(Stale)).

%% Success grants readiness when the durable head is AT OR PAST the corroborated height. A head that
%% advanced while the completion was in flight only moves via cert-verified commits (`persisted_finality`),
%% so it is itself corroborated — accepting it is what keeps a member that stays caught up under load from
%% being bounced back to `unconfirmed` forever. A result from an OBSOLETE worker (pid mismatch) is ignored.
sync_completion_is_height_bound_test() ->
    Eng = quod_simplex:eng_with_certs(0, []),
    Base = #{self => <<"me">>, validators => [<<"me">>],
             sync => {pulling, self()}, eng => Eng, last_applied => 3, prolog_ready => true},
    %% exact corroborated height ⇒ ready
    Pulling = st(Base#{slot => 2}),
    {keep_state, Ready, _} = quod_simplex:running(cast, {sync_done, self(), {ready, 2}}, Pulling),
    ?assertEqual(ready, quod_simplex:test_sync(Ready)),
    %% head advanced past the corroborated height (live cert-verified commits) ⇒ STILL ready (no bounce)
    Advanced = st(Base#{slot => 3}),
    ?assertNot(quod_simplex:may_vote(Advanced)),   %% mid-pull ⇒ the stall: cannot vote yet
    {keep_state, Accepted, _} =
        quod_simplex:running(cast, {sync_done, self(), {ready, 2}}, Advanced),
    ?assertEqual(ready, quod_simplex:test_sync(Accepted)),
    ?assert(quod_simplex:may_vote(Accepted)),      %% accepted advanced-during-probe ⇒ RESUMES voting (the fix)
    %% a result whose pid does not own the in-flight pull is stale ⇒ state unchanged (still pulling)
    Other = spawn(fun() -> ok end),
    {keep_state, Stale} = quod_simplex:running(cast, {sync_done, Other, {ready, 2}}, Pulling),
    ?assertMatch({pulling, _}, quod_simplex:test_sync(Stale)).

tip_quorum_test() ->
    A = <<"a">>, B = <<"b">>, C = <<"c">>, D = <<"d">>, Committee = [A, B, C, D],
    ?assertNot(quod_simplex:tip_quorum(Committee, A, [B])),
    ?assert(quod_simplex:tip_quorum(Committee, A, [B, C])),
    ?assert(quod_simplex:tip_quorum(Committee, A, [B, B, C, <<"outsider">>])),
    ?assertNot(quod_simplex:tip_quorum(Committee, <<"outsider">>, [A, B])).

%% A sole validator settles locally; it must not perform endpoint warming just because there are no peer
%% resolver hints. A cold joiner with no committee has no possible identity confirmation and does need its
%% bootstrap endpoint path.
hint_warm_threshold_test() ->
    ?assertNot(quod_simplex:needs_hint_warm([<<"me">>], <<"me">>)),
    ?assert(quod_simplex:needs_hint_warm([], <<"me">>)).

recovery_failure_revokes_capability_test() ->
    Eng = quod_simplex:eng_with_certs(0, []),
    Pulling = st(#{self => <<"me">>, validators => [<<"me">>], slot => 2,
                   eng => Eng, sync => {pulling, self()}}),
    Failed = quod_simplex:recovery_failed(Pulling),
    ?assertEqual(unconfirmed, quod_simplex:test_sync(Failed)),
    ?assertNot(quod_simplex:may_vote(Failed)).

sink_ownership_test() ->
    Other = spawn(fun() -> receive stop -> ok end end),
    Pulling = st(#{sync => {pulling, self()}}),
    ?assert(quod_simplex:may_sink({recovery, self()}, Pulling)),
    ?assertNot(quod_simplex:may_sink({recovery, Other}, Pulling)),
    ?assertNot(quod_simplex:may_sink({feed, replay}, Pulling)),
    ?assert(quod_simplex:may_sink({feed, live},
                                  st(#{self => <<"me">>, validators => [<<"other">>], sync => ready}))),
    ?assertNot(quod_simplex:may_sink({feed, replay},
                                     st(#{self => <<"me">>, validators => [<<"me">>], sync => ready}))),
    Other ! stop.

%% A settled observer's contiguous push is a real live event. Recovery and anti-entropy
%% windows rebuild D silently and reconcile P once at their explicit ready edge.
feed_apply_origin_test() ->
    ?assertEqual(live, quod_simplex:catchup_origin({feed, live})),
    ?assertEqual(replay, quod_simplex:catchup_origin({feed, replay})),
    ?assertEqual(replay, quod_simplex:catchup_origin({recovery, self()})).

catchup_window_publishes_one_wake_only_certified_head_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Ns = iolist_to_binary(
           [<<"catchup:certified-head:">>,
            integer_to_binary(erlang:unique_integer([positive]))]),
    Anchor = crypto:hash(sha256, Ns),
    Entry = #entry{index = 1, data = noop, timestamp = 1},
    Projection = quod_simplex:history_advance(
                   Ns, Entry, quod_simplex:history_projection()),
    Dir = relay_store_dir("catchup_certified_head"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    quod_reg:subscribe({committed, Ns}),
    try
        Initial = st(#{ns => Ns, genesis_hash => Anchor,
                       store => Store0, slot => 0}),
        {_Recovered, ok} = quod_simplex:test_apply_catchup_window(
                             recovery, [Entry], Projection, Initial),
        receive
            {certified_head, Ns, 1} -> ok
        after 1000 ->
            error(catchup_head_wake_missing)
        end,
        %% Catch-up exposes only the newest durable height. It must never
        %% replay the historical entry as a live commit/event.
        receive
            {committed, Ns, 1, #entry{}} ->
                error(catchup_rebroadcast_historical_entry)
        after 0 ->
            ok
        end
    after
        _ = try quod_reg:unsubscribe({committed, Ns}) catch _:_ -> ok end,
        quod_ledger_store:close(Store0),
        file:del_dir_r(Dir)
    end.

%% Arm pacing (#s.sync_arm): the behind-hysteresis counter, the backoff cooldown countdown, and the
%% arm_ready gate / backoff growth.
sync_arm_pacing_test() ->
    EngIdle = quod_simplex:eng_with_certs(0, []),
    EngBehind = quod_simplex:eng_with_certs(0, [{commit, 20}]),
    Arm = fun(S) -> quod_simplex:test_arm(quod_simplex:pace_tick(S)) end,

    %% pace_tick grows the hysteresis while behind, resets it when not behind, and counts the cooldown down
    ?assertMatch({1, _, _}, Arm(st(#{slot => 2, eng => EngBehind, sync_arm => {0, 0, 0}}))),
    ?assertMatch({0, _, _}, Arm(st(#{slot => 2, eng => EngIdle,   sync_arm => {5, 0, 0}}))),
    ?assertMatch({_, 2, _}, Arm(st(#{slot => 2, eng => EngIdle,   sync_arm => {0, 3, 8}}))),

    %% unconfirmed arms immediately (unless cooling down); ready requires persistent gap evidence
    ?assert(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {0, 0, 0}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => unconfirmed, sync_arm => {0, 1, 4}}))),
    ?assertNot(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {1, 0, 0}}))),
    ?assert(quod_simplex:arm_ready(st(#{sync => ready, sync_arm => {2, 0, 0}}))),

    %% backoff floors then doubles the interval, resets the hysteresis, and sets a positive jittered cooldown
    {BH, BC, BI} = quod_simplex:backoff({7, 0, 0}),
    ?assertEqual(0, BH),
    ?assert(BI >= 3),                              %% floored at ?SYNC_BACKOFF_MIN
    ?assert(BC >= 1),                              %% a positive jittered cooldown
    {_, _, BI2} = quod_simplex:backoff({0, 0, BI}),
    ?assert(BI2 >= BI andalso BI2 =< 20),          %% grows, capped at ?SYNC_BACKOFF_MAX
    ?assertEqual({0, 0, 0}, quod_simplex:reset_pace()).

%% minimal-state builder for the pure gate predicates (the #s record is private to quod_simplex)
st(Overrides) ->
    DomainOverrides =
        case maps:is_key(consensus_domain, Overrides) of
            true  -> Overrides;
            false -> Overrides#{consensus_domain => ?DOMAIN}
        end,
    %% Every founded test committee has the same kind of authoritative view
    %% identity as a live/replayed node. Tests that intentionally model an
    %% unfounded state leave `validators` empty; explicit committee ids win.
    WithCommitteeId =
        case {maps:is_key(committee_id, DomainOverrides),
              maps:get(validators, DomainOverrides, [])} of
            {false, [_ | _]} ->
                DomainOverrides#{
                  committee_id =>
                      crypto:hash(sha256, <<"simplex-test-committee-view">>)};
            _ ->
                DomainOverrides
        end,
    quod_simplex:test_state(WithCommitteeId).

voting_readiness(Peers, LinkPid, Height) ->
    Now = quod_time:mono_ms(),
    maps:from_list([{Peer, {LinkPid, Height, true, Now}} || Peer <- Peers]).

%%%===================================================================
%%% block-timestamp acceptance (the valid_proposal monotonic + future + type gate)
%%%===================================================================

%% Ts must be a non-negative integer, ≥ the parent block time, and ≤ Now + skew. This is the whole
%% Byzantine-timestamp defence, so pin every branch directly (valid_proposal wires it to the live clock).
ts_acceptable_test() ->
    Now  = quod_time:now_ms(),
    Last = Now - 1000,
    ?assert(quod_simplex:ts_acceptable(Now, Last, Now)),          %% normal: monotonic + within skew
    ?assert(quod_simplex:ts_acceptable(Last, Last, Now)),         %% equal to parent is allowed
    ?assertNot(quod_simplex:ts_acceptable(Last - 1, Last, Now)),  %% backwards ⇒ rejected
    ?assertNot(quod_simplex:ts_acceptable(Now + 3 * 60 * 60 * 1000, Last, Now)),  %% >2h future ⇒ rejected
    %% non-integer terms must NOT slip through. A FLOAT is the load-bearing case: numbers compare by
    %% VALUE, so the range check alone would accept Now+0.5 — ONLY the is_integer guard rejects it. The
    %% others (binary/atom/tuple) sort above every integer in term order, so the upper bound also stops them.
    ?assertNot(quod_simplex:ts_acceptable(Now + 0.5, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable(<<"x">>, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable(future, Last, Now)),
    ?assertNot(quod_simplex:ts_acceptable({0}, Last, Now)).

%% The proposal frontier follows notarization, while the durable frontier follows
%% commit. Depth one allows H+2 to open over approved H+1, then applies backpressure.
pipeline_frontier_test() ->
    Eng = quod_simplex:eng_new(?DOMAIN, [<<"self">>], 5),
    Open = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                approved => 5, eng => Eng, sync => ready}),
    ?assertEqual({ok, 6}, quod_simplex:proposal_slot(Open)),
    OneAhead = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                    approved => 6, eng => Eng, sync => ready}),
    ?assertEqual({ok, 7}, quod_simplex:proposal_slot(OneAhead)),
    Full = st(#{self => <<"self">>, validators => [<<"self">>], slot => 5,
                approved => 7, eng => Eng, sync => ready}),
    ?assertEqual(blocked, quod_simplex:proposal_slot(Full)).

%% The watchdog follows the durable head, not the proposal frontier. Notarizing H+1 changes the phase to
%% awaiting_commit and keeps slot H+1 watched while the pipeline may already propose H+2. Connectivity is
%% part of the state so a returning quorum receives a fresh full timeout.
head_progress_state_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Eng0 = quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5),
    Idle = st(#{self => A, validators => pubs(Committee), slot => 5,
                approved => 5, eng => Eng0, sync => ready}),
    ?assertEqual(idle, quod_simplex:test_progress(
                         quod_simplex:reconcile_head_progress(Idle))),

    Requested = st(#{self => A, validators => pubs(Committee), slot => 5,
                     approved => 5, eng => Eng0, sync => ready,
                     head_progress => {6, awaiting_proposal, false}}),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Requested))),

    Inbound = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    Readiness = voting_readiness([B, C], self(), 6),
    Notarized = st(#{self => A, validators => pubs(Committee), slot => 5,
                     approved => 6, eng => Eng0, sync => ready,
                     inbound_conns => Inbound, peer_readiness => Readiness,
                     head_progress => {6, awaiting_notarization, false}}),
    ?assertEqual({6, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Notarized))),

    %% Once slot 6 is durable, the same approved frontier now means slot 7 is the watched finality head.
    Advanced = st(#{self => A, validators => pubs(Committee), slot => 6,
                    approved => 7, eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), 6),
                    sync => ready, inbound_conns => Inbound,
                    peer_readiness => Readiness}),
    ?assertEqual({7, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Advanced))).

%% Demand for the depth-one successor arrives while the durable head is still awaiting commit. Preserve
%% that demand separately; once the parent commits, the successor immediately becomes the watched
%% awaiting-proposal head even if no second client request arrives.
pipelined_demand_survives_parent_finality_test() ->
    Eng = quod_simplex:eng_new(?DOMAIN, [<<"self">>], 5),
    Pipelined = st(#{self => <<"self">>, validators => [<<"self">>],
                     slot => 5, approved => 6, eng => Eng, sync => ready}),
    Requested = quod_simplex:watch_requested(7, Pipelined),
    ?assertEqual(7, quod_simplex:test_requested(Requested)),
    ?assertEqual({6, awaiting_commit, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(Requested))),
    ParentFinal = st(#{self => <<"self">>, validators => [<<"self">>],
                       slot => 6, approved => 6,
                       requested_slot => quod_simplex:test_requested(Requested),
                       eng => quod_simplex:eng_new(?DOMAIN, [<<"self">>], 6), sync => ready}),
    ?assertEqual({7, awaiting_proposal, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(ParentFinal))).

%% A complaint may finalize its slot synchronously before the amplification caller retains the demand.
%% Finalized demand must stay cleared; a genuinely later pipelined request is preserved.
finalized_request_is_not_resurrected_test() ->
    Eng = quod_simplex:eng_new(?DOMAIN, [<<"self">>], 6),
    Final = st(#{self => <<"self">>, validators => [<<"self">>],
                 slot => 6, approved => 6, eng => Eng, sync => ready,
                 requested_slot => 6}),
    Cleared = quod_simplex:watch_requested(6, Final),
    ?assertEqual(none, quod_simplex:test_requested(Cleared)),
    Later = quod_simplex:watch_requested(
              6, st(#{self => <<"self">>, validators => [<<"self">>],
                      slot => 6, approved => 6, eng => Eng, sync => ready,
                      requested_slot => 7})),
    ?assertEqual(7, quod_simplex:test_requested(Later)).

%% A peer counts only after reporting readiness on the authenticated inbound stream that carries its
%% votes. Our own outbound stream may still be opening; that does not hide a peer that can already vote.
inbound_link_counts_toward_quorum_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Inbound = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    S = st(#{self => A, validators => pubs(Committee), slot => 5, approved => 5,
             eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5), sync => ready,
             inbound_conns => Inbound,
             peer_readiness => voting_readiness([B, C], self(), 5),
             head_progress => {6, awaiting_proposal, false}}),
    ?assertEqual({6, awaiting_proposal, true},
                 quod_simplex:test_progress(
                   quod_simplex:reconcile_head_progress(S))).

%% Open authenticated streams alone are not evidence that a restarted peer has recovered enough state to
%% vote. A current-height heartbeat turns the same links into a ready quorum; a behind heartbeat does not.
socket_only_quorum_is_not_ready_test() ->
    [{A, _}, {B, _}, {C, _}, {_D, _}] = Committee = committee(4),
    Links = #{B => {self(), make_ref()}, C => {self(), make_ref()}},
    Common = #{self => A, validators => pubs(Committee), slot => 5, approved => 5,
               eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5), sync => ready,
               inbound_conns => Links, head_progress => {6, awaiting_proposal, false}},
    SocketOnly = quod_simplex:reconcile_head_progress(st(Common)),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(SocketOnly)),
    Behind = quod_simplex:reconcile_head_progress(
               st(Common#{peer_readiness => voting_readiness([B, C], self(), 4)})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(Behind)),
    Now = quod_time:mono_ms(),
    Stale = maps:from_list([{Peer, {self(), 5, true, Now - 3001}} ||
                               Peer <- [B, C]]),
    StaleState = quod_simplex:reconcile_head_progress(
                   st(Common#{peer_readiness => Stale})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(StaleState)),
    OtherLink = spawn(fun() -> receive stop -> ok end end),
    WrongGeneration = voting_readiness([B, C], OtherLink, 5),
    WrongState = quod_simplex:reconcile_head_progress(
                   st(Common#{peer_readiness => WrongGeneration})),
    ?assertEqual({6, awaiting_proposal, false},
                 quod_simplex:test_progress(WrongState)),
    OtherLink ! stop,
    Ready = quod_simplex:reconcile_head_progress(
              st(Common#{peer_readiness => voting_readiness([B, C], self(), 5)})),
    ?assertEqual({6, awaiting_proposal, true},
                 quod_simplex:test_progress(Ready)).

%% Consensus links are committee-scoped. A committed removal drops both directions plus any queued frames
%% and outstanding dial for the departed peer, while preserving the remaining member's transport state.
committee_change_prunes_stale_links_test() ->
    [{A, _}, {B, _}, {C, _}] = committee(3),
    Keep = spawn(fun Loop() -> receive _ -> Loop() end end),
    DropOut = spawn(fun Loop() -> receive _ -> Loop() end end),
    DropIn = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        S = st(#{self => A, validators => [A, B],
                 conns => #{B => {Keep, erlang:monitor(process, Keep)},
                            C => {DropOut, erlang:monitor(process, DropOut)}},
                 inbound_conns => #{B => {Keep, erlang:monitor(process, Keep)},
                                    C => {DropIn, erlang:monitor(process, DropIn)}},
                 outbox => #{B => [<<"keep">>], C => [<<"drop">>]},
                 dialing => #{B => 1, C => 1}}),
        Pruned = quod_simplex:prune_consensus_links(S),
        ?assertEqual({[B], [B], [B], [B]},
                     quod_simplex:test_link_peers(Pruned))
    after
        exit(Keep, kill),
        exit(DropOut, kill),
        exit(DropIn, kill)
    end.

%% Membership pruning uses the same monitored retirement barrier as live
%% generation replacement. Keep the removed process alive after `close` to
%% prove the prune itself does not wait, then re-admit its peer before
%% delivering a queued frame: the tombstone, rather than committee exclusion or
%% process death, is what prevents the retired pid from reclaiming the stream.
committee_prune_retirement_is_nonblocking_and_monotonic_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    Slot = 3,
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    try
        Removed =
            st(#{self => Self, validators => [Self],
                 slot => Slot, approved => Slot, sync => ready,
                 eng => quod_simplex:eng_with_certs(Slot, []),
                 inbound_conns => #{Peer => {OldPid, OldRef}},
                 peer_readiness =>
                     #{Peer =>
                           {OldPid, Slot, true,
                            quod_time:mono_ms()}}}),
        {PruneUs, Pruned} =
            timer:tc(
              fun() ->
                      quod_simplex:prune_consensus_links(Removed)
              end),
        ?assert(PruneUs < 250000),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assertEqual(
           {[], [], [], []},
           quod_simplex:test_link_peers(Pruned)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Pruned)),

        %% Make the peer eligible again before its queued old-generation
        %% readiness arrives. Without the retained tombstone, this live pid
        %% would be adopted and counted as the new generation.
        Readmitted =
            quod_simplex:test_state_set(
              validators, [Self, Peer], Pruned),
        LogChan =
            term_to_binary({log, <<"t">>}, [deterministic]),
        ReadyPayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, true}),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, OldPid},
                 LogChan, ReadyPayload},
                Readmitted)),
        {_OutboundAfterStale, InboundAfterStale,
         _OutboxAfterStale, _DialingAfterStale} =
            quod_simplex:test_link_peers(AfterStale),
        ?assertEqual([], InboundAfterStale),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),

        OldDown =
            release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(
                info, OldDown, AfterStale)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown))
    after
        ensure_stubborn_link_closed(OldPid, OldToken)
    end.

%% Exercise every watchdog decision boundary directly: a ready node with quorum complains, a ready node
%% without quorum pauses, and a recovering node merely probes. Readiness restoration replaces the timer
%% with a fresh full Delta; losing quorum leaves the existing timer untouched.
progress_timeout_branches_test() ->
    [{A, IdA}, {B, _}, {C, _}, {D, _}] = Committee = committee(4),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Eng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5),
        Full = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                 D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        Common = #{self => A, id => IdA, validators => pubs(Committee),
                   slot => 5, approved => 5, eng => Eng,
                   head_progress => {6, awaiting_proposal, true}},
        Complained = quod_simplex:on_progress_timeout(
                       6, st(Common#{sync => ready, inbound_conns => Full,
                                     peer_readiness => Readiness})),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Complained)),
        ?assertEqual({1, 0}, quod_simplex:test_progress_counts(Complained)),

        Sparse = #{B => {Sink, make_ref()}},
        Dialing = #{C => 999999999999, D => 999999999999},
        Paused = quod_simplex:on_progress_timeout(
                   6, st(Common#{sync => ready, inbound_conns => Sparse,
                                 peer_readiness => Readiness, dialing => Dialing,
                                 head_progress => {6, awaiting_proposal, false}})),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Paused)),
        ?assertEqual({1, 1}, quod_simplex:test_progress_counts(Paused)),

        Recovering = quod_simplex:on_progress_timeout(
                       6, st(Common#{sync => unconfirmed, inbound_conns => Sparse,
                                     peer_readiness => Readiness, dialing => Dialing,
                                     head_progress => {6, awaiting_proposal, false}})),
        ?assertEqual({none, false, false}, quod_simplex:test_round(6, Recovering)),
        ?assertEqual({1, 0}, quod_simplex:test_progress_counts(Recovering)),

        Disconnected = st(Common#{sync => ready,
                                  head_progress => {6, awaiting_proposal, false}}),
        Connected = st(Common#{sync => ready,
                               head_progress => {6, awaiting_proposal, true}}),
        ?assertMatch([{{timeout, progress}, _, {progress_timeout, 6}}],
                     quod_simplex:progress_timer_actions(Disconnected, Connected)),
        ?assertEqual([], quod_simplex:progress_timer_actions(Connected, Disconnected))
    after
        exit(Sink, kill)
    end.

%% A valid proposal received while recovery forbids voting is retained without starting a complaint timer.
%% Once ready, the node watches it and its first timeout emits ordinary support rather than skipping it.
ready_after_passive_ingest_supports_before_complaining_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"passive-recovery">>,
                   [{assert, {{recovered, proposal}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        Recovering = st(#{self => A, id => IdA, validators => pubs(Committee),
                          slot => 5, approved => 5, eng => Eng, sync => unconfirmed,
                          inbound_conns => Inbound, peer_readiness => Readiness}),
        ?assertEqual(idle, quod_simplex:test_progress(
                             quod_simplex:reconcile_head_progress(Recovering))),
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => Eng, sync => ready,
                     inbound_conns => Inbound, peer_readiness => Readiness}),
        Watched = quod_simplex:reconcile_head_progress(Ready),
        ?assertEqual({6, awaiting_notarization, true},
                     quod_simplex:test_progress(Watched)),
        Supported = quod_simplex:on_progress_timeout(6, Watched),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Supported))
    after
        exit(Sink, kill)
    end.

%% Live recovery regression: the below-quorum survivors may already have support-signed the retained
%% proposal. When quorum returns, their first timeout must re-echo support and leave complaint unsigned,
%% giving the leader's proposal redrive one Delta to reach a recovered voter. The grace is exactly once:
%% if notarization still does not form, the following timeout may complain and preserve leader-failure
%% liveness.
supported_proposal_gets_one_redrive_before_complaint_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"supported-recovery">>,
                   [{assert, {{recovered, supported}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => Eng, sync => ready,
                     inbound_conns => Inbound,
                     peer_readiness => voting_readiness([B, C, D], Sink, 5),
                     head_progress => {6, awaiting_notarization, true}}),

        Supported = quod_simplex:on_progress_timeout(6, Ready),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Supported)),
        ?assertNot(quod_simplex:test_support_grace(Supported)),

        Retried = quod_simplex:on_progress_timeout(6, Supported),
        ?assertEqual({BH, false, false}, quod_simplex:test_round(6, Retried)),
        ?assert(quod_simplex:test_support_grace(Retried)),

        Complained = quod_simplex:on_progress_timeout(6, Retried),
        ?assertEqual({BH, false, true}, quod_simplex:test_round(6, Complained))
    after
        exit(Sink, kill)
    end.

%% A retained leader proposal must be queued for validators that are not connected yet. The old live-link
%% filter omitted them entirely, so a recovered validator could advertise readiness but never receive the
%% proposal whose support was needed to complete notarization.
redrive_queues_proposal_for_disconnected_validators_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Tx = signed_tx(<<"t">>, <<"redrive-disconnected">>,
                   [{assert, {{recovered, redrive}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    {Eng, []} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5, eng => Eng, sync => ready}),
    Redriven = quod_simplex:test_redrive_head(6, BH, S),
    ?assertEqual({[], [], lists:sort([B, C, D]), lists:sort([B, C, D])},
                 quod_simplex:test_link_peers(Redriven)).

%% A validator that has a support certificate but lost the corresponding block asks one holder at a
%% time. The request itself is tiny; it must not fan a complete block out from every validator.
certified_block_request_targets_one_holder_test() ->
    Committee = [{A, IdA} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"missing-block">>,
                   [{assert, {{recovered, block}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    {Eng, _} = feed_shares(supports(Block, Committee, 3),
                           quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    Missing = st(#{self => A, id => IdA, validators => pubs(Committee),
                   slot => 5, approved => 5, eng => Eng, sync => ready}),

    Requested = quod_simplex:reconcile_block_requests(Missing),
    {[], [], OutboxPeers, DialPeers} = quod_simplex:test_link_peers(Requested),
    ?assertEqual(1, length(OutboxPeers)),
    ?assertEqual(OutboxPeers, DialPeers),
    ?assertEqual(1, map_size(quod_simplex:test_block_requests(Requested))).

%% Any active validator holding both the exact block and its support certificate may answer, but an
%% authenticated non-member cannot use block recovery as an oracle or make the node queue large frames.
certified_block_request_is_committee_scoped_test() ->
    Committee = [{A, IdA}, {B, _} | _] = committee(4),
    Tx = signed_tx(<<"t">>, <<"serve-certified-block">>,
                   [{assert, {{recovered, served}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Holder = st(#{self => B, validators => pubs(Committee), slot => 5,
                  approved => 6, eng => Eng2, sync => ready}),

    Answered = quod_simplex:dispatch(A, {block_request, 6, BH}, Holder),
    ?assertEqual({[], [], [A], [A]}, quod_simplex:test_link_peers(Answered)),
    Outsider = <<"not-a-validator">>,
    Ignored = quod_simplex:dispatch(Outsider, {block_request, 6, BH}, Holder),
    ?assertEqual({[], [], [], []}, quod_simplex:test_link_peers(Ignored)).

%% The responder need not be the original proposer. A quorum support certificate authenticates the exact
%% block hash; the receiver rechecks the bounded block and its transactions before putting it in the tree.
certified_block_from_non_leader_restores_finality_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"non-leader-recovery">>,
                   [{assert, {{recovered, any_holder}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, 6, BH, SupportShares, pubs(Committee)),
    {CertOnly, _} = feed_shares(SupportShares, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    Requester = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 5, eng => CertOnly, sync => ready,
                     block_requests => #{{6, BH} => {1, 0}}}),
    Leader = quod_simplex:leader(6, pubs(Committee)),
    Sender = hd([Peer || {Peer, _} <- Peers, Peer =/= Leader]),

    Restored = quod_simplex:dispatch(Sender, {certified_block, Block, Cert}, Requester),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

%% Certified recovery must classify a DTX batch as controls and retain it in
%% the phase-aware validation round.  Sending it through the generic content
%% engine would install the block without the DTX prerequisite checks.
certified_dtx_block_uses_phase_aware_recovery_test() ->
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    Control = maps:get(begin_control, Fixture),
    {Ns, Anchor} = maps:get(target, Fixture),
    #{pubkey := Self} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    {ok, Envelope} = quod_dtx:encode_control(Control),
    Block = #block{slot = 1, parent = 0,
                   payload = {batch, [{dtx, Envelope}]}, timestamp = 0},
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(
                   ?DOMAIN, support, 1, BH,
                   supports(Block, [{Self, Identity}], 1), [Self]),
    {CertOnly, _} = feed_shares(
                      supports(Block, [{Self, Identity}], 1),
                      quod_simplex:eng_new(?DOMAIN, [Self], 0)),
    S = st(#{ns => Ns, genesis_hash => Anchor,
             self => Self, id => Identity, validators => [Self],
             author_admissions => #{Self => Admission},
             dtx_projection => quod_dtx:initial_projection({Ns, Anchor}, 0),
             slot => 0, approved => 0, eng => CertOnly, sync => ready,
             block_requests => #{{1, BH} => {1, 0}}}),

    Recovered = quod_simplex:dispatch(
                  Self, {certified_block, Block, Cert}, S),
    ?assertMatch({_, _, {_, #block{payload = {batch, [{dtx, _}]}}}, _, _},
                 quod_simplex:test_dtx_round(1, Recovered)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Recovered))).

certified_block_response_requires_outstanding_request_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"unsolicited-certified-block">>,
                   [{assert, {{recovered, requested_only}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    SupportShares = supports(Block, Committee, 3),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, 6, BH, SupportShares,
                                        pubs(Committee)),
    {CertOnly, _} = feed_shares(SupportShares,
                                quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5, eng => CertOnly, sync => ready}),
    Sender = element(1, hd(Peers)),

    Ignored = quod_simplex:dispatch(Sender, {certified_block, Block, Cert}, S),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Ignored)),
    ?assertEqual(1, maps:get(missing_certified_blocks,
                            quod_simplex:stats_map(Ignored))).

%% Supporting one proposal does not bind the later final vote to that losing hash. Once a different block
%% has the unique support quorum, this validator must recover it and join finality; otherwise one leader
%% equivocation can remove an honest validator from the only completable commit camp.
certified_block_recovery_accepts_losing_local_support_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    [{Self, SelfId} | _] = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Leader],
    OtherValidators = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Self],
    Losing = #block{slot = 6, parent = 5,
                    payload = {batch,
                               [signed_tx(<<"t">>, <<"losing-support">>,
                                          [{assert, {{proposal, losing}, true}}],
                                          {Leader, LeaderId})]}},
    Winning = #block{slot = 6, parent = 5,
                     payload = {batch,
                                [signed_tx(<<"t">>, <<"winning-support">>,
                                           [{assert, {{proposal, winning}, true}}],
                                           hd(OtherValidators))]}},
    WinningHash = quod_simplex:block_hash(Winning),
    {ok, WinningCert} = quod_simplex:form_cert(?DOMAIN,
                          support, 6, WinningHash,
                          supports(Winning, OtherValidators, 3), Validators),
    Initial = st(#{self => Self, id => SelfId, validators => Validators,
                   slot => 5, approved => 5,
                   eng => quod_simplex:eng_new(?DOMAIN, Validators, 5), sync => ready}),
    SupportedLosing = quod_simplex:dispatch(
                        Leader, {propose, Losing, []}, Initial),
    LosingHash = quod_simplex:block_hash(Losing),
    ?assertEqual({LosingHash, false, false},
                 quod_simplex:test_round(6, SupportedLosing)),
    HasCertificate = quod_simplex:dispatch(Leader, {cert, WinningCert}, SupportedLosing),
    Requested = quod_simplex:reconcile_block_requests(HasCertificate),
    Sender = element(1, hd(OtherValidators)),

    Restored = quod_simplex:dispatch(
                 Sender, {certified_block, Winning, WinningCert}, Requested),
    ?assertEqual({LosingHash, true, false}, quod_simplex:test_round(6, Restored)),
    ?assertEqual(0, map_size(quod_simplex:test_block_requests(Restored))).

certified_block_hash_mismatch_is_rejected_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Tx = signed_tx(<<"t">>, <<"certified-good">>,
                   [{assert, {{recovered, correct}, true}}], {A, IdA}),
    Block = #block{slot = 6, parent = 5, payload = {batch, [Tx]}},
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN,
                   support, 6, BH, supports(Block, Committee, 3), pubs(Committee)),
    Different = Block#block{timestamp = 1},
    DifferentHash = quod_simplex:block_hash(Different),
    S = st(#{self => A, id => IdA, validators => pubs(Committee),
             slot => 5, approved => 5,
             eng => quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5), sync => ready,
             block_requests => #{{6, DifferentHash} => {1, 0}}}),
    Rejected = quod_simplex:dispatch(element(1, hd(Peers)),
                                     {certified_block, Different, Cert}, S),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Rejected)).

%% Recovery metrics count signatures carried by a verified certificate even when individual share frames
%% were not received, and expose the exact "certificate present, block absent" condition.
recovery_stats_include_certificate_evidence_test() ->
    Committee = [{A, _} | _] = committee(4),
    Block = blk(6),
    BH = quod_simplex:block_hash(Block),
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN,
                   support, 6, BH, supports(Block, Committee, 3), pubs(Committee)),
    {CertOnly, _} = quod_simplex:eng_offer(
                      {cert, Cert}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    Stats = quod_simplex:stats_map(
              st(#{self => A, validators => pubs(Committee), slot => 5,
                   approved => 5, eng => CertOnly, sync => ready})),
    ?assertEqual(3, maps:get(head_support_votes, Stats)),
    ?assertEqual(0, maps:get(head_commit_votes, Stats)),
    ?assertEqual(0, maps:get(head_complaint_votes, Stats)),
    ?assertEqual(1, maps:get(missing_certified_blocks, Stats)).

%% Quorum restoration may grant a few fresh Deltas for transient reconnects, but an unchanged slot/phase
%% eventually exhausts that budget. Further false->true flaps leave the existing deadline untouched.
quorum_restoration_rearm_is_bounded_test() ->
    Common = #{slot => 5, approved => 5, eng => quod_simplex:eng_new(?DOMAIN, [<<"self">>], 5),
               self => <<"self">>, validators => [<<"self">>], sync => ready},
    BelowCap = st(Common#{head_progress => {6, awaiting_proposal, false, 2, true}}),
    Restored = quod_simplex:reconcile_head_progress(BelowCap),
    ?assertEqual(3, quod_simplex:test_progress_rearms(Restored)),
    ?assertNot(quod_simplex:test_support_grace(Restored)),
    ?assertMatch([{{timeout, progress}, _, {progress_timeout, 6}}],
                 quod_simplex:progress_timer_actions(BelowCap, Restored)),
    AtCap = st(Common#{head_progress => {6, awaiting_proposal, false, 3, true}}),
    Capped = quod_simplex:reconcile_head_progress(AtCap),
    ?assertEqual(3, quod_simplex:test_progress_rearms(Capped)),
    ?assert(quod_simplex:test_support_grace(Capped)),
    ?assertEqual([], quod_simplex:progress_timer_actions(AtCap, Capped)),
    NewPhase = st(Common#{approved => 6,
                         head_progress => {6, awaiting_notarization, false, 3, true}}),
    Advanced = quod_simplex:reconcile_head_progress(NewPhase),
    ?assertEqual(0, quod_simplex:test_progress_rearms(Advanced)),
    ?assertNot(quod_simplex:test_support_grace(Advanced)).

%% A block can be notarized while a restarted member is still `unconfirmed`: it is deliberately forbidden
%% to vote, and the engine's one-shot notarized event is consumed. Regaining `ready` must reconstruct the
%% commit latch from the complete tree, otherwise this validator never contributes to finality. It must
%% not invent a support vote: membership support requires a separate local KB verdict.
resume_notarized_after_recovery_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer({block, Block},
                                       quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    ?assert(maps:is_key(6, quod_simplex:eng_tree(Eng2))),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    Conns = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
              D => {Sink, make_ref()}},
    Recovering = st(#{self => A, id => IdA, validators => pubs(Committee),
                      slot => 5, approved => 6, eng => Eng2,
                      sync => unconfirmed, conns => Conns}),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Recovering)),
    ?assertEqual({none, false, false},
                 quod_simplex:test_round(
                   6, quod_simplex:resume_ready_rounds(Recovering))),

    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2,
                 sync => ready, conns => Conns}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)),
    exit(Sink, kill).

%% A recovered validator must not blindly join the commit side of a notarized
%% round when f+1 distinct peers have already complaint-signed the durable
%% head. At N=10, four complaint latches leave at most six commit-eligible
%% validators, so choosing commit would recreate the permanent 4/6 split seen
%% at live slot 6180. Complaint evidence is deliberately below certificate
%% quorum here: this exercises camp selection, not ordinary skip processing.
resume_notarized_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    Complaints = [quod_simplex:make_share(?DOMAIN, complaint, 6, none, Id)
                  || {_Pub, Id} <- take(4, Peers)],
    {Eng3, _} = feed_shares(Complaints, Eng2),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng3, sync => ready}),

    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, false, true}, quod_simplex:test_round(6, Resumed)).

%% Approval does not close complaint amplification. The fourth peer complaint at N=10 is f+1 evidence;
%% an uncommitted head already awaiting final votes must join the skip side instead of freezing a 4/6 split.
awaiting_commit_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    ComplaintShares = [{Pub, quod_simplex:make_share(?DOMAIN, complaint, 6, none, Id)}
                       || {Pub, Id} <- take(4, Peers)],
    Prefix = [Share || {_Pub, Share} <- take(3, ComplaintShares)],
    {Eng3, _} = feed_shares(Prefix, Eng2),
    [{LastPeer, LastShare}] = lists:nthtail(3, ComplaintShares),
    AwaitingCommit = st(#{self => A, id => IdA, validators => pubs(Committee),
                          slot => 5, approved => 6, eng => Eng3, sync => ready,
                          head_progress => {6, awaiting_commit, true}}),

    Joined = quod_simplex:dispatch(LastPeer, {share, LastShare}, AwaitingCommit),
    ?assertEqual({none, false, true}, quod_simplex:test_round(6, Joined)).

%% Final-vote ownership covers the complete depth-one pipeline, not only committed+1. A child already
%% notarized over the head must join amplified skip evidence immediately; its skip is buffered until the
%% parent finalizes, but the two slots do not need serial evidence collection.
pipelined_child_joins_amplified_complaint_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Parent = blk(6),
    Child = blk(7),
    {E1, _} = quod_simplex:eng_offer(
                {block, Parent}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, Child}, E1),
    {E3, _} = feed_shares(supports(Parent, Committee, 7), E2),
    {E4, _} = feed_shares(supports(Child, Committee, 7), E3),
    ComplaintShares = [{Pub, quod_simplex:make_share(?DOMAIN, complaint, 7, none, Id)}
                       || {Pub, Id} <- take(4, Peers)],
    Prefix = [Share || {_Pub, Share} <- take(3, ComplaintShares)],
    {E5, _} = feed_shares(Prefix, E4),
    [{LastPeer, LastShare}] = lists:nthtail(3, ComplaintShares),
    Pipelined = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 7, eng => E5, sync => ready}),

    Joined = quod_simplex:dispatch(LastPeer, {share, LastShare}, Pipelined),
    ?assertEqual({none, false, true}, quod_simplex:test_round(7, Joined)),
    ?assertEqual({none, false, false}, quod_simplex:test_round(6, Joined)).

%% At most f peer complaints cannot steer an unlatched validator away from a notarized block. This pins
%% the threshold so Byzantine validators alone cannot force the honest committee onto the skip side.
resume_notarized_commits_below_complaint_amplification_test() ->
    Committee = [{A, IdA} | Peers] = committee(10),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 7), Eng1),
    Complaints = [quod_simplex:make_share(?DOMAIN, complaint, 6, none, Id)
                  || {_Pub, Id} <- take(3, Peers)],
    {Eng3, _} = feed_shares(Complaints, Eng2),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng3, sync => ready}),

    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)).

%% Live commit/skip self-corroboration can restore voting between periodic ticks. The common transition
%% hook must reconcile an already-notarized successor immediately on that false->true capability edge.
live_finality_ready_edge_resumes_successor_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    Block = blk(6),
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Before = st(#{self => A, id => IdA, validators => pubs(Committee),
                  slot => 5, approved => 6, eng => Eng2, sync => unconfirmed}),
    After = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2, sync => ready}),
    Settled = quod_simplex:settle_readiness(Before, After),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Settled)).

%% The recovery fold snapshots slot numbers. An earlier iteration can commit and prune a buffered successor;
%% revisiting that stale snapshot entry must be a no-op rather than maps:get(tree_hashes) crashing the statem.
resume_stale_snapshot_slot_is_skipped_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    [{A, IdA}] = Committee = committee(1),
    B6 = blk(6),
    B7 = blk(7),
    {E1, _} = quod_simplex:eng_offer(
                {block, B6}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, B7}, E1),
    {E3, _} = feed_shares(supports(B6, Committee, 1) ++
                          supports(B7, Committee, 1), E2),
    B7Hash = quod_simplex:block_hash(B7),
    B7Commit = quod_simplex:make_share(?DOMAIN, commit, 7, B7Hash, IdA),
    {ok, B7Cert} = quod_simplex:form_cert(?DOMAIN,
                     commit, 7, B7Hash, [B7Commit], pubs(Committee)),
    Eng = quod_simplex:eng_buffered_commit(7, B7, B7Cert, E3),
    Dir = filename:join(
            "/tmp", "quod_resume_snapshot_" ++
                    integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"t">>, Dir),
    Prefix = [#entry{index = I, data = noop, timestamp = I} ||
                 I <- lists:seq(1, 5)],
    {ok, Store1} = quod_ledger_store:append(Store0, Prefix),
    try
        Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                     slot => 5, approved => 7, eng => Eng, sync => ready,
                     store => Store1, last_applied => 5,
                     commit_buf => #{7 => {commit, B7}}}),
        Resumed = quod_simplex:resume_ready_rounds(Ready),
        {7, FinalStore} = quod_simplex:test_committed_store(Resumed),
        ?assertMatch({ok, #entry{index = 6}},
                     quod_ledger_store:read_at(FinalStore, 6)),
        ?assertMatch({ok, #entry{index = 7}},
                     quod_ledger_store:read_at(FinalStore, 7))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% More than one notarized entry may be present when recovery grants voting capability. Reconcile every
%% still-live tree slot, but create final-vote latches only; no synthetic support vote is permitted.
resume_multiple_notarized_slots_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    B6 = blk(6),
    B7 = blk(7),
    {E1, _} = quod_simplex:eng_offer({block, B6},
                                     quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {E2, _} = quod_simplex:eng_offer({block, B7}, E1),
    {E3, _} = feed_shares(supports(B6, Committee, 3), E2),
    {E4, _} = feed_shares(supports(B7, Committee, 3), E3),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 7, eng => E4, sync => ready}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)),
    ?assertEqual({none, true, false}, quod_simplex:test_round(7, Resumed)).

%% Membership proposals use the same final-vote recovery but retain their stricter support boundary:
%% recovery may commit a quorum-notarized block and must never manufacture the skipped local KB verdict.
resume_membership_notarization_does_not_support_test() ->
    Committee = [{A, IdA}, {_, _}, {_, _}, {_, _}] = committee(4),
    {E, _NewId} = id(),
    Membership = signed_tx(<<"t">>, <<"recovery-membership">>, [pa(E)], {A, IdA}),
    Block = #block{slot = 6, parent = 5,
                   payload = {batch, [Membership]}},
    {Eng1, _} = quod_simplex:eng_offer(
                  {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Eng2, _} = feed_shares(supports(Block, Committee, 3), Eng1),
    Ready = st(#{self => A, id => IdA, validators => pubs(Committee),
                 slot => 5, approved => 6, eng => Eng2, sync => ready}),
    Resumed = quod_simplex:resume_ready_rounds(Ready),
    ?assertEqual({none, true, false}, quod_simplex:test_round(6, Resumed)).

%% A restart reloads the validator's own final-vote decision before recovery sees network evidence. A
%% notarized block therefore cannot recruit a validator that complaint-signed this slot before crashing.
restart_preserves_complaint_latch_test() ->
    Committee = [{A, IdA}, {B, _}, {C, _}, {D, _}] = committee(4),
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    Dir = filename:join("/tmp", "quod_simplex_vote_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           <<"t">>, ?DOMAIN, Dir),
        Inbound = #{B => {Sink, make_ref()}, C => {Sink, make_ref()},
                    D => {Sink, make_ref()}},
        Readiness = voting_readiness([B, C, D], Sink, 5),
        EmptyEng = quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 5, eng => EmptyEng, sync => ready,
                           signing_journal => Journal0,
                           inbound_conns => Inbound, peer_readiness => Readiness,
                           head_progress => {6, awaiting_proposal, true}}),
        Complained = quod_simplex:on_progress_timeout(6, BeforeCrash),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Complained)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Complained)),

        Block = blk(6),
        {E1, _} = quod_simplex:eng_offer(
                    {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
        {Notarized, _} = feed_shares(supports(Block, Committee, 3), E1),
        {ok, Journal1} = quod_signing_journal:recover(
                           <<"t">>, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => Notarized, sync => ready,
                           signing_journal => Journal1})),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, Restarted)),
        AfterRestart = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, false, true}, quod_simplex:test_round(6, AfterRestart)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(AfterRestart))
    after
        exit(Sink, kill),
        file:del_dir_r(Dir)
    end.

%% The opposite final camp is equally durable. Once recovery commit-signs a notarized block, reopening the
%% journal must keep later amplified complaint evidence from moving this validator to the skip side.
restart_preserves_commit_latch_test() ->
    Committee = [{A, IdA} | Peers] = committee(4),
    Block = blk(6),
    {E1, _} = quod_simplex:eng_offer(
                {block, Block}, quod_simplex:eng_new(?DOMAIN, pubs(Committee), 5)),
    {Notarized, _} = feed_shares(supports(Block, Committee, 3), E1),
    Dir = filename:join("/tmp", "quod_simplex_commit_restart_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           <<"t">>, ?DOMAIN, Dir),
        BeforeCrash = st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => Notarized, sync => ready,
                           signing_journal => Journal0}),
        Committed = quod_simplex:resume_ready_rounds(BeforeCrash),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Committed)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Committed)),

        Complaints = [quod_simplex:make_share(?DOMAIN, complaint, 6, none, Id)
                      || {_Pub, Id} <- take(2, Peers)],
        {WithComplaints, _} = feed_shares(Complaints, Notarized),
        {ok, Journal1} = quod_signing_journal:recover(
                           <<"t">>, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{self => A, id => IdA, validators => pubs(Committee),
                           slot => 5, approved => 6, eng => WithComplaints, sync => ready,
                           signing_journal => Journal1})),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, Restarted)),
        StillCommitted = quod_simplex:resume_ready_rounds(Restarted),
        ?assertEqual({none, true, false}, quod_simplex:test_round(6, StillCommitted)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(StillCommitted))
    after
        file:del_dir_r(Dir)
    end.

%% An effect transaction crosses a second hard crash boundary after the
%% effect journal has handed it to Simplex: the exact signed submission must
%% be datasync'd in the signing journal before custody is acknowledged.  A
%% restart restores those bytes, rather than rebuilding or re-signing the
%% transaction, so the original OutcomeRef remains the only public identity.
restart_restores_exact_effect_custody_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    {Author, Identity} = id(),
    Admission = quod_simplex:test_author_admission(Author),
    EffectId = crypto:hash(sha256, <<"effect-restart-id">>),
    TargetAnchor = crypto:hash(sha256, <<"effect-restart-target">>),
    RequestDigest = crypto:hash(sha256, <<"effect-restart-request">>),
    PreparedDigest = crypto:hash(sha256, <<"effect-restart-prepared">>),
    {ok, Goal} = quod_durable_term:encode_goal(
                   {create_ontology, <<"restart:created">>, []}),
    {ok, Result} = quod_durable_term:encode_result(#{}),
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create, EffectId, Author,
              {node, Author}, {<<"restart:created">>, TargetAnchor},
              RequestDigest, PreparedDigest},
    Unsigned = quod_transaction:bind_id(
                 {Ns, Anchor},
                 #transaction{origin = {Ns, Anchor},
                              proof_id = crypto:hash(
                                           sha256, <<"effect-proof">>),
                              plan_digest = crypto:hash(
                                              sha256, <<"effect-plan">>),
                              goal = Goal, result = Result,
                              diff = [], read_check = #{},
                              effects = [Effect], author = Author,
                              author_seq = 1, submitted_at = 1234,
                              sig = none}),
    {ok, Signed, Submission} = quod_transaction:sign_submission(
                                 {Ns, Anchor, Admission},
                                 Unsigned, Identity),
    TxId = Signed#transaction.tx_id,
    SubmissionId = quod_transaction:submission_id(Submission),
    Dir = filename:join(
            "/tmp", "quod_effect_custody_restart_" ++
                        integer_to_list(
                          erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1} = quod_signing_journal:record_transaction(
                           Journal0, Signed, Submission, ready),
        ok = quod_signing_journal:close(Journal1),

        {ok, Journal2} = quod_signing_journal:recover(
                           Ns, ?DOMAIN, Dir),
        Restarted = quod_simplex:restore_signing_state(
                      st(#{ns => Ns, self => Author, id => Identity,
                           validators => [Author],
                           author_admissions => #{Author => Admission},
                           signing_journal => Journal2,
                           sync => ready})),
        [{SubmissionId, 1, RestoredSubmission, ready,
          _NoExpiry, 0}] = quod_simplex:test_custody(Restarted),
        ?assertEqual(Submission, RestoredSubmission),
        ?assertMatch(
           #{TxId := #{admission := Admission, sequence := 1}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restarted))),

        %% Live commit retirement is keyed by semantic TxId, not by the
        %% shorter transport submission id.  It must clear custody in the
        %% same turn even when no ordinary custody/relay waiter exists.
        Committed = quod_simplex:test_resolve_committed_submissions(
                      {batch, [Signed]}, 2, Restarted),
        ?assertEqual(
           #{},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Committed))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Committed))
    after
        file:del_dir_r(Dir)
    end.

%% Dormant source custody is process-owned until the proof either activates it
%% or explicitly asks the same custody owner to cancel it. If that proof dies,
%% its exact monitor starts one cancellation coordinator from the retained
%% signed Submission; no timeout or second cleanup registry is involved.
dormant_operation_owner_down_starts_exact_cancellation_test() ->
    {Dir, Fixture, Owner, TxId, S1} =
        registered_dormant_operation("owner_down"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner, OwnerMonitor},
      placement := dormant} = quod_simplex:test_custody_owner(TxId, S1),
    try
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_dormant_owner_down)
        end,
        {true, Cancelling} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor, Owner, S1, Start),
        CancelPid = receive
            {cancellation_started, Submission, Pid, _CancelMonitor} ->
                ?assertEqual(maps:get(submission, Fixture), Submission),
                ?assert(is_process_alive(Pid)),
                Pid
        after 1000 -> error(cancellation_not_started)
        end,
        ?assertMatch(
           #{placement := cancelling, dormant_owner := none},
           quod_simplex:test_custody_owner(TxId, Cancelling)),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ?assertEqual(not_found,
                     quod_simplex:test_custody_owner(TxId, Settled)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% The stored proof-worker PID owns the dormant transition, and the spawned
%% cancellation PID alone may retire it. Knowing the semantic TxId is not a
%% capability to bind, activate, or erase the durable signing row.
dormant_operation_transitions_require_exact_process_owner_test() ->
    {Dir, _Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("wrong_owner"),
    Intruder = spawn(fun validation_owner/0),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    try
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_activate_dormant_transaction(
             TxId, {Intruder, make_ref()}, Dormant)),
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_start_dormant_transaction_cancellation(
             TxId, Intruder, Dormant, Start)),
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_cancel_dormant_transaction(
             TxId, Owner, Dormant)),
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Dormant))),
        ?assertMatch(
           #{placement := dormant, dormant_owner := {Owner, _}},
           quod_simplex:test_custody_owner(TxId, Dormant)),

        {ok, Cancelling} =
            quod_simplex:test_start_dormant_transaction_cancellation(
              TxId, Owner, Dormant, Start),
        CancelPid = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(exact_owner_cancellation_not_started)
        end,
        ?assertMatch(
           {error, not_in_charge, _},
           quod_simplex:test_cancel_dormant_transaction(
             TxId, Intruder, Cancelling)),
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Cancelling))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ?assertEqual(not_found,
                     quod_simplex:test_custody_owner(TxId, Settled)),
        ?assertEqual(
           #{}, quod_signing_journal:pending_transactions(
                  quod_simplex:test_signing_journal(Settled))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        ensure_process_stopped(Intruder),
        file:del_dir_r(Dir)
    end.

%% An admission generation change makes every old source signature unusable,
%% but it does not prove that the remote target forgot its private operation
%% row. Every volatile source placement therefore converges on the same sole
%% cancellation owner; the durable signing row survives until that owner
%% receives a correlated terminal target reply.
admission_change_cancels_remote_operation_from_every_placement_test() ->
    lists:foreach(
      fun(PlacementKind) ->
          {Dir, Fixture, Owner, TxId, Dormant} =
              registered_dormant_operation(
                "admission_" ++ atom_to_list(PlacementKind)),
          #{pubkey := Author} = maps:get(source_identity, Fixture),
          OldAdmission = maps:get(admission, Fixture),
          NewAdmission = crypto:hash(
                           sha256,
                           term_to_binary(
                             {new_admission, PlacementKind},
                             [deterministic])),
          try
              Placed = operation_custody_placement(
                         PlacementKind, Owner, TxId, Dormant),
              BeforeState = case PlacementKind of
                                dormant -> dormant;
                                _ -> ready
                            end,
              ?assertMatch(
                 #{TxId := #{state := BeforeState}},
                 quod_signing_journal:pending_transactions(
                   quod_simplex:test_signing_journal(Placed))),
              Cancelling = quod_simplex:test_retire_changed_admissions(
                             #{Author => OldAdmission},
                             #{Author => NewAdmission}, Placed),
              {Reconciled, _PendingTransition} =
                  quod_simplex:test_reconcile_signing_state(
                    quod_simplex:test_set_author_admissions(
                      #{Author => NewAdmission}, Cancelling)),
              #{placement := cancelling,
                cancellation_owner := CancelPid} =
                  quod_simplex:test_custody_owner(TxId, Reconciled),
              ?assert(is_process_alive(CancelPid)),
              ?assertEqual(
                 0, maps:get(custody_ready,
                             quod_simplex:stats_map(Reconciled))),
              ?assertMatch(
                 #{TxId := #{state := BeforeState}},
                 quod_signing_journal:pending_transactions(
                   quod_simplex:test_signing_journal(Reconciled))),
              {ok, Settled} =
                  quod_simplex:test_cancel_dormant_transaction(
                    TxId, CancelPid, Reconciled),
              ?assertEqual(
                 #{}, quod_signing_journal:pending_transactions(
                        quod_simplex:test_signing_journal(Settled))),
              ok = quod_signing_journal:close(
                     quod_simplex:test_signing_journal(Settled))
          after
              ensure_process_stopped(Owner),
              file:del_dir_r(Dir)
          end
      end, [dormant, ready, local, relay]).

operation_custody_placement(dormant, _Owner, _TxId, S) ->
    S;
operation_custody_placement(Kind, Owner, TxId, Dormant) ->
    {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                    TxId, {Owner, make_ref()}, Dormant),
    case Kind of
        ready -> Ready;
        local ->
            {ok, Local} = quod_simplex:test_place_transaction_custody(
                            TxId, {local, 2, <<241:256>>}, Ready),
            Local;
        relay ->
            {ok, Relay} = quod_simplex:test_place_transaction_custody(
                            TxId,
                            {relay, <<242:128>>, <<243:256>>, 2, <<244:256>>},
                            Ready),
            Relay
    end.

%% Activation and owner death are serialized by Simplex. Whichever message is
%% handled first decides the only legal next state: activation removes the
%% monitor, while a consumed DOWN moves custody to cancelling and makes later
%% activation fail closed.
dormant_operation_activation_vs_owner_down_is_serialized_test() ->
    {Dir1, _Fixture1, Owner1, TxId1, Dormant1} =
        registered_dormant_operation("activate_first"),
    #{dormant_owner := {Owner1, OwnerMonitor1}} =
        quod_simplex:test_custody_owner(TxId1, Dormant1),
    NeverStart =
        fun(_Ns, _Submission) -> error(unexpected_cancellation_start) end,
    try
        {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                        TxId1, {Owner1, make_ref()}, Dormant1),
        ?assertMatch(#{placement := ready, dormant_owner := none},
                     quod_simplex:test_custody_owner(TxId1, Ready)),
        exit(Owner1, kill),
        ?assertEqual(
           false,
           quod_simplex:test_restart_dormant_custody_owner(
             OwnerMonitor1, Owner1, Ready, NeverStart)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Ready))
    after
        ensure_process_stopped(Owner1),
        file:del_dir_r(Dir1)
    end,

    {Dir2, _Fixture2, Owner2, TxId2, Dormant2} =
        registered_dormant_operation("down_first"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner2, OwnerMonitor2}} =
        quod_simplex:test_custody_owner(TxId2, Dormant2),
    try
        exit(Owner2, kill),
        receive
            {'DOWN', OwnerMonitor2, process, Owner2, _} -> ok
        after 1000 -> error(missing_down_first_owner_down)
        end,
        {true, Cancelling} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor2, Owner2, Dormant2, Start),
        CancelPid2 = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(down_first_cancellation_not_started)
        end,
        ?assertMatch(
           {error, already_active, _},
           quod_simplex:test_activate_dormant_transaction(
              TxId2, {self(), make_ref()}, Cancelling)),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId2, CancelPid2, Cancelling),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner2),
        file:del_dir_r(Dir2)
    end.

%% A cancellation worker owns no durable truth. If it crashes, its exact
%% monitor recreates that one worker from the same retained Submission, and an
%% explicit concurrent cancellation request observes the existing owner
%% instead of spawning another one.
dormant_operation_cancellation_worker_crash_restarts_once_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("cancel_restart"),
    Parent = self(),
    Start = cancellation_test_starter(Parent),
    #{dormant_owner := {Owner, OwnerMonitor}} =
        quod_simplex:test_custody_owner(TxId, Dormant),
    try
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_restart_owner_down)
        end,
        {true, Cancelling1} =
            quod_simplex:test_restart_dormant_custody_owner(
              OwnerMonitor, Owner, Dormant, Start),
        {CancelPid1, CancelMonitor1} =
            receive
                {cancellation_started, Submission1, Pid1, Monitor1} ->
                    ?assertEqual(maps:get(submission, Fixture), Submission1),
                    {Pid1, Monitor1}
            after 1000 -> error(first_cancellation_not_started)
            end,
        exit(CancelPid1, kill),
        receive
            {'DOWN', CancelMonitor1, process, CancelPid1, _} -> ok
        after 1000 -> error(missing_cancellation_worker_down)
        end,
        {true, Cancelling2} =
            quod_simplex:test_restart_dormant_custody_owner(
              CancelMonitor1, CancelPid1, Cancelling1, Start),
        CancelPid2 = receive
            {cancellation_started, Submission2, Pid2, _Monitor2} ->
                ?assertEqual(maps:get(submission, Fixture), Submission2),
                ?assert(CancelPid1 =/= Pid2),
                Pid2
        after 1000 -> error(replacement_cancellation_not_started)
        end,
        {ok, Same} = quod_simplex:test_start_dormant_transaction_cancellation(
                       TxId, CancelPid2, Cancelling2, Start),
        ?assertEqual(quod_simplex:test_custody(Cancelling2),
                     quod_simplex:test_custody(Same)),
        receive
            {cancellation_started, _, _, _} ->
                error(duplicate_cancellation_owner)
        after 0 -> ok
        end,
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid2, Same),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% A hard restart has no proof-worker PID to monitor. A persisted dormant row
%% therefore reconstructs directly as cancelling, never as an inert tombstone.
restart_reconstructs_dormant_operation_cancellation_owner_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("restart_cancel"),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    #{dormant_owner := {Owner, OwnerMonitor}, placement := dormant} =
        quod_simplex:test_custody_owner(TxId, Dormant),
    try
        ?assertMatch(
           #{TxId := #{state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Dormant))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Dormant)),
        exit(Owner, kill),
        receive
            {'DOWN', OwnerMonitor, process, Owner, _} -> ok
        after 1000 -> error(missing_restart_registration_owner_down)
        end,
        {ok, Journal} = quod_signing_journal:recover(Ns, ?DOMAIN, Dir),
        NewAdmission = crypto:hash(
                         sha256,
                         term_to_binary(
                           {restart_new_admission, Admission},
                           [deterministic])),
        BeforeRestore = st(#{ns => Ns, genesis_hash => Anchor,
                             self => Author, id => Identity,
                             validators => [Author],
                             author_admissions => #{Author => NewAdmission},
                             signing_journal => Journal, sync => ready,
                             eng => quod_simplex:eng_with_certs(0, [])}),
        {Reconciled, _PendingTransition} =
            quod_simplex:test_reconcile_signing_state(BeforeRestore),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Reconciled))),
        Restored = quod_simplex:restore_signing_state(Reconciled),
        #{placement := cancelling, dormant_owner := none,
          cancellation_owner := CancelPid} =
            quod_simplex:test_custody_owner(TxId, Restored),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := dormant}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restored))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Restored),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% A target-bound operation that was ready under an earlier admission cannot
%% re-enter consensus after re-admission. Recovery still verifies its exact old
%% signature, but restores it under cancellation rather than the ready queue.
restart_with_changed_admission_cancels_ready_operation_test() ->
    {Dir, Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("restart_ready_new_admission"),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    try
        {ok, Ready} = quod_simplex:test_activate_dormant_transaction(
                        TxId, {Owner, make_ref()}, Dormant),
        ?assertMatch(
           #{TxId := #{state := ready}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Ready))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Ready)),
        exit(Owner, kill),
        {ok, Journal} = quod_signing_journal:recover(Ns, ?DOMAIN, Dir),
        NewAdmission = crypto:hash(
                         sha256,
                         term_to_binary(
                           {restart_ready_new_admission, Admission},
                           [deterministic])),
        BeforeRestore = st(#{ns => Ns, genesis_hash => Anchor,
                             self => Author, id => Identity,
                             validators => [Author],
                             author_admissions => #{Author => NewAdmission},
                             signing_journal => Journal, sync => ready,
                             eng => quod_simplex:eng_with_certs(0, [])}),
        {Reconciled, _PendingTransition} =
            quod_simplex:test_reconcile_signing_state(BeforeRestore),
        Restored = quod_simplex:restore_signing_state(Reconciled),
        #{placement := cancelling,
          cancellation_owner := CancelPid} =
            quod_simplex:test_custody_owner(TxId, Restored),
        ?assertEqual(
           0, maps:get(custody_ready, quod_simplex:stats_map(Restored))),
        ?assertMatch(
           #{TxId := #{admission := Admission, state := ready}},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Restored))),
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Restored),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% Dormant/cancelling custody is a prerequisite lifecycle, not consensus-lane
%% work. Lane retirement and catch-up exclusion must preserve it rather than
%% silently enqueueing the source claim before its target prerequisite exists.
dormant_operation_is_not_released_by_lane_or_catchup_reconciliation_test() ->
    {Dir, _Fixture, Owner, TxId, Dormant} =
        registered_dormant_operation("lane_reconcile"),
    try
        LaneRetired = quod_simplex:test_mark_custody_lane_ready(Dormant),
        ?assertMatch(#{placement := dormant},
                     quod_simplex:test_custody_owner(TxId, LaneRetired)),
        Recovered = quod_simplex:test_settle_recovery_custody(
                      100, #{}, LaneRetired),
        ?assertMatch(#{placement := dormant},
                     quod_simplex:test_custody_owner(TxId, Recovered)),
        Parent = self(),
        Start = cancellation_test_starter(Parent),
        {ok, Cancelling} =
            quod_simplex:test_start_dormant_transaction_cancellation(
              TxId, Owner, Recovered, Start),
        CancelPid = receive
            {cancellation_started, _Submission, Pid, _Monitor} -> Pid
        after 1000 -> error(lane_reconcile_cancellation_not_started)
        end,
        {ok, Settled} =
            quod_simplex:test_cancel_dormant_transaction(
              TxId, CancelPid, Cancelling),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Settled))
    after
        ensure_process_stopped(Owner),
        file:del_dir_r(Dir)
    end.

%% Catch-up must retire the same durable signing row as a live commit. Merely
%% removing the volatile custody record would let the next restart restore and
%% re-drive an effect transaction that is already in certified history.
catchup_commit_retires_effect_signing_custody_test() ->
    Ns = <<"effect:catchup-retirement">>,
    Anchor = crypto:hash(sha256, <<"effect-catchup-anchor">>),
    {Author, Identity} = id(),
    Admission = quod_simplex:test_author_admission(Author),
    CommitteeId = crypto:hash(sha256, <<"effect-catchup-committee">>),
    {Signed, Submission} = effect_submission_fixture(
                             Ns, Anchor, Admission, 1,
                             Author, Identity),
    TxId = Signed#transaction.tx_id,
    Entry = #entry{index = 1, data = {batch, [Signed]}, timestamp = 1},
    Projection = quod_simplex:history_projection(
                   [Author], CommitteeId, #{Author => Admission},
                   #{Author => 1}, 1),
    Dir = filename:join(
            "/tmp", "quod_effect_catchup_retirement_" ++
                        integer_to_list(
                          erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        {ok, Journal1} = quod_signing_journal:record_transaction(
                           Journal0, Signed, Submission, ready),
        {ok, Store0} = quod_ledger_store:open(Ns, Dir),
        Restored = quod_simplex:restore_signing_state(
                     st(#{ns => Ns, genesis_hash => Anchor,
                          self => Author, id => Identity,
                          validators => [Author],
                          author_admissions => #{Author => Admission},
                          signing_journal => Journal1,
                          store => Store0, slot => 0, sync => ready})),
        ?assertMatch(#{TxId := #{}},
                     quod_signing_journal:pending_transactions(
                       quod_simplex:test_signing_journal(Restored))),
        {Recovered, ok} = quod_simplex:test_apply_catchup_window(
                            recovery, [Entry], Projection, Restored),
        ?assertEqual([], quod_simplex:test_custody(Recovered)),
        ?assertEqual(
           #{},
           quod_signing_journal:pending_transactions(
             quod_simplex:test_signing_journal(Recovered))),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Recovered)),
        {_Slot, Store1} = quod_simplex:test_committed_store(Recovered),
        ok = quod_ledger_store:close(Store1)
    after
        file:del_dir_r(Dir)
    end.

%% More than one full journal capacity of sequential effect commits must not
%% accumulate signing custody.  Each committed semantic TxId retires before
%% the next lifecycle transaction is signed.
effect_custody_does_not_saturate_after_live_commits_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    {Author, Identity} = id(),
    Admission = quod_simplex:test_author_admission(Author),
    Dir = filename:join(
            "/tmp", "quod_effect_custody_capacity_" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Journal0} = quod_signing_journal:initialize(
                           Ns, ?DOMAIN, Dir),
        S0 = st(#{ns => Ns, self => Author, id => Identity,
                  validators => [Author],
                  author_admissions => #{Author => Admission},
                  signing_journal => Journal0, sync => ready}),
        Final =
            lists:foldl(
              fun(Sequence, S) ->
                  {Signed, Submission} = effect_submission_fixture(
                                           Ns, Anchor, Admission,
                                           Sequence, Author, Identity),
                  {ok, Journal1} = quod_signing_journal:record_transaction(
                                     quod_simplex:test_signing_journal(S),
                                     Signed, Submission, ready),
                  S1 = quod_simplex:test_state_set(
                         signing_journal, Journal1, S),
                  S2 = quod_simplex:test_resolve_committed_submissions(
                         {batch, [Signed]}, Sequence + 1, S1),
                  ?assertEqual(
                     #{},
                     quod_signing_journal:pending_transactions(
                       quod_simplex:test_signing_journal(S2))),
                  S2
              end,
              S0, lists:seq(1, 65)),
        ok = quod_signing_journal:close(
               quod_simplex:test_signing_journal(Final))
    after
        file:del_dir_r(Dir)
    end.

effect_submission_fixture(Ns, Anchor, Admission, Sequence,
                          Author, Identity) ->
    Effect = {quod_direct_effect, 2, local_durable,
              ontology_lifecycle, create,
              crypto:hash(sha256, <<"effect-id", Sequence:64>>), Author,
              {node, Author},
              {<<"capacity:test">>,
               crypto:hash(sha256, <<"effect-target", Sequence:64>>)},
              crypto:hash(sha256, <<"effect-request", Sequence:64>>),
              crypto:hash(sha256, <<"effect-prepared", Sequence:64>>)},
    Unsigned = quod_transaction:bind_id(
                 {Ns, Anchor},
                 #transaction{origin = {Ns, Anchor},
                              proof_id = crypto:hash(
                                           sha256,
                                           <<"effect-proof", Sequence:64>>),
                              plan_digest = crypto:hash(
                                              sha256,
                                              <<"effect-plan", Sequence:64>>),
                              goal = durable_goal(
                                       {create_ontology,
                                        <<"capacity:test">>, []}),
                              result = durable_result(),
                              diff = [], read_check = #{}, effects = [Effect],
                              author = Author, author_seq = Sequence,
                              submitted_at = Sequence, sig = none}),
    {ok, Signed, Submission} = quod_transaction:sign_submission(
                                 {Ns, Anchor, Admission},
                                 Unsigned, Identity),
    {Signed, Submission}.

%% Drive the repaired liveness path through the state-machine boundary: f+1 peer complaints for an already
%% notarized head recruit this validator, its durable share completes the skip certificate, the noop is
%% appended, and the rotated slot then accepts and commits a normal signed transaction. This is the complete
%% join -> skip -> continue guarantee rather than three isolated predicate assertions.
amplified_complaint_skips_and_next_slot_commits_test() ->
    {ok, _} = application:ensure_all_started(gproc),
    Committee = [{Self, SelfId} | Peers] = committee(4),
    Validators = pubs(Committee),
    SkippedBlock = blk(6),
    {E1, _} = quod_simplex:eng_offer(
                {block, SkippedBlock}, quod_simplex:eng_new(?DOMAIN, Validators, 5)),
    {Notarized, _} = feed_shares(supports(SkippedBlock, Committee, 3), E1),
    [FirstComplainer, SecondComplainer | _] = Peers,
    FirstShare = complaint_share(6, FirstComplainer),
    {WithOneComplaint, _} = feed_shares([FirstShare], Notarized),
    SecondShare = complaint_share(6, SecondComplainer),
    Dir = filename:join("/tmp", "quod_finality_continue_" ++
                                integer_to_list(erlang:unique_integer([positive]))),
    {ok, Store0} = quod_ledger_store:open(<<"t">>, Dir),
    Prefix = [#entry{index = I, data = noop, timestamp = I}
              || I <- lists:seq(1, 5)],
    {ok, Store1} = quod_ledger_store:append(Store0, Prefix),
    {ok, Journal0} = quod_signing_journal:initialize(
                       <<"t">>, ?DOMAIN, Dir),
    try
        Split = st(#{self => Self, id => SelfId, validators => Validators,
                     slot => 5, approved => 6, eng => WithOneComplaint,
                     sync => ready, store => Store1,
                     signing_journal => Journal0,
                     last_applied => 5}),
        Skipped = quod_simplex:dispatch(
                    element(1, SecondComplainer), {share, SecondShare}, Split),
        {6, Store2} = quod_simplex:test_committed_store(Skipped),
        ?assertMatch({ok, #entry{index = 6, data = noop}},
                     quod_ledger_store:read_at(Store2, 6)),

        Leader7 = quod_simplex:leader(7, Validators),
        {Leader7, LeaderId} = lists:keyfind(Leader7, 1, Committee),
        Tx7 = signed_tx(<<"t">>, <<"after-amplified-skip">>,
                        [{assert, {{after_skip, live}, true}}],
                        {Leader7, LeaderId}),
        Block7 = #block{slot = 7, parent = 6, payload = {batch, [Tx7]}},
        Proposed = quod_simplex:dispatch(
                     Leader7, {propose, Block7, []}, Skipped),
        OtherVoters = [Pair || {Pub, _} = Pair <- Committee, Pub =/= Self],
        Supported = dispatch_shares(supports(Block7, OtherVoters, 2), Proposed),
        Final = dispatch_shares(commits(Block7, OtherVoters, 2), Supported),
        {7, FinalStore} = quod_simplex:test_committed_store(Final),
        ?assertMatch({ok, #entry{index = 7}},
                     quod_ledger_store:read_at(FinalStore, 7))
    after
        quod_signing_journal:close(Journal0),
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% Content transactions may batch. A committee transaction is legal only as a
%% singleton at the committed frontier, making it a pipeline barrier by construction.
batch_consensus_barrier_test() ->
    [{A, IdA}, {B, _IdB}] = committee(2),
    Eng = quod_simplex:eng_new(?DOMAIN, [A, B], 5),
    S0 = st(#{self => A, validators => [A, B], slot => 5, approved => 5,
              eng => Eng, sync => ready}),
    C1 = signed_tx(<<"t">>, <<"one">>, [{assert, {{fact, one}, true}}], {A, IdA}),
    C2 = signed_tx(<<"t">>, <<"two">>, [{assert, {{fact, two}, true}}], {A, IdA}),
    Membership = signed_tx(<<"t">>, <<"membership">>, [pa(B)], {A, IdA}),
    ?assert(quod_simplex:acceptable_payload({batch, [C1, C2]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [C1, C1]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [C1 | malformed_tail]}, S0)),
    ?assert(quod_simplex:acceptable_payload({batch, [Membership]}, S0)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [C1, Membership]}, S0)),
    S1 = st(#{self => A, validators => [A, B], slot => 5, approved => 6,
              eng => Eng, sync => ready}),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Membership]}, S1)).

transaction_signature_acceptance_test() ->
    [{Author, AuthorId}, {Outsider, OutsiderId}] = committee(2),
    State = st(#{self => Author, validators => [Author], slot => 5,
                 approved => 5, eng => quod_simplex:eng_new(?DOMAIN, [Author], 5),
                 sync => ready}),
    Good = signed_tx(<<"t">>, <<"good">>,
                     [{assert, {{fact, signed}, true}}], {Author, AuthorId}),
    Forged = Good#transaction{sig = flip1(Good#transaction.sig)},
    Unsigned = Good#transaction{sig = none},
    {ok, NondeterministicId} = quod_transaction:sign(
                                 test_binding(<<"t">>, Author),
                                 Good#transaction{tx_id = <<99:256>>,
                                                  sig = none},
                                 AuthorId),
    WrongNamespace = signed_tx(
                       <<"other">>, <<"wrong-ns">>,
                       [{assert, {{fact, other}, true}}], {Author, AuthorId}),
    Unauthorized = signed_tx(
                     <<"t">>, <<"outsider">>,
                     [{assert, {{fact, outsider}, true}}], {Outsider, OutsiderId}),
    ?assert(quod_simplex:acceptable_payload({batch, [Good]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Unsigned]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Forged]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [NondeterministicId]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [WrongNamespace]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Unauthorized]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Good, Forged]}, State)).

committed_author_sequence_replay_test() ->
    [{Author, AuthorId}] = committee(1),
    State = st(#{self => Author, validators => [Author], slot => 5,
                 approved => 5, eng => quod_simplex:eng_new(?DOMAIN, [Author], 5),
                 author_seqs => #{Author => 5}, sync => ready}),
    Fresh = signed_tx_seq(<<"t">>, <<"fresh">>, 6,
                          [{assert, {{fact, fresh}, true}}],
                          {Author, AuthorId}),
    Replay = signed_tx_seq(<<"t">>, <<"old">>, 5,
                           [{assert, {{fact, old}, true}}],
                           {Author, AuthorId}),
    SameSeq = signed_tx_seq(<<"t">>, <<"same-seq">>, 6,
                            [{assert, {{fact, duplicate}, true}}],
                            {Author, AuthorId}),
    ?assert(quod_simplex:acceptable_payload({batch, [Fresh]}, State)),
    ?assertNot(quod_simplex:acceptable_payload({batch, [Replay]}, State)),
    ?assertNot(quod_simplex:acceptable_payload(
                 {batch, [Fresh, SameSeq]}, State)).

%% The dialing timeout: a dial marker whose deadline has passed is swept (so the tick re-dials it),
%% while one still in the future is kept. This is the whole self-heal for a dial that resolves to neither
%% link_up nor link_error — without it a lost dial pins the peer out of redial_pending forever.
prune_dials_test() ->
    Now = 1000,
    %% keep future deadlines (Now < Deadline); drop expired ones, INCLUDING exactly at the deadline (Now >= Deadline)
    ?assertEqual(#{a => 1500},
                 quod_simplex:prune_dials(#{a => 1500, b => 900, c => 1000}, Now)),
    ?assertEqual(#{}, quod_simplex:prune_dials(#{}, Now)),
    ?assertEqual(#{}, quod_simplex:prune_dials(#{stuck => 1}, Now)),            %% long-expired ⇒ swept
    ?assertEqual(#{x => 2000, y => 3000},                                       %% all future ⇒ all kept
                 quod_simplex:prune_dials(#{x => 2000, y => 3000}, Now)).

%%%===================================================================
%%% share sign / verify
%%%===================================================================

share_roundtrip_test() ->
    {_Pub, Id} = id(),
    H = quod_simplex:block_hash(blk(3)),
    S = quod_simplex:make_share(?DOMAIN, support, 3, H, Id),
    ?assert(quod_simplex:verify_share(?DOMAIN, S)),
    %% a tampered signature is rejected
    Bad = S#share{sig = flip1(S#share.sig)},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Bad)).

%% a support sig does not verify as a commit sig (domain separation)
domain_separation_test() ->
    {Pub, Id} = id(),
    H = quod_simplex:block_hash(blk(3)),
    S = quod_simplex:make_share(?DOMAIN, support, 3, H, Id),
    %% same signer/slot/hash, but the COMMIT bytes -> the support sig must not verify
    ?assertNot(quod_identity:verify(S#share.sig, quod_simplex:share_bytes(?DOMAIN, commit, 3, H), Pub)).

%% There is deliberately no dual-stack verifier. A genuine Ed25519 signature
%% over the former unversioned `{kind,slot,hash}` bytes is cryptographically
%% valid for those bytes but invalid consensus evidence after the format break.
legacy_unversioned_share_is_rejected_test() ->
    {Pub, #{key := Key}} = id(),
    H = quod_simplex:block_hash(blk(3)),
    LegacyBytes = <<$S, 3:64, H/binary>>,
    LegacySig = quod_identity:sign(LegacyBytes, Key),
    ?assert(quod_identity:verify(LegacySig, LegacyBytes, Pub)),
    Legacy =
        #share{kind = support, slot = 3, block_hash = H,
               signer = Pub, sig = LegacySig},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Legacy)).

%% A node identity is intentionally reused across hosted ontologies. The
%% namespace and pinned genesis must therefore both participate in the
%% consensus signature domain: even a genuine quorum complaint from one chain
%% is inert in either a sibling namespace or a re-founded chain.
namespace_and_genesis_bound_consensus_replay_rejected_test() ->
    NsA = <<"ontology:a">>,
    NsB = <<"ontology:b">>,
    GenesisA = <<1:256>>,
    GenesisB = <<2:256>>,
    DomainA = quod_simplex:consensus_domain(NsA, GenesisA),
    NamespaceDomain = quod_simplex:consensus_domain(NsB, GenesisA),
    GenesisDomain = quod_simplex:consensus_domain(NsA, GenesisB),
    ?assertNotEqual(DomainA, NamespaceDomain),
    ?assertNotEqual(DomainA, GenesisDomain),
    Committee = committee(4),
    Validators = pubs(Committee),
    Shares =
        [quod_simplex:make_share(DomainA, complaint, 6, none, Id)
         || {_, Id} <- take(3, Committee)],
    [FirstShare | _] = Shares,
    {ok, Cert} =
        quod_simplex:form_cert(
          DomainA, complaint, 6, none, Shares, Validators),
    ?assert(quod_simplex:verify_share(DomainA, FirstShare)),
    ?assertNot(quod_simplex:verify_share(NamespaceDomain, FirstShare)),
    ?assertNot(quod_simplex:verify_share(GenesisDomain, FirstShare)),
    ?assert(quod_simplex:verify_cert(DomainA, Cert, Validators)),
    ?assertNot(quod_simplex:verify_cert(
                 NamespaceDomain, Cert, Validators)),
    ?assertNot(quod_simplex:verify_cert(
                 GenesisDomain, Cert, Validators)),
    NamespaceEngine =
        quod_simplex:eng_new(NamespaceDomain, Validators, 5),
    {NamespaceRejected, []} =
        quod_simplex:eng_offer({cert, Cert}, NamespaceEngine),
    ?assertEqual(NamespaceEngine, NamespaceRejected),
    GenesisEngine =
        quod_simplex:eng_new(GenesisDomain, Validators, 5),
    {GenesisRejected, []} =
        quod_simplex:eng_offer({cert, Cert}, GenesisEngine),
    ?assertEqual(GenesisEngine, GenesisRejected).

%%%===================================================================
%%% certificate formation + trustless verification
%%%===================================================================

form_and_verify_cert_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, Cert, Vals)).

cert_insufficient_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H, Id) || {_, Id} <- take(2, Ids)],   %% < quorum 3
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals)).

%% a share from a non-validator does not count toward quorum
cert_rejects_outsider_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    {_, Outsider} = id(),                            %% not in Vals
    H = quod_simplex:block_hash(blk(1)),
    Shares =
        [quod_simplex:make_share(?DOMAIN, support, 1, H, Outsider) |
         [quod_simplex:make_share(?DOMAIN, support, 1, H, Id)
          || {_, Id} <- take(2, Ids)]],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals)).

%% a corrupted signature does not count
cert_rejects_bad_sig_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [S1, S2, S3] = [quod_simplex:make_share(?DOMAIN, support, 1, H, Id) || {_, Id} <- take(3, Ids)],
    Shares = [S1, S2, S3#share{sig = flip1(S3#share.sig)}],   %% one bad -> only 2 valid
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals)).

%% duplicate shares from the same signer count once
cert_dedup_signer_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    [{_, A}, {_, B} | _] = Ids,
    %% 3 shares but only 2 distinct signers (A twice) -> below quorum 3
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H, A),
              quod_simplex:make_share(?DOMAIN, support, 1, H, A),
              quod_simplex:make_share(?DOMAIN, support, 1, H, B)],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals)).

%% a forged cert (sigs over a different block) fails trustless verification
verify_cert_rejects_wrong_block_test() ->
    Ids = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H1 = quod_simplex:block_hash(blk(1)),
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H1, Id) || {_, Id} <- take(3, Ids)],
    {ok, Cert} = quod_simplex:form_cert(?DOMAIN, support, 1, H1, Shares, Vals),
    %% claim the cert is for a different block hash -> sigs no longer verify
    Forged = Cert#cert{block_hash = quod_simplex:block_hash(blk(2))},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Forged, Vals)).

%%%===================================================================
%%% the commit guard
%%%===================================================================

%% Both halves of the mutual-exclusion guard, and robustness to an UNSORTED list (the old ordset
%% contract was a silent-wrong-answer footgun — this pins the fix).
mutual_exclusion_guard_test() ->
    ?assert(quod_simplex:may_commit(5, [])),
    ?assertNot(quod_simplex:may_commit(5, [5])),        %% complained slot 5 -> cannot commit it
    ?assert(quod_simplex:may_complain(5, [])),
    ?assertNot(quod_simplex:may_complain(5, [5])),      %% committed slot 5 -> cannot complain it
    ?assertNot(quod_simplex:may_commit(5, [9, 5, 1])),  %% UNSORTED list must still find 5
    ?assertNot(quod_simplex:may_complain(5, [9, 5, 1])).

%% The CROSS-SLOT half of the exclusion, load-bearing for the depth-1 pipeline: committing a block
%% implicitly finalizes its APPROVED PARENT (slot-1), so an honest validator that complained slot v must
%% not commit its child v+1 (that would finalize v — the fork the naive per-slot latch allowed), and
%% symmetrically must not complain v after committing v+1. Without this, a complaint cert on v and a
%% commit cert on v+1 could both form from honest signers and split the committee on v.
cross_slot_exclusion_test() ->
    %% complained the PARENT (4) ⇒ must not commit the child (5), which would implicitly finalize 4
    ?assertNot(quod_simplex:may_commit(5, [4])),
    ?assert(quod_simplex:may_commit(5, [6])),          %% complaining a LATER slot never bars committing 5
    %% committed the CHILD (6) ⇒ must not complain the parent (5), already implicitly finalized
    ?assertNot(quod_simplex:may_complain(5, [6])),
    ?assert(quod_simplex:may_complain(5, [4])),        %% committing an EARLIER slot never bars complaining 5
    %% genesis edge: slot 1's parent is 0 (the origin sentinel), never a votable slot
    ?assert(quod_simplex:may_commit(1, [])),
    ?assertNot(quod_simplex:may_commit(1, [0])).       %% (defensive) 0 in the complained set still bars

%% The FORK the depth-1 pipeline opened, reproduced at the certificate level. A child's commit implicitly
%% finalizes its approved PARENT, so a complaint cert on slot v and a commit cert on its child v+1 must
%% never both form — otherwise v is skipped (noop) on some nodes and block-committed on others. This runs
%% each honest node's REAL guarded vote (may_commit/may_complain over its own latch) across both adversarial
%% orderings and forms the certs with `form_cert`, asserting the two conflicting certs cannot coexist.
%% PRE-FIX (per-slot latch only) BOTH certs formed — the split-brain finalize. Complements the pure-guard
%% cross_slot_exclusion_test with the quorum/cert-formation layer.
fork_certs_cannot_coexist_test() ->
    C    = committee(4),                        %% N=4, quorum(4) = 3
    Vals = pubs(C),
    BH5  = quod_simplex:block_hash(blk(5)),     %% the child block at slot 5 (parent = 4)
    %% (1) every node complains parent 4, THEN is asked to commit child 5: the child-commit cert must NOT form
    {Cpl1, Cmt1} = run_schedule(C, [{complaint, 4, none}, {commit, 5, BH5}]),
    ?assertMatch({ok, _}, quod_simplex:form_cert(?DOMAIN, complaint, 4, none, Cpl1, Vals)),   %% parent-skip cert forms
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, commit, 5, BH5, Cmt1, Vals)),
    %% (2) mirror — every node commits child 5 (finalizing 4), THEN is asked to complain 4: the skip cert must NOT form
    {Cpl2, Cmt2} = run_schedule(C, [{commit, 5, BH5}, {complaint, 4, none}]),
    ?assertMatch({ok, _}, quod_simplex:form_cert(?DOMAIN, commit, 5, BH5, Cmt2, Vals)),       %% child-commit cert forms
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, complaint, 4, none, Cpl2, Vals)).

%% This is the low-level cleanup path for a manually constructed collection
%% with raw caller markers and no signed custody. Complaint-skipping its slot
%% must nack those non-custodied callers instead of leaking them to the park
%% deadline. Ordinary public writes use custody and are retargeted instead.
skipped_batch_nacks_its_callers_test() ->
    Ref  = make_ref(),
    From = {self(), Ref},
    S = quod_simplex:test_state(#{slot => 4, eng => quod_simplex:eng_with_certs(4, []),
                                  collecting => {5, [From]}}),
    _ = quod_simplex:finalize(5, S),   %% slot 5 finalized (skipped) while its batch was still collecting
    %% Select on this waiter's exact reply ref: the mailbox may also hold
    %% unrelated engine signals, so match `{Ref, _}` rather than any 2-tuple.
    receive
        {Ref, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> ?assert(false)          %% no reply => the caller would hang to its transaction TTL
    end.

%% The same raw, non-custodied cleanup applies when a competing block notarizes
%% while the leader is collecting for that slot. The obsolete collection must
%% be nacked rather than left able to crash the next collect_append.
competing_notarization_nacks_collected_batch_test() ->
    Ref = make_ref(),
    From = {self(), Ref},
    S = quod_simplex:test_state(
          #{slot => 4, approved => 4, eng => quod_simplex:eng_with_certs(4, []),
            collecting => {5, [From]}}),
    _ = quod_simplex:approve_block(blk(5), S),
    receive
        {Ref, Reply} -> ?assertEqual({error, skipped}, Reply)
    after 0 -> ?assert(false)
    end.

%% Batch capacity limits, driven through the real append entry (running/3). An oversized single change is
%% rejected fast ({error, too_large}) so a block can never blow past the wire frame; a leader whose
%% depth-one pipeline is already full now PARKS the append in the bounded ingress queue instead of
%% rejecting {error, busy} — the caller waits for the pipeline's own events, not a retry timer.
batch_caps_reject_oversized_and_park_test() ->
    {Me, Id} = id(),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             eng => quod_simplex:eng_with_certs(0, [])},   %% a caught-up sole leader
    From = {self(), make_ref()},
    %% oversized single transaction (> MAX_BLOCK_BYTES = 256 KiB) => too_large, never batched, never parked
    Big = bind_test_id(
            #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                         proof_id = <<0:256>>, plan_digest = <<0:256>>,
                         goal = durable_goal({test, big}),
                         result = durable_result(),
                         author = Me, sig = none, read_check = #{},
                         diff = [{assert,
                                  {{blob, binary:copy(<<0>>, 300 * 1024)},
                                   true}}]}),
    {keep_state, _, A1} =
        quod_simplex:running(
          {call, From}, {append, Big, otel_ctx:new()}, st(Base)),
    ?assert(lists:member({reply, From, {error, too_large}}, A1)),
    %% depth-one pipeline already full (committed 3, approved 5 => gap 2, the max): the append PARKS —
    %% no reply action, no busy, one queued item under this author.
    Small = bind_test_id(
              #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                           proof_id = <<0:256>>, plan_digest = <<0:256>>,
                           goal = durable_goal({test, small}),
                           result = durable_result(),
                           author = Me, sig = none, read_check = #{},
                           diff = [{assert, {{k, v}, true}}]}),
    {keep_state, SParked, A2} =
        quod_simplex:running(
          {call, From}, {append, Small, otel_ctx:new()},
          st(Base#{approved => 5})),
    ?assertEqual([], [R || {reply, _, _} = R <- A2]),
    SmallId = Small#transaction.tx_id,
    {1, _, Authors, [{local, SmallId, _}]} = quod_simplex:test_ingress(SParked),
    ?assertEqual(#{Me => 1}, Authors),
    ?assertEqual(0, maps:get(r_busy, quod_simplex:stats_map(SParked))),
    %% Two locally authored envelopes for the same semantic transaction
    %% coalesce. The second custody record is not replied to early; both are
    %% released by the one committed tx_id.
    FirstRef = make_ref(),
    SecondRef = make_ref(),
    FirstFrom = {self(), FirstRef},
    SecondFrom = {self(), SecondRef},
    {keep_state, S1, _} =
        quod_simplex:running(
          {call, FirstFrom}, {append, Small, otel_ctx:new()}, st(Base)),
    {keep_state, S2, A3} =
        quod_simplex:running(
          {call, SecondFrom}, {append, Small, otel_ctx:new()}, S1),
    ?assertEqual([], [R || {reply, _, _} = R <- A3]),
    ?assertEqual(2, length(quod_simplex:test_custody(S2))),
    [{_FirstSubmissionId, 1, FirstSubmission,
      _FirstPlacement, _FirstDeadline, _FirstAttempts}] =
        quod_simplex:test_custody(S1),
    {ok, SignedFirst} = decode_submission(<<"t">>, FirstSubmission),
    Settled = quod_simplex:test_resolve_committed_submissions(
                {batch, [SignedFirst]}, 4, S2),
    receive {FirstRef, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    receive {SecondRef, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    ?assertEqual([], quod_simplex:test_custody(Settled)).

different_validator_envelopes_for_same_transaction_converge_test() ->
    Ns = <<"t">>,
    {FirstAuthor, FirstIdentity} = id(),
    {SecondAuthor, SecondIdentity} = id(),
    Base = bind_test_id(
             #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                          proof_id = <<91:256>>, plan_digest = <<92:256>>,
                          goal = durable_goal({same, semantic, transaction}),
                          result = durable_result(), read_check = #{},
                          diff = [{assert, {{same_semantic, value}, true}}],
                          author = SecondAuthor, author_seq = 0, sig = none}),
    FirstUnsigned = Base#transaction{author = FirstAuthor, author_seq = 1},
    {ok, First} = quod_transaction:sign(
                    test_binding(Ns, FirstAuthor),
                    FirstUnsigned, FirstIdentity),
    Ref = make_ref(),
    From = {self(), Ref},
    S0 = st(#{self => SecondAuthor, id => SecondIdentity,
              validators => [SecondAuthor], sync => ready,
              slot => 3, approved => 3,
              eng => quod_simplex:eng_with_certs(3, [])}),
    {S1, _Actions} = quod_simplex:test_append(From, Base, S0),
    [{_SubmissionId, 1, SecondSubmission, _Placement, _Deadline, _Attempts}] =
        quod_simplex:test_custody(S1),
    {ok, Second} = decode_submission(Ns, SecondSubmission),
    ?assertNotEqual(First#transaction.author, Second#transaction.author),
    ?assertEqual(First#transaction.tx_id, Second#transaction.tx_id),
    Settled = quod_simplex:test_resolve_committed_submissions(
                {batch, [First]}, 4, S1),
    receive {Ref, {ok, 4}} -> ok after 0 -> ?assert(false) end,
    ?assertEqual([], quod_simplex:test_custody(Settled)).

batch_rejects_duplicate_author_sequence_without_mutation_test() ->
    Ns = <<"t">>,
    [{Author, AuthorId}] = Committee = committee(1),
    First =
        signed_tx_seq(
          Ns, <<"same-sequence-a">>, 7,
          [{assert, {{same_sequence, a}, true}}],
          {Author, AuthorId}),
    Second =
        signed_tx_seq(
          Ns, <<"same-sequence-b">>, 7,
          [{assert, {{same_sequence, b}, true}}],
          {Author, AuthorId}),
    S0 =
        st(#{self => Author, id => AuthorId,
             validators => pubs(Committee), sync => ready,
             slot => 3, approved => 3, author_seqs => #{Author => 6},
             eng => quod_simplex:eng_with_certs(3, []),
             relay_conns => #{Author => {self(), make_ref()}}}),
    {S1, _} = quod_simplex:test_relayed_append(Author, First, S0),
    BatchBefore = quod_simplex:test_batch(S1),
    StatsBefore = quod_simplex:stats_map(S1),
    {S2, []} = quod_simplex:test_relayed_append(Author, Second, S1),
    ?assertEqual(BatchBefore, quod_simplex:test_batch(S2)),
    ?assertEqual(maps:get(appends, StatsBefore),
                 maps:get(appends, quod_simplex:stats_map(S2))),
    ?assertEqual(maps:get(r_stale, StatsBefore) + 1,
                 maps:get(r_stale, quod_simplex:stats_map(S2))),
    ?assertMatch(
       {relay_result, _SubmissionId, _AttemptId, _CommitteeId, 4,
        {error, stale_seq}},
       receive_relay_control(Ns)).

batch_operation_claims_coalesce_aliases_and_reject_conflicts_test() ->
    Ns = <<"t">>,
    Anchor = <<0:256>>,
    OperationId = <<77:256>>,
    AgentKey = quod_identity:generate(),
    Base = quod_ct:signed_dtx_begin_fixture(
             #{target => {Ns, Anchor}, operation_id => OperationId,
               key_pair => AgentKey}),
    First0 = maps:get(transaction, Base),
    #{pubkey := Author} = NodeIdentity = maps:get(node_identity, Base),
    Admission = maps:get(admission, Base),
    First = First0#transaction{author = Author, author_seq = 0, sig = none},
    AliasFixture = quod_ct:signed_dtx_begin_fixture(
                     #{target => {Ns, Anchor},
                       operation_id => OperationId, key_pair => AgentKey,
                       proof_id => <<210:256>>}),
    Alias = (maps:get(transaction, AliasFixture))#transaction{
              author = Author, author_seq = 0, sig = none},
    ConflictFixture = quod_ct:signed_dtx_begin_fixture(
                        #{target => {Ns, Anchor},
                          operation_id => OperationId, key_pair => AgentKey,
                          proof_id => <<211:256>>,
                          goal_text => <<"assertz(saved(conflict)).">>}),
    Conflict = (maps:get(transaction, ConflictFixture))#transaction{
                 author = Author, author_seq = 0, sig = none},
    ?assertNotEqual(First#transaction.tx_id, Alias#transaction.tx_id),
    {ok, FirstClaim} = quod_transaction:request_claim(First),
    {ok, AliasClaim} = quod_transaction:request_claim(Alias),
    {ok, ConflictClaim} = quod_transaction:request_claim(Conflict),
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, AliasClaim)),
    ?assertEqual(maps:get(digest, FirstClaim), maps:get(digest, AliasClaim)),
    ?assertEqual(maps:get(key, FirstClaim), maps:get(key, ConflictClaim)),
    ?assertNotEqual(maps:get(digest, FirstClaim),
                    maps:get(digest, ConflictClaim)),
    quod_ct:with_network_identity(
      maps:get(network, Base),
      fun() ->
          S0 = st(#{ns => Ns, self => Author,
                    id => NodeIdentity,
                    genesis_hash => Anchor,
                    consensus_domain => quod_simplex:consensus_domain(
                                            Ns, Anchor),
                    validators => [Author],
                    author_admissions => #{Author => Admission},
                    author_seqs => #{Author => 0}, sync => ready,
                    slot => 3, approved => 3,
                    eng => quod_simplex:eng_with_certs(3, [])}),
          FirstRef = make_ref(),
          AliasRef = make_ref(),
          {S1, _BatchTimer} = quod_simplex:test_append(
                                {self(), FirstRef}, First, S0),
          {S2, []} = quod_simplex:test_append(
                       {self(), AliasRef}, Alias, S1),
          #{count := 1, operation_claims := Claims} =
              quod_simplex:test_batch(S2),
          ?assertEqual(1, map_size(Claims)),
          ?assertEqual(2, length(quod_simplex:test_custody(S2))),
          [{_FirstSubmissionId, 1, FirstSubmission,
            _FirstPlacement, _FirstDeadline, _FirstAttempts}] =
              quod_simplex:test_custody(S1),
          {ok, SignedFirst} = quod_transaction:decode_verified_submission(
                                {Ns, Anchor, Admission}, FirstSubmission),
          Settled = quod_simplex:test_resolve_committed_submissions(
                      {batch, [SignedFirst]}, 4, S2),
          receive {FirstRef, {ok, 4}} -> ok
          after 0 -> ?assert(false)
          end,
          OperationRef = maps:get(operation_ref, FirstClaim),
          receive
              {AliasRef, {error, {outcome_unknown, OperationRef}}} -> ok
          after 0 -> ?assert(false)
          end,
          ?assertEqual([], quod_simplex:test_custody(Settled)),

          ConflictRef = make_ref(),
          ConflictFrom = {self(), ConflictRef},
          {C1, _ConflictBatchTimer} = quod_simplex:test_append(
                                        {self(), make_ref()}, First, S0),
          {C2, ConflictActions} = quod_simplex:test_append(
                                    ConflictFrom, Conflict, C1),
          ?assert(lists:member(
                    {reply, ConflictFrom, {error, bad_change}},
                    ConflictActions)),
          #{count := 1} = quod_simplex:test_batch(C2),
          ?assertEqual(1, length(quod_simplex:test_custody(C2)))
      end).

batch_population_does_not_flush_before_byte_limit_test() ->
    Ns = <<"t">>,
    [{Author, AuthorId}] = Committee = committee(1),
    S0 =
        st(#{self => Author, id => AuthorId,
             validators => pubs(Committee), sync => ready,
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    Transactions =
        [signed_tx_seq(
           Ns, <<"batch-", (integer_to_binary(N))/binary>>, N,
           [{assert, {{batch_item, N}, true}}],
           {Author, AuthorId})
         || N <- lists:seq(1, 256)],
    {First255, _} =
        lists:foldl(
          fun(Change, {Acc, _Actions}) ->
                  quod_simplex:test_relayed_append(
                    Author, Change, Acc)
          end, {S0, []}, lists:sublist(Transactions, 255)),
    #{count := 255, tx_ids := TxIds, sequences := Sequences} =
        quod_simplex:test_batch(First255),
    ?assertEqual(255, map_size(TxIds)),
    ?assertEqual(255, map_size(Sequences)),
    Last = lists:nth(256, Transactions),
    {Collected, Actions} =
        quod_simplex:test_relayed_append(
          Author, Last, First255),
    #{count := 256, tx_ids := FinalTxIds,
      sequences := FinalSequences} = quod_simplex:test_batch(Collected),
    ?assertEqual(256, map_size(FinalTxIds)),
    ?assertEqual(256, map_size(FinalSequences)),
    ?assertNot(lists:member({{timeout, batch}, cancel}, Actions)),
    Stats = quod_simplex:stats_map(Collected),
    ?assertEqual(256, maps:get(appends, Stats)),
    ?assertEqual(0, maps:get(batched_txs, Stats)),
    ?assertEqual(0, maps:get(proposals, Stats)).

%%%===================================================================
%%% ingress park queue — park, drain, forward, expire (event-driven ingress)
%%%===================================================================

lt(N) -> bind_test_id(
           #transaction{tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
                        proof_id = <<0:256>>, plan_digest = <<0:256>>,
                        goal = durable_goal({load, N}),
                        result = durable_result(),
                        author = undefined,
                        sig = none, read_check = #{},
                        diff = [{assert, {{loadfact, N}, true}}]}).
lt(N, Author) -> (lt(N))#transaction{author = Author}.

keep_progress_retains_unchanged_ingress_view_test() ->
    {Me, Id} = id(),
    S0 =
        st(#{self => Me, id => Id, validators => [Me],
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    ?assertEqual(undefined,
                 quod_simplex:test_ingress_view_source(S0)),
    {keep_state, Cached, _} =
        quod_simplex:test_keep_progress_transition(S0, S0),
    Source = quod_simplex:test_ingress_view_source(Cached),
    ?assertNotEqual(undefined, Source),
    {keep_state, CachedAgain, _} =
        quod_simplex:test_keep_progress_transition(Cached, Cached),
    ?assertEqual(
       Source,
       quod_simplex:test_ingress_view_source(CachedAgain)).

%% A verified finalizer beyond the live engine window is represented only by
%% `ahead_finalizer`. That scalar revokes voting and ingress immediately, so it
%% must also invalidate the cached route view even though no cert map changed.
far_finalizer_invalidates_cached_ingress_view_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Me = quod_simplex:leader(6, Validators),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, 5),
    S0 =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 5, approved => 5, eng => E0}),
    {keep_state, Cached, _} =
        quod_simplex:test_keep_progress_transition(S0, S0),
    CachedSource = quod_simplex:test_ingress_view_source(Cached),
    ?assertEqual(
       {collect, 6},
       quod_simplex:test_route(entry, local, lt($h, Me), Cached)),

    FarBlock = blk(8),
    FarHash = quod_simplex:block_hash(FarBlock),
    {ok, FarCert} =
        quod_simplex:form_cert(
          ?DOMAIN, commit, 8, FarHash,
          commits(FarBlock, Committee, 3), Validators),
    {HintedEngine, []} =
        quod_simplex:eng_offer({cert, FarCert}, E0),
    Hinted =
        quod_simplex:test_state_set(eng, HintedEngine, Cached),
    {keep_state, Refreshed, _} =
        quod_simplex:test_keep_progress_transition(Cached, Hinted),
    ?assertNotEqual(
       CachedSource,
       quod_simplex:test_ingress_view_source(Refreshed)),
    ?assertEqual(
       redirect,
       quod_simplex:test_route(entry, local, lt($i, Me), Refreshed)).

%% Two parked items drain into ONE immediately-sealed block the moment the pipeline
%% opens — no micro-batch window for backlog that already waited a full flight.
%% Planting the blocked queue directly keeps this test about drain/seal,
%% independently of source-side target selection.
multi_item_drain_seals_one_block_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    A = lt($a, Me), B = lt($b, Me),
    P2 = quod_simplex:test_state_set(
           ingress,
           [{local, F1, A, quod_time:mono_ms()},
            {local, F2, B, quod_time:mono_ms() + 1}],
           Blocked),
    {2, _, _, [{local, AId, _}, {local, BId, _}]} =
        quod_simplex:test_ingress(P2),
    ?assertEqual(A#transaction.tx_id, AId),
    ?assertEqual(B#transaction.tx_id, BId),
    %% pipeline opens (approval frontier back at the durable head) => drain pours + seals NOW
    Opened = quod_simplex:test_state_set(approved, 3, P2),
    ?assert(quod_simplex:test_ingress_needs_drain(P2, Opened)),
    {Drained, Actions} = quod_simplex:test_drain(Opened),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    %% sealed immediately: no open batch survives, both waiters sit on the in-flight
    %% proposal (pending counts local_proposal waiters), the head watchdog is armed.
    ?assert(lists:member({{timeout, batch}, cancel}, Actions)),
    ?assertMatch({4, _, _}, quod_simplex:test_progress(Drained)),
    ?assertEqual(2, maps:get(pending, quod_simplex:stats_map(Drained))),
    ?assertEqual(2, maps:get(batched_txs, quod_simplex:stats_map(Drained))).

%% A singleton drain keeps the normal micro-batch window (its arm action threads out),
%% so the post-rotation re-send wave can still join the same block.
singleton_drain_keeps_batch_window_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   batch_window_ms => 37,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    F = {self(), make_ref()},
    P1 = quod_simplex:test_state_set(
           ingress, [{local, F, lt($c, Me), quod_time:mono_ms()}], Blocked),
    {Drained, Actions} = quod_simplex:test_drain(
                           quod_simplex:test_state_set(approved, 3, P1)),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual([{{timeout, batch}, 37, {flush_batch, 4}}],
                 [A || {{timeout, batch}, _, _} = A <- Actions]).

%% Membership must enter only after the approved pipeline becomes final. It is a
%% global drain barrier, not ordinary author-local backpressure: allowing later
%% writes to keep filling the child slot could starve the committee transition.
queued_membership_stops_the_drain_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(5, Validators), 1, Committee),
    [{AuthorA, IdA}, {AuthorB, IdB} | _] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    NewMember = <<99:256>>,
    Membership = signed_tx(<<"t">>, <<"membership-head">>, [pa(NewMember)],
                           {AuthorA, IdA}),
    Ordinary = signed_tx(<<"t">>, <<"ordinary-ready">>,
                         [{assert, {{ordinary, ready}, true}}], {AuthorB, IdB}),
    Approved = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, Approved}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {Eng, _} = feed_shares(supports(Approved, Committee, 3), E1),
    Now = quod_time:mono_ms(),
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 4,
                  eng => Eng,
                  ingress =>
                      [{relayed, AuthorA, 5, Membership, Now},
                       {relayed, AuthorB, 5, Ordinary, Now}]}),
    %% The ordinary write could enter slot 5 in isolation; queue ordering is what
    %% deliberately holds it behind the membership boundary.
    OrdinaryOrigin =
        quod_simplex:test_relay_origin(AuthorB, 5, Ordinary, Queued),
    ?assertEqual({collect, 5},
                 quod_simplex:test_route(
                   drain, OrdinaryOrigin, Ordinary, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 1, AuthorB := 1},
     [{relayed, MembershipId, _}, {relayed, OrdinaryId, _}]} =
        quod_simplex:test_ingress(Drained),
    ?assertEqual(Membership#transaction.tx_id, MembershipId),
    ?assertEqual(Ordinary#transaction.tx_id, OrdinaryId),
    ?assertEqual(0, maps:get(appends, quod_simplex:stats_map(Drained))).

%% Capacity backpressure is author-local. A large A1 that cannot join the open
%% batch holds A2 behind it, preserving signed author sequence, while a small B
%% may fill the otherwise usable block. The held pair is restored in order.
blocked_author_does_not_block_other_authors_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{FillerAuthor, FillerId}, {AuthorA, IdA}, {AuthorB, IdB}] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Filler = signed_tx(
               <<"t">>, <<"batch-filler">>,
               [{assert, {{blob, binary:copy(<<1>>, 190000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 90000)}, true}}],
           {AuthorA, IdA}),
    A2 = signed_tx_seq(
           <<"t">>, <<"a-small">>, 11,
           [{assert, {{ordinary, a2}, true}}], {AuthorA, IdA}),
    B = signed_tx(
          <<"t">>, <<"b-small">>,
          [{assert, {{ordinary, b}, true}}], {AuthorB, IdB}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, approved => 3,
                eng => quod_simplex:eng_with_certs(3, [])}),
    {WithBatch, _BatchActions} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, AuthorA, 4, A1, Now},
                {relayed, AuthorA, 4, A2, Now + 1},
                {relayed, AuthorB, 4, B, Now + 2}],
               WithBatch),
    ?assert(quod_simplex:test_ingress_needs_drain(WithBatch, Queued)),
    A1Origin = quod_simplex:test_relay_origin(AuthorA, 4, A1, Queued),
    A2Origin = quod_simplex:test_relay_origin(AuthorA, 4, A2, Queued),
    BOrigin = quod_simplex:test_relay_origin(AuthorB, 4, B, Queued),
    ?assertMatch({park, _},
                 quod_simplex:test_route(drain, A1Origin, A1, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:test_route(drain, A2Origin, A2, Queued)),
    ?assertEqual({collect, 4},
                 quod_simplex:test_route(drain, BOrigin, B, Queued)),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {2, _, #{AuthorA := 2},
     [{relayed, A1Id, _}, {relayed, A2Id, _}]} =
        quod_simplex:test_ingress(Drained),
    ?assertEqual(A1#transaction.tx_id, A1Id),
    ?assertEqual(A2#transaction.tx_id, A2Id),
    ?assertEqual(2, maps:get(appends, quod_simplex:stats_map(Drained))),
    ?assertNot(quod_simplex:test_ingress_needs_drain(Drained, Drained)).

%% The first pass can itself change routing: B and C fill and seal slot 4 while
%% A1/A2 are held behind A1's capacity block. The second pass must then revisit A
%% and reject its now-closed exact target. A one-pass drain leaves both A requests
%% stranded even though the route changed during the same statem event.
drain_rechecks_held_authors_after_route_change_test() ->
    Committee = committee(5),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{FillerAuthor, FillerId}, {AuthorA, IdA},
     {AuthorB, IdB}, {AuthorC, IdC}] =
        [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Filler = signed_tx(
               <<"t">>, <<"multipass-filler">>,
               [{assert, {{blob, binary:copy(<<1>>, 190000)}, true}}],
               {FillerAuthor, FillerId}),
    A1 = signed_tx_seq(
           <<"t">>, <<"multipass-a-large">>, 10,
           [{assert, {{blob, binary:copy(<<2>>, 90000)}, true}}],
           {AuthorA, IdA}),
    A2 = signed_tx_seq(
           <<"t">>, <<"multipass-a-small">>, 11,
           [{assert, {{ordinary, multipass_a2}, true}}], {AuthorA, IdA}),
    B = signed_tx(
          <<"t">>, <<"multipass-b">>,
          [{assert, {{ordinary, multipass_b}, true}}], {AuthorB, IdB}),
    C = signed_tx(
          <<"t">>, <<"multipass-c">>,
          [{assert, {{ordinary, multipass_c}, true}}], {AuthorC, IdC}),
    Base = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, approved => 3,
                eng => quod_simplex:eng_with_certs(3, [])}),
    {WithBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Base),
    Now = quod_time:mono_ms(),
    Queued = quod_simplex:test_state_set(
               ingress,
               [{relayed, AuthorA, 4, A1, Now},
                {relayed, AuthorA, 4, A2, Now + 1},
                {relayed, AuthorB, 4, B, Now + 2},
                {relayed, AuthorC, 4, C, Now + 3}],
               WithBatch),
    {Drained, _Actions} = quod_simplex:test_drain(Queued),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    Stats = quod_simplex:stats_map(Drained),
    ?assertEqual(3, maps:get(appends, Stats)),
    ?assertEqual(2, maps:get(r_redirect, Stats)).

%% A participant can temporarily lose voting capability while recovering or while a
%% finality cert arrives before its block. Local unsigned work is refused, but an
%% authenticated relay attempt is held until readiness returns. If recovery
%% replaces that volatile destination window, the source reconnects and replays
%% its retained ordered prefix; no public retry is synthesized.
queued_work_survives_temporary_unready_state_test() ->
    Committee = committee(2),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    [{Author, AuthorId}] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"recovering-queue">>,
                   [{assert, {{recovering, queued}, true}}], {Author, AuthorId}),
    Now = quod_time:mono_ms(),
    Recovering = st(
                   #{self => Me, id => MyId, validators => Validators,
                     sync => unconfirmed, slot => 3, approved => 3,
                     eng => quod_simplex:eng_with_certs(3, []),
                     ingress =>
                         [{relayed, Author, 4, Tx, Now}]}),
    Origin4 =
        quod_simplex:test_relay_origin(Author, 4, Tx, Recovering),
    Origin5 =
        quod_simplex:test_relay_origin(Author, 5, Tx, Recovering),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, Origin4, Tx, Recovering)),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(drain, Origin4, Tx, Recovering)),
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, Origin5, Tx, Recovering)),
    {Held, []} = quod_simplex:test_drain(Recovering),
    {1, _, _, [{relayed, RecoveringId, _}]} =
        quod_simplex:test_ingress(Held),
    ?assertEqual(Tx#transaction.tx_id, RecoveringId),
    Ready = quod_simplex:test_state_set(sync, ready, Held),
    ?assert(quod_simplex:test_ingress_needs_drain(Held, Ready)),
    {Drained, _} = quod_simplex:test_drain(Ready),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))).

%% Shared and per-author bounds: overflow is the only remaining live source of busy.
%% A foreign author reaches this node only over the signed relay, so its park rides
%% the relayed entry; the flooding author's overflow never blocks anyone else's seat.
ingress_overflow_and_author_cap_test() ->
    Committee = committee(2),
    Validators = pubs(Committee),
    %% the node that leads the blocked-time floor (slot 6) — local items park HERE
    {Me, Id} = lists:keyfind(quod_simplex:leader(6, Validators), 1, Committee),
    [{Other, OtherId}] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Blocked = st(#{self => Me, id => Id, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(0, [])}),
    %% Fill one author to its fair-share cap (64). Planting the queue directly
    %% isolates the queue bounds from source-side target selection.
    S64 = quod_simplex:test_state_set(
            ingress,
            [{local, {self(), make_ref()}, lt(N, Me),
              quod_time:mono_ms() + N} || N <- lists:seq(1, 64)],
            Blocked),
    {64, _, #{Me := 64}, _} = quod_simplex:test_ingress(S64),
    %% the 65th from the SAME author overflows busy; another author still parks
    FromB = {self(), make_ref()},
    {S65, A65} = quod_simplex:test_append(FromB, lt(65, Me), S64),
    ?assert(lists:member({reply, FromB, {error, busy}}, A65)),
    ?assertEqual(1, maps:get(ingress_overflow, quod_simplex:stats_map(S65))),
    OtherTx = signed_tx(<<"t">>, <<"other-park">>,
                        [{assert, {{other, fact}, true}}], {Other, OtherId}),
    {S66, []} = quod_simplex:test_relayed_append(
                  Other, OtherTx, S65),
    {65, _, #{Other := 1}, _} = quod_simplex:test_ingress(S66).

%% TTL expiry fails VISIBLY (busy) and walks only the queue head — a stalled cluster
%% must never silently hold callers hostage.
ingress_ttl_expires_visibly_test() ->
    {Me, Id} = id(),
    Old = quod_time:mono_ms() - 60000,
    From = {self(), make_ref()},
    S = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             approved => 5, eng => quod_simplex:eng_with_certs(0, [])}),
    {Parked, []} = quod_simplex:test_append(From, lt($e, Me), S),
    %% age the single parked item by rebuilding it with an old enqueue stamp
    Aged = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
                approved => 5, eng => quod_simplex:eng_with_certs(0, []),
                ingress => [{local, From, lt($e, Me), Old}]}),
    {1, _, _, _} = quod_simplex:test_ingress(Aged),
    Expired = quod_simplex:test_expire_ingress(Aged),
    {0, 0, _, []} = quod_simplex:test_ingress(Expired),
    {_, ExpectRef} = From,
    receive {ExpectRef, Reply} -> ?assertEqual({error, busy}, Reply)
    after 0 -> ?assert(false) end,
    ?assertEqual(1, maps:get(ingress_expired, quod_simplex:stats_map(Expired))),
    ?assertEqual(1, maps:get(r_busy, quod_simplex:stats_map(Expired))),
    %% the fresh twin above must NOT have expired anything
    Fresh = quod_simplex:test_expire_ingress(Parked),
    {1, _, _, _} = quod_simplex:test_ingress(Fresh).

%% Forward-on-rotation: at drain, a local item whose next slot belongs to another
%% leader is signed once and relayed — with the relay deadline anchored at the ORIGINAL
%% enqueue time, so queue time counts against the caller's end-to-end budget.
drain_forwards_to_next_leader_with_anchored_deadline_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    NotLeader4 = hd([P || {P, _} = P4 <- Committee,
                          element(1, P4) =/= quod_simplex:leader(4, Validators)]),
    {Me, MyId} = lists:keyfind(NotLeader4, 1, Committee),
    TargetLeader = quod_simplex:leader(4, Validators),
    Anchor = quod_time:mono_ms() - 3000,   %% parked 3s ago
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($f, Me), Anchor}]}),
    {Drained, []} = quod_simplex:test_drain(S),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(ingress_forwarded, quod_simplex:stats_map(Drained))),
    %% the relay is pending toward leader(4) with its deadline anchored at the ORIGINAL
    %% enqueue time — park time counts against the caller's budget, not on top of it
    ?assertEqual(
       {[], [], [], []},
       quod_simplex:test_link_peers(Drained)),
    ?assertEqual(
       {[], [], [TargetLeader]},
       quod_simplex:test_relay_link_peers(Drained)),
    [{_AttemptId, Target, 4, Deadline}] =
        quod_simplex:test_relay_pending(Drained),
    ?assertEqual(TargetLeader, Target),
    ?assert(Deadline =< Anchor + 32000),                  %% anchored: ~Anchor + 31s
    ?assert(Deadline < quod_time:mono_ms() + 30000).      %% NOT re-anchored at drain time

%% A fresh author lane targets the earliest slot that can still accept it. The
%% target slot is explicit and therefore cannot be reinterpreted by the receiver.
origin_routes_to_earliest_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    ExpectedTarget = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee,
                          Pub =/= ExpectedTarget]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Sent, []} = quod_simplex:test_append(From, lt($g, Me), S),
    {0, 0, _, []} = quod_simplex:test_ingress(Sent),
    [{_AttemptId, Target, 4, _Deadline}] =
        quod_simplex:test_relay_pending(Sent),
    ?assertEqual(ExpectedTarget, Target),
    %% A live entry is not a drain forward.
    ?assertEqual(0, maps:get(ingress_forwarded, quod_simplex:stats_map(Sent))).

%% Placement is about filling the earliest block, independent of author identity.
%% Aggregation can be moved out of the consensus process later; routing must not
%% manufacture empty slots merely to distribute mailbox work.
all_authors_target_earliest_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Targets =
        [begin
             S = st(#{self => Author, id => AuthorId,
                      validators => Validators, sync => ready,
                      slot => 3, approved => 3,
                      eng => quod_simplex:eng_with_certs(3, [])}),
             case quod_simplex:test_route(entry, local, lt($d, Author), S) of
                 {collect, 4} -> quod_simplex:leader(4, Validators);
                 {relay, Target, 4} -> Target
             end
         end || {Author, AuthorId} <- Committee],
    ?assertEqual(
       lists:duplicate(length(Committee), quod_simplex:leader(4, Validators)),
       Targets).

%% If this node proposes the earliest usable slot, it holds the change locally
%% until that exact slot opens.
origin_parks_when_it_owns_the_next_seat_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(5, Validators), 1, Committee),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => E2}),
    {Parked, []} = quod_simplex:test_append(From, lt($g, Me), S),
    {1, _, _, [{local, _, _}]} = quod_simplex:test_ingress(Parked),
    ?assertEqual([], quod_simplex:test_relay_pending(Parked)),
    {Still, []} = quod_simplex:test_drain(Parked),   %% the drain holds it for our turn
    {1, _, _, _} = quod_simplex:test_ingress(Still).

%% Every parked item sits under an armed head watchdog: for each blocked cause the
%% reconciled head_progress is non-idle (the liveness invariant behind park-not-poll).
parked_ingress_implies_armed_watchdog_test() ->
    {Me, Id} = id(),
    Base = #{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             eng => quod_simplex:eng_with_certs(0, [])},
    F = fun(Over) ->
            {S, []} = quod_simplex:test_append({self(), make_ref()}, lt($h, Me),
                                               st(maps:merge(Base, Over))),
            {C, _, _, _} = quod_simplex:test_ingress(S),
            ?assertEqual(1, C),
            ?assertNotEqual(idle,
                            quod_simplex:test_progress(
                              quod_simplex:reconcile_head_progress(S)))
        end,
    F(#{approved => 5}),                                   %% pipeline full
    F(#{approved => 3, commit_buf => #{4 => skip}}),       %% commit_buf holds Next
    %% a sealed local proposal in flight for Next
    B4 = blk(4),
    F(#{approved => 3,
        local_proposal => {4, quod_simplex:block_hash(B4)}}),
    %% consensus barrier: a notarized committee-touching block above the head (a
    %% one-member engine notarizes it from a single support share; the barrier and the
    %% watchdog evidence both read the engine, not the state's validator list)
    {MPub, MId} = id(),
    MTx = signed_tx(<<"t">>, <<"barrier">>, [pa(MPub)], {MPub, MId}),
    MBlock = #block{slot = 4, parent = 3, payload = {batch, [MTx]}},
    {EngB0, _} = quod_simplex:eng_offer({block, MBlock},
                                        quod_simplex:eng_new(?DOMAIN, [MPub], 3)),
    {BarrierEng, _} = feed_shares(
                        [quod_simplex:make_share(?DOMAIN,
                           support, 4, quod_simplex:block_hash(MBlock), MId)],
                        EngB0),
    F(#{approved => 3, eng => BarrierEng}).

%% A pre-signed relayed change whose sequence fell below the floor is STALE_SEQ —
%% retryable by contract — never terminal bad_change.
stale_seq_is_retryable_test() ->
    [{A, IdA}] = Committee = committee(1),
    Signed = signed_tx_seq(<<"t">>, <<"stale">>, 2,
                           [{assert, {{stale, fact}, true}}], {A, IdA}),
    S = st(#{self => A, id => IdA, validators => pubs(Committee), sync => ready,
             slot => 5, approved => 5, eng => quod_simplex:eng_with_certs(0, []),
             relay_conns => #{A => {self(), make_ref()}},
             author_seqs => #{A => 9}}),   %% committed floor already past seq 2
    {S1, []} = quod_simplex:test_relayed_append(A, Signed, S),
    %% The relay result stays on the dedicated ingress stream. Consensus
    %% transport state remains completely untouched.
    ?assertMatch(
       {relay_result, _SubmissionId, _AttemptId, _CommitteeId,
        _TargetSlot, {error, stale_seq}},
       receive_relay_control(<<"t">>)),
    ?assertEqual({[], [], [], []}, quod_simplex:test_link_peers(S1)),
    ?assertEqual({[A], [], []},
                 quod_simplex:test_relay_link_peers(S1)),
    %% counted as a ROUTING RACE, never as malformed input — r_bad is the loadtest's
    %% "malformed workload" alarm and must stay quiet for retryable races
    ?assertEqual(1, maps:get(r_stale, quod_simplex:stats_map(S1))),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(S1))).

%% Recovery nacks unsigned ingress that has not yet become signed custody. Any
%% custodied submission is retained and reconstructed separately.
reseat_nacks_parked_ingress_test() ->
    {Me, Id} = id(),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => Id, validators => [Me], sync => ready, slot => 3,
             approved => 5, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($i, Me), quod_time:mono_ms()}]}),
    Reseated = quod_simplex:reseat_engine(3, S),
    {0, 0, _, []} = quod_simplex:test_ingress(Reseated),
    {_, ExpectRef} = From,
    receive {ExpectRef, Reply2} -> ?assertEqual({error, skipped}, Reply2)
    after 0 -> ?assert(false) end.

%% Delivery can race the selected slot closing. The destination rejects that
%% attempt; the origin treats the response as a hint and retargets its retained
%% submission after observing local exclusion.
closed_target_slot_is_rejected_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    L4 = quod_simplex:leader(4, Validators),
    {Me, MyId} = lists:keyfind(L4, 1, Committee),
    [{Author, AuthorId} | _] =
        [P || {Pub, _} = P <- Committee,
              Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"closed">>, [{assert, {{closed, fact}, true}}],
                   {Author, AuthorId}),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Closed = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 3, eng => E2}),
    ?assert(quod_simplex:proposal_visible(4, Closed)),
    ClosedOrigin =
        quod_simplex:test_relay_origin(Author, 4, Tx, Closed),
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, ClosedOrigin, Tx, Closed)),
    {Rejected, []} = quod_simplex:test_relayed_append(
                       Author, 4, Tx, Closed),
    {0, 0, #{}, []} = quod_simplex:test_ingress(Rejected),
    ?assertEqual(1, maps:get(r_redirect, quod_simplex:stats_map(Rejected))).

%% The pure decision function, cell by cell: exact target-slot ownership, the
%% barrier override, and FIFO egress.
route_decision_cells_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    L = fun(Slot) -> quod_simplex:leader(Slot, Validators) end,
    Outside = L(7),
    {Me, MyId} = lists:keyfind(Outside, 1, Committee),
    [{Author, AuthorId} | _] = [P || {Pub, _} = P <- Committee, Pub =/= Me],
    Tx = signed_tx(<<"t">>, <<"cell">>, [{assert, {{cell, fact}, true}}],
                   {Author, AuthorId}),
    Open = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, [])}),
    Origin4 = quod_simplex:test_relay_origin(Author, 4, Tx, Open),
    Origin7 = quod_simplex:test_relay_origin(Author, 7, Tx, Open),
    %% This node does not own target slot 4, so it refuses that placement.
    ?assertEqual(redirect,
                 quod_simplex:test_route(entry, Origin4, Tx, Open)),
    %% It does own target slot 7 and may safely hold it until that slot opens.
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, Origin7, Tx, Open)),
    %% The same exact-slot rule holds while the pipeline is full.
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5, eng => quod_simplex:eng_with_certs(3, [])}),
    BlockedOrigin7 =
        quod_simplex:test_relay_origin(Author, 7, Tx, Blocked),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, BlockedOrigin7, Tx, Blocked)),
    %% Another participant accepts only the slot it actually owns.
    {Far, FarId} = lists:keyfind(L(9), 1, Committee),
    BlockedFar = st(#{self => Far, id => FarId, validators => Validators,
                      sync => ready, slot => 3, approved => 5,
                      eng => quod_simplex:eng_with_certs(3, [])}),
    FarTx = signed_tx(<<"t">>, <<"cellf">>, [{assert, {{cellf, fact}, true}}],
                      {Author, AuthorId}),
    FarOrigin =
        quod_simplex:test_relay_origin(Author, 9, FarTx, BlockedFar),
    ?assertEqual({park, awaiting_turn},
                 quod_simplex:test_route(entry, FarOrigin, FarTx, BlockedFar)),
    %% consensus barrier: park UNCONDITIONALLY, both origins — the
    %% post-adoption schedule is unknowable until the committee block commits
    {MPub, MId} = id(),
    MTx = signed_tx(<<"t">>, <<"mb">>, [pa(MPub)], {MPub, MId}),
    MBlock = #block{slot = 4, parent = 3, payload = {batch, [MTx]}},
    {EngB0, _} = quod_simplex:eng_offer({block, MBlock},
                                        quod_simplex:eng_new(?DOMAIN, [MPub], 3)),
    {BarrierEng, _} = feed_shares(
                        [quod_simplex:make_share(?DOMAIN,
                           support, 4, quod_simplex:block_hash(MBlock), MId)],
                        EngB0),
    Barrier = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 3, eng => BarrierEng}),
    BarrierOrigin =
        quod_simplex:test_relay_origin(Author, 7, Tx, Barrier),
    ?assertEqual({park, barrier},
                 quod_simplex:test_route(entry, BarrierOrigin, Tx, Barrier)),
    ?assertEqual({park, barrier},
                 quod_simplex:test_route(entry, local, lt($m, Me), Barrier)),
    %% FIFO egress: with a live queue a local ENTRY joins the tail (ordered dispatch),
    %% while the DRAIN pass relays that same item to the first seat's leader
    Queued = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                  slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, []),
                  ingress => [{local, {self(), make_ref()}, lt($q, Me),
                               quod_time:mono_ms()}]}),
    ?assertEqual({park, fifo},
                 quod_simplex:test_route(entry, local, lt($n, Me), Queued)),
    ?assertEqual({relay, L(4), 4},
                 quod_simplex:test_route(drain, local, lt($q, Me), Queued)).

%% The round-phase probe follows an own proposal: stamped when the proposal seals
%% (mono-ms, approval mark still `none`), and pruned by finalize/2 — which both the
%% commit and skip paths run, so a probe entry can never outlive its slot.
round_probe_lifecycle_test() ->
    Committee = committee(3),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    Blocked = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                   slot => 3, approved => 5,
                   eng => quod_simplex:eng_with_certs(3, [])}),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Blocked)),
    F1 = {self(), make_ref()}, F2 = {self(), make_ref()},
    P2 = quod_simplex:test_state_set(
           ingress,
           [{local, F1, lt($p, Me), quod_time:mono_ms()},
            {local, F2, lt($q, Me), quod_time:mono_ms() + 1}],
           Blocked),
    %% pipeline opens => the multi-item drain seals OUR block for slot 4 => stamped
    {Drained, _} = quod_simplex:test_drain(quod_simplex:test_state_set(approved, 3, P2)),
    Probe = quod_simplex:test_round_probe(Drained),
    ?assertMatch(#{4 := {At, none}} when is_integer(At), Probe),
    %% the slot finalizing (commit OR skip both run finalize/2) prunes the entry
    Finalized = quod_simplex:finalize(4, Drained),
    ?assertEqual(#{}, quod_simplex:test_round_probe(Finalized)).

%% Creation owns the one-lane invariant: a future call site cannot silently add
%% a different target or slot to the map projected into the ingress view.
relay_lane_creation_rejects_divergent_target_test() ->
    Target4 = <<1:256>>,
    Target5 = <<2:256>>,
    S0 = st(#{}),
    {ok, S1} = quod_simplex:test_put_pending_relay(Target4, 4, S0),
    {ok, S2} = quod_simplex:test_put_pending_relay(Target4, 4, S1),
    ?assertEqual(
       [{Target4, 4}, {Target4, 4}],
       lists:sort([{Target, Slot}
                   || {_AttemptId, Target, Slot, _Deadline} <-
                          quod_simplex:test_relay_pending(S2)])),
    ?assertEqual(
       {error, {relay_lane_conflict,
                {Target4, 4, <<0:256>>},
                {Target5, 5, <<0:256>>}}},
       quod_simplex:test_put_pending_relay(Target5, 5, S2)),
    NewCommitteeId = crypto:hash(sha256, <<"new-relay-lane-view">>),
    NewView =
        quod_simplex:test_state_set(committee_id, NewCommitteeId, S2),
    ?assertEqual(
       {error, {relay_lane_conflict,
                {Target4, 4, <<0:256>>},
                {Target4, 4, NewCommitteeId}}},
       quod_simplex:test_put_pending_relay(Target4, 4, NewView)).

%% A defensive relay-lane conflict cannot classify retained content as skipped.
%% Keep the exact signed submission ready; once routed onto the extant lane it
%% must proceed internally without a public reply or a new signature.
retained_custody_relay_lane_conflict_defers_without_reply_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Leader5 = quod_simplex:leader(5, Validators),
    Leader6 = quod_simplex:leader(6, Validators),
    {Leader4, Leader4Id} = lists:keyfind(Leader4, 1, Committee),
    From = {self(), make_ref()},
    S = st(#{self => Leader4, id => Leader4Id,
             validators => Validators, sync => ready,
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From, lt($c, Leader4), S),
    [{SubmissionId, 1, Submission, {local, 4}, Deadline, 1}] =
        quod_simplex:test_custody(Collected),
    Ready0 = quod_simplex:finalize(4, Collected),
    Ready = quod_simplex:test_state_set(approved, 4, Ready0),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Ready),
    {ok, WithExistingLane} =
        quod_simplex:test_put_pending_relay(Leader5, 5, Ready),
    ExistingPending =
        quod_simplex:test_relay_pending(WithExistingLane),

    {Deferred, []} =
        quod_simplex:test_relay_custody(
          SubmissionId, Leader6, 6, WithExistingLane),
    ?assertEqual(
       ExistingPending, quod_simplex:test_relay_pending(Deferred)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Deferred)),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(Deferred))),
    assert_no_reply(From),

    %% The restored ready key is live, not merely retained in the custody map.
    {Retried, []} = quod_simplex:test_drain_custody(Deferred),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Leader5, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(2, length(quod_simplex:test_relay_pending(Retried))),
    assert_no_reply(From).

%% A malformed committee view cannot name an exact relay attempt. That is a
%% temporary placement refusal: the retained envelope must be re-indexed for an
%% internal retry, never released or reported as malformed/busy.
retained_custody_malformed_route_view_defers_without_reply_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} =
        ready_custody_fixture($d),
    ValidCommitteeId = quod_simplex:test_committee_id(Ready),
    MalformedView =
        quod_simplex:test_state_set(committee_id, <<1>>, Ready),

    %% Exercise the real ready-set drain while the refusal remains unchanged.
    %% Before the no-progress guard this recursed on the same restored key
    %% forever inside one consensus callback.
    {Deferred, []} = drain_custody_within(MalformedView),
    ?assertEqual([], quod_simplex:test_relay_pending(Deferred)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Deferred)),
    DeferredStats = quod_simplex:stats_map(Deferred),
    ?assertEqual(1, maps:get(custody_ready, DeferredStats)),
    ?assertEqual(0, maps:get(r_bad, DeferredStats)),
    ?assertEqual(0, maps:get(r_busy, DeferredStats)),
    assert_no_reply(From),

    Restored =
        quod_simplex:test_state_set(
          committee_id, ValidCommitteeId, Deferred),
    Retried =
        running_state(
          quod_simplex:test_keep_progress_transition(
            Deferred, Restored)),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Target, 5, ValidCommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(1, length(quod_simplex:test_relay_pending(Retried))),
    assert_no_reply(From).

%% Relay ownership has no compiled population threshold. More rows than the
%% retired 2048-entry cap cannot refuse an already-owned signed submission.
retained_custody_relay_has_no_population_cap_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} =
        ready_custody_fixture($e),
    Full =
        lists:foldl(
          fun(_, Acc) ->
                  {ok, Next} =
                      quod_simplex:test_put_pending_relay(
                        Target, 5, Acc),
                  Next
          end, Ready, lists:seq(1, 2048)),
    ExistingPending = quod_simplex:test_relay_pending(Full),
    ?assertEqual(2048, length(ExistingPending)),
    CommitteeId = quod_simplex:test_committee_id(Full),
    CustodyAttemptId =
        quod_transaction:relay_attempt_id(
          <<"t">>, SubmissionId, CommitteeId, 5, Target),
    ?assertNot(lists:keymember(CustodyAttemptId, 1, ExistingPending)),

    {Retried, []} = drain_custody_within(Full),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Target, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(2049, length(quod_simplex:test_relay_pending(Retried))),
    RetriedStats = quod_simplex:stats_map(Retried),
    ?assertEqual(0, maps:get(custody_ready, RetriedStats)),
    ?assertEqual(0, maps:get(r_bad, RetriedStats)),
    ?assertEqual(0, maps:get(r_busy, RetriedStats)),
    assert_no_reply(From).

%% A stale exact attempt collision is distinct from lane divergence: the
%% retained submission must neither overwrite the pending owner nor release its
%% caller. Removing that exact entry while another same-lane relay remains must
%% wake the real keep_progress drain even though lane and capacity stay stable.
retained_custody_duplicate_attempt_defers_and_wakes_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready} =
        ready_custody_fixture($f),
    CommitteeId = quod_simplex:test_committee_id(Ready),

    %% Derive the collision through the real relay-placement path, then copy
    %% only its opaque pending map onto the original ready state. This avoids a
    %% test-side reconstruction drifting from the production AttemptId recipe.
    {Placed, []} =
        quod_simplex:test_relay_custody(
          SubmissionId, Target, 5, Ready),
    [{AttemptId, Target, 5, Deadline}] =
        quod_simplex:test_relay_pending(Placed),
    ?assertEqual(
       quod_transaction:relay_attempt_id(
         <<"t">>, SubmissionId, CommitteeId, 5, Target),
       AttemptId),
    {ok, WithOther} =
        quod_simplex:test_put_pending_relay(Target, 5, Placed),
    PendingBefore =
        quod_simplex:test_relay_pending(WithOther),
    ?assertEqual(2, length(PendingBefore)),
    [OtherAttemptId] =
        [Id || {Id, _, 5, _} <- PendingBefore,
               Id =/= AttemptId],
    Collision =
        quod_simplex:test_copy_relay_pending(WithOther, Ready),

    {Deferred, []} = drain_custody_within(Collision),
    DeferredPending =
        quod_simplex:test_relay_pending(Deferred),
    ?assertEqual(2, length(DeferredPending)),
    ?assert(lists:keymember(AttemptId, 1, DeferredPending)),
    ?assert(lists:keymember(OtherAttemptId, 1, DeferredPending)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Deferred)),
    DeferredStats = quod_simplex:stats_map(Deferred),
    ?assertEqual(1, maps:get(custody_ready, DeferredStats)),
    ?assertEqual(0, maps:get(r_bad, DeferredStats)),
    ?assertEqual(0, maps:get(r_busy, DeferredStats)),
    assert_no_reply(From),

    Relieved =
        quod_simplex:test_remove_pending_relay(
          AttemptId, Deferred),
    [{OtherAttemptId, Target, 5, _OtherDeadline}] =
        quod_simplex:test_relay_pending(Relieved),
    Retried =
        running_state(
          quod_simplex:test_keep_progress_transition(
            Deferred, Relieved)),
    [{SubmissionId, 1, Submission,
      {relay, RetriedAttemptId, Target, 5, CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(AttemptId, RetriedAttemptId),
    RetriedPending =
        quod_simplex:test_relay_pending(Retried),
    ?assertEqual(2, length(RetriedPending)),
    ?assert(lists:keymember(AttemptId, 1, RetriedPending)),
    ?assert(lists:keymember(OtherAttemptId, 1, RetriedPending)),
    assert_no_reply(From).

%% During deep recovery the approved frontier can arrive before its block.
%% custody_sequence_status/2 must hold in that gap, then the exact transition
%% from "approved block absent" to "present" must wake keep_progress even
%% though every ordinary ingress-route component still has the same value.
retained_custody_approved_block_arrival_wakes_drain_test() ->
    {Target, From, SubmissionId, Submission, Deadline, Ready0} =
        ready_custody_fixture($h),
    {ok, Change} =
        decode_submission(<<"t">>, Submission),

    %% Recreate the recovery-only shape: durable H=3, approved H+1=4, but
    %% the locally retained notarized block for H+1 has not arrived yet.
    EmptyEng = quod_simplex:eng_new(?DOMAIN, [], 3),
    Gap0 =
        quod_simplex:test_state_set(
          eng, EmptyEng,
          quod_simplex:test_state_set(
            approved, 4,
            quod_simplex:test_state_set(slot, 3, Ready0))),
    ?assertNot(maps:is_key(4, quod_simplex:eng_tree(EmptyEng))),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(
         drain, {custody, SubmissionId}, Change, Gap0)),
    {Held, []} = quod_simplex:test_drain_custody(Gap0),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Held)),

    %% Insert the approved block through the real engine. It is below the
    %% routing Floor (5), contains no membership transition, and has no
    %% finalizer cert, so the ordinary-ingress view remains identical.
    RecoveryCommittee = committee(4),
    B4 = blk(4),
    {E1, []} =
        quod_simplex:eng_offer(
          {block, B4},
          quod_simplex:eng_new(?DOMAIN, pubs(RecoveryCommittee), 3)),
    {RecoveredEng, _} =
        feed_shares(
          supports(B4, RecoveryCommittee, 3), E1),
    ?assert(maps:is_key(
              4, quod_simplex:eng_tree(RecoveredEng))),
    Recovered =
        quod_simplex:test_state_set(eng, RecoveredEng, Held),
    ?assertNot(quod_simplex:test_ingress_needs_drain(Held, Recovered)),
    ?assertEqual(
       {relay, Target, 5},
       quod_simplex:test_route(
         drain, {custody, SubmissionId}, Change, Recovered)),

    Retried =
        running_state(
          quod_simplex:test_keep_progress_transition(
            Held, Recovered)),
    [{SubmissionId, 1, Submission,
      {relay, _AttemptId, Target, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Retried),
    ?assertEqual(1, length(quod_simplex:test_relay_pending(Retried))),
    assert_no_reply(From).

%% Demotion is not authoritative exclusion: the old exact relay attempt may
%% already commit under the adopted committee. Retain its immutable submission
%% to the original deadline, with no redirect, malformed alarm, or public retry.
retained_custody_demotion_remains_ambiguous_until_deadline_test() ->
    {Ns, OldCommitteeId, Slot, From, Target, Validators,
     SubmissionId, AttemptId, _Frame, Sent} =
        outbound_fixture(<<"custody-demotion">>),
    [{SubmissionId, 1, Submission,
      {relay, AttemptId, Target, Slot, OldCommitteeId}, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    {ok, Change = #transaction{author = Author}} =
        decode_submission(Ns, Submission),

    %% Also pin the defensive sibling: after custody, a changed local validity
    %% view is ambiguity, never retroactive bad input.
    Capable =
        quod_simplex:test_state_set(validators, [Author], Sent),
    ?assert(quod_simplex:may_vote(Capable)),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(
         drain, {custody, SubmissionId},
         Change#transaction{origin = {<<"other">>, <<0:256>>}}, Capable)),

    Remaining = lists:delete(Author, Validators),
    NewCommitteeId =
        crypto:hash(sha256, <<"custody-demotion-new-view">>),
    ?assertNotEqual(OldCommitteeId, NewCommitteeId),
    Demoted =
        quod_simplex:test_state_set(
          committee_id, NewCommitteeId,
          quod_simplex:test_state_set(
            validators, Remaining, Sent)),
    {keep_state, Parked, Actions} =
        quod_simplex:test_keep_progress_transition(Sent, Demoted),
    ?assertNot(lists:keymember(reply, 1, Actions)),
    ?assertEqual([], quod_simplex:test_relay_pending(Parked)),
    ?assertEqual(
       [{SubmissionId, 1, Submission, ready, Deadline, 1}],
       quod_simplex:test_custody(Parked)),
    ParkedStats = quod_simplex:stats_map(Parked),
    ?assertEqual(1, maps:get(custody_ready, ParkedStats)),
    ?assertEqual(0, maps:get(r_bad, ParkedStats)),
    ?assertEqual(0, maps:get(r_redirect, ParkedStats)),
    ?assertEqual(0, maps:get(r_stale, ParkedStats)),
    ?assertEqual({Parked, []}, quod_simplex:test_drain_custody(Parked)),
    assert_no_reply(From),

    Expired = quod_simplex:test_expire_custody(Parked),
    ?assertEqual([], quod_simplex:test_custody(Expired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Expired)),
    {_, ExpectRef} = From,
    receive
        {ExpectRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    assert_no_reply(From).

ready_custody_fixture(TxSuffix) ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Target = quod_simplex:leader(5, Validators),
    {Leader4, Leader4Id} = lists:keyfind(Leader4, 1, Committee),
    From = {self(), make_ref()},
    S = st(#{self => Leader4, id => Leader4Id,
             validators => Validators, sync => ready,
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From, lt(TxSuffix, Leader4), S),
    [{SubmissionId, 1, Submission, {local, 4}, Deadline, 1}] =
        quod_simplex:test_custody(Collected),
    Ready =
        quod_simplex:test_state_set(
          approved, 4, quod_simplex:finalize(4, Collected)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Ready),
    {Target, From, SubmissionId, Submission, Deadline, Ready}.

admission_change_retires_exact_signed_custody_test() ->
    {_Ns, _CommitteeId, _Slot, From, _Target, Validators,
     _SubmissionId, _AttemptId, _Frame, Sent} =
        outbound_fixture(<<"admission-retired">>),
    [Author] = quod_simplex:test_custody_authors(Sent),
    ?assert(lists:member(Author, Validators)),
    [Other | _] = Validators -- [Author],
    OtherOld = quod_simplex:test_author_admission(Other),
    Unrelated = quod_simplex:test_retire_changed_admissions(
                  #{Other => OtherOld}, #{Other => <<98:256>>}, Sent),
    ?assertEqual(quod_simplex:test_custody(Sent),
                 quod_simplex:test_custody(Unrelated)),
    ?assertEqual(quod_simplex:test_relay_pending(Sent),
                 quod_simplex:test_relay_pending(Unrelated)),
    Old = quod_simplex:test_author_admission(Author),
    Retired = quod_simplex:test_retire_changed_admissions(
                #{Author => Old}, #{Author => <<99:256>>}, Sent),
    ?assertEqual([], quod_simplex:test_custody(Retired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Retired)),
    {_, ReplyRef} = From,
    receive
        {ReplyRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end.

%% A committee-view change can race a locally collected custody lane before
%% the normal reconciliation hook retires it. The next ordinary write must wait
%% unsigned for that transition; a lane mismatch is placement state, not a
%% malformed transaction and therefore must not increment r_bad or reply.
committee_view_lane_conflict_parks_without_bad_change_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Me = quod_simplex:leader(4, Validators),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    OldCommitteeId =
        crypto:hash(sha256, <<"placement-conflict-old-view">>),
    NewCommitteeId =
        crypto:hash(sha256, <<"placement-conflict-new-view">>),
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators,
             committee_id => OldCommitteeId,
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From1, lt($v, Me), S),
    [{_SubmissionId, 1, _Submission, {local, 4},
      _Deadline, 1}] =
        quod_simplex:test_custody(Collected),
    NewView =
        quod_simplex:test_state_set(
          committee_id, NewCommitteeId, Collected),
    Next = lt($w, Me),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(entry, local, Next, NewView)),

    {Parked, []} =
        quod_simplex:test_append(From2, Next, NewView),
    [{_SameSubmissionId, 1, _SameSubmission, {local, 4},
      _SameDeadline, 1}] =
        quod_simplex:test_custody(Parked),
    {1, _, #{Me := 1}, [{local, NextId, _}]} =
        quod_simplex:test_ingress(Parked),
    ?assertEqual(Next#transaction.tx_id, NextId),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(Parked))),
    {StillParked, _} = quod_simplex:test_drain(Parked),
    {1, _, #{Me := 1}, [{local, NextId, _}]} =
        quod_simplex:test_ingress(StillParked),
    ?assertEqual(0, maps:get(r_bad, quod_simplex:stats_map(StillParked))),
    assert_no_reply(From1),
    assert_no_reply(From2).

%% A burst stays on one exact-slot lane while that slot is open. Once the local
%% frontier sees it close, later sequences queue until the old lane resolves.
stable_relay_lane_preserves_author_order_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Target5 = quod_simplex:leader(5, Validators),
    Me = hd(Validators -- [Target4, Target5]),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, [])}),
    From1 = {self(), make_ref()},
    From2 = {self(), make_ref()},
    {Sent1, []} = quod_simplex:test_append(From1, lt($r, Me), S),
    [{Attempt1, LaneTarget, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent1),
    [{Submission1, 1, Signed1,
      {relay, Attempt1, LaneTarget, 4, _CommitteeId}, Deadline, 1}] =
        quod_simplex:test_custody(Sent1),
    %% Locally, slot 4 closes and a fresh route would now choose leader(5).
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Advanced = quod_simplex:test_state_set(eng, E2, Sent1),
    ?assert(quod_simplex:proposal_visible(4, Advanced)),
    ?assertEqual(
       {relay, Target5, 5},
       quod_simplex:test_route(entry, local, lt($x, Me),
                          quod_simplex:test_state_set(eng, E2, S))),
    Later = lt($s, Me),
    {Sent2, []} =
        quod_simplex:test_append(From2, Later, Advanced),
    [{Attempt1, LaneTarget, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent2),
    {1, _, _, [{local, LaterId, _}]} = quod_simplex:test_ingress(Sent2),
    ?assertEqual(Later#transaction.tx_id, LaterId),
    Finalized = quod_simplex:finalize(4, Sent2),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    [{Submission1, 1, Signed1, ready, Deadline, 1}] =
        quod_simplex:test_custody(Finalized),
    assert_no_reply(From1),
    assert_no_reply(From2),

    %% Retained signed work drains before the later unsigned queue entry. The
    %% first placement gets a new attempt id but keeps the exact signed envelope
    %% and original deadline.
    Open = quod_simplex:test_state_set(
             outbox, #{},
             quod_simplex:test_state_set(approved, 4, Finalized)),
    {Retargeted, []} = quod_simplex:test_drain_custody(Open),
    [{Attempt2, Target5, 5, Deadline}] =
        quod_simplex:test_relay_pending(Retargeted),
    ?assertNotEqual(Attempt1, Attempt2),
    [{Submission1, 1, Signed1,
      {relay, Attempt2, Target5, 5, _CommitteeId2}, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    {1, _, _, [{local, LaterId, _}]} =
        quod_simplex:test_ingress(Retargeted),

    %% Only after sequence 1 is placed again may sequence 2 leave the unsigned
    %% queue; both then share the same exact lane in author order.
    {SentBoth, []} = quod_simplex:test_drain(Retargeted),
    {0, 0, _, []} = quod_simplex:test_ingress(SentBoth),
    ?assertEqual(
       [1, 2],
       lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                           _Deadline, _Attempts} <-
                              quod_simplex:test_custody(SentBoth)])),
    ?assertEqual(
       [{Target5, 5}, {Target5, 5}],
       lists:sort([{Target, Slot}
                   || {_Id, _Seq, _Submission,
                       {relay, _Attempt, Target, Slot, _View},
                       _Deadline, _Attempts} <-
                          quod_simplex:test_custody(SentBoth)])),
    ?assertEqual(
       1, maps:get(ingress_retargets,
                   quod_simplex:stats_map(SentBoth))),

    %% Source submissions never enter the bounded consensus outbox. When the
    %% link opens, the complete retained prefix is reconstructed from custody
    %% and emitted in author-sequence order, with the exact signed envelopes.
    ?assertEqual(#{}, quod_simplex:test_outbox(SentBoth)),
    RelayChan = quod_simplex:test_relay_chan(SentBoth),
    {keep_state, Linked, _Actions} =
        quod_simplex:running(
          info, {link_up, Target5, RelayChan, self()}, SentBoth),
    Frames = [receive_ordered_frame(), receive_ordered_frame()],
    BySeq =
        maps:from_list(
          [{Seq, Signed}
           || {_Id, Seq, Signed, _Placement, _Deadline, _Attempts} <-
                  quod_simplex:test_custody(SentBoth)]),
    DecodedPrefix =
        [begin
             {relay,
              {relay_submit, _SubmissionId, _AttemptId, _View,
               5, Signed, _Carrier}} =
                 quod_relay:decode_relay_frame(Frame, <<"t">>),
             {ok, Tx} =
                 decode_submission(<<"t">>, Signed),
             {Tx#transaction.author_seq, Signed}
         end || Frame <- Frames],
    ?assertEqual(
       [{1, maps:get(1, BySeq)}, {2, maps:get(2, BySeq)}],
       DecodedPrefix),
    ?assertEqual(#{}, quod_simplex:test_outbox(Linked)),
    flush_unordered_link_frames(),
    assert_no_reply(From1),
    assert_no_reply(From2).

%% A lane may hold several exact signed placements. Expiring one member must
%% retain the lane while others remain; finalizing that lane must derive the
%% complete remaining cohort from custody, make every member ready, and clear
%% the old lane so the cohort can retarget together.
same_lane_partial_completion_and_finalization_retargets_cohort_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Target5 = quod_simplex:leader(5, Validators),
    Me = hd(Validators -- [Target4, Target5]),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    Base = st(#{self => Me, id => MyId, validators => Validators,
                sync => ready, slot => 3, approved => 3,
                eng => quod_simplex:eng_with_certs(3, [])}),
    ExpiredFrom = {self(), make_ref()},
    ExpiredAt = quod_time:mono_ms() - 60000,
    Parked = quod_simplex:test_state_set(
               ingress,
               [{local, ExpiredFrom, lt($1, Me), ExpiredAt}],
               Base),
    {Sent1, []} = quod_simplex:test_drain(Parked),
    From2 = {self(), make_ref()},
    From3 = {self(), make_ref()},
    From4 = {self(), make_ref()},
    {Sent2, []} = quod_simplex:test_append(From2, lt($2, Me), Sent1),
    {Sent3, []} = quod_simplex:test_append(From3, lt($3, Me), Sent2),
    {Sent4, []} = quod_simplex:test_append(From4, lt($4, Me), Sent3),
    ?assertEqual(
       [1, 2, 3, 4],
       lists:sort(
         [Seq || {_Id, Seq, _Submission, _Placement,
                  _Deadline, _Attempts} <-
                     quod_simplex:test_custody(Sent4)])),

    %% Make slot 4 visibly closed. With a surviving lane, a fresh local write
    %% must remain behind it instead of independently choosing slot 5.
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    Visible = quod_simplex:test_state_set(eng, E2, Sent4),
    {keep_state, OneExpired, _TickActions} =
        quod_simplex:running({timeout, tick}, tick, Visible),
    receive
        {Tag, Reply} when Tag =:= element(2, ExpiredFrom) ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    Remaining = quod_simplex:test_custody(OneExpired),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                                      _Deadline, _Attempts} <- Remaining])),
    ?assert(
       lists:all(
         fun({_Id, _Seq, _Submission,
              {relay, _Attempt, ActualTarget, 4, _View},
              _Deadline, 1}) -> ActualTarget =:= Target4;
            (_) -> false
         end, Remaining)),
    ?assertEqual(
       {park, fifo},
       quod_simplex:test_route(
         entry, local, lt($5, Me), OneExpired)),

    Finalized = quod_simplex:finalize(4, OneExpired),
    Ready = quod_simplex:test_custody(Finalized),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, ready,
                                      _Deadline, 1} <- Ready])),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),

    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          quod_simplex:test_state_set(approved, 4, Finalized)),
    RetargetedCustody = quod_simplex:test_custody(Retargeted),
    ?assertEqual([2, 3, 4],
                 lists:sort([Seq || {_Id, Seq, _Submission, _Placement,
                                      _Deadline, _Attempts} <-
                                         RetargetedCustody])),
    ?assert(
       lists:all(
         fun({_Id, _Seq, _Submission,
              {relay, _Attempt, ActualTarget, 5, _View},
              _Deadline, 2}) -> ActualTarget =:= Target5;
            (_) -> false
         end, RetargetedCustody)),
    ?assertEqual(3, length(quod_simplex:test_relay_pending(Retargeted))),
    assert_no_reply(From2),
    assert_no_reply(From3),
    assert_no_reply(From4).

%% Ready custody always precedes this author's later unsigned ingress. In
%% particular, a large lower sequence that cannot fit the remaining active
%% batch must stop a later small write that otherwise could join and commit.
ready_lower_sequence_capacity_block_prevents_local_overtake_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Target4 = quod_simplex:leader(4, Validators),
    Me = quod_simplex:leader(5, Validators),
    ?assertNotEqual(Target4, Me),
    {Me, MyId} = lists:keyfind(Me, 1, Committee),
    [{FillerAuthor, FillerId} | _] =
        [Member || {Pub, _} = Member <- Committee, Pub =/= Me],
    Lower = bind_test_id(
        #transaction{
           tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
           proof_id = <<0:256>>, plan_digest = <<0:256>>,
           goal = durable_goal(ready_lower), result = durable_result(),
           author = Me, sig = none, read_check = #{},
           diff =
               [{assert,
                 {{blob, binary:copy(<<1>>, 90000)}, true}}]}),
    Filler =
        signed_tx(
          <<"t">>, <<"ready-order-filler">>,
          [{assert, {{blob, binary:copy(<<2>>, 190000)}, true}}],
          {FillerAuthor, FillerId}),
    Small = bind_test_id(
        #transaction{
           tx_id = <<>>, origin = {<<"t">>, <<0:256>>},
           proof_id = <<0:256>>, plan_digest = <<0:256>>,
           goal = durable_goal(later_small), result = durable_result(),
           author = Me, sig = none, read_check = #{},
           diff = [{assert, {{later, small}, true}}]}),
    Current =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 4, approved => 4,
             eng => quod_simplex:eng_with_certs(4, [])}),

    %% The small write genuinely fits beside the filler when no retained lower
    %% sequence owns priority.
    {ControlBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Current),
    ?assertEqual(
       {collect, 5},
       quod_simplex:test_route(entry, local, Small, ControlBatch)),

    LowerFrom = {self(), make_ref()},
    Before =
        st(#{self => Me, id => MyId, validators => Validators,
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Placed, []} =
        quod_simplex:test_append(LowerFrom, Lower, Before),
    [{SubmissionId, 1, Submission, _Placement, Deadline, 1}] =
        quod_simplex:test_custody(Placed),
    Ready =
        quod_simplex:test_state_set(
          approved, 4, quod_simplex:finalize(4, Placed)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Ready),
    {ok, SignedLower} =
        decode_submission(<<"t">>, Submission),
    {WithBatch, _} =
        quod_simplex:test_relayed_append(
          FillerAuthor, Filler, Ready),
    ?assertEqual(
       {park, awaiting_turn},
       quod_simplex:test_route(
         drain, {custody, SubmissionId}, SignedLower, WithBatch)),

    SmallFrom = {self(), make_ref()},
    {ParkedSmall, []} =
        quod_simplex:test_append(SmallFrom, Small, WithBatch),
    {1, _, #{Me := 1}, [{local, SmallId, _}]} =
        quod_simplex:test_ingress(ParkedSmall),
    ?assertEqual(Small#transaction.tx_id, SmallId),
    {CustodyHeld, []} =
        quod_simplex:test_drain_custody(ParkedSmall),
    {StillHeld, []} = quod_simplex:test_drain(CustodyHeld),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(StillHeld),
    {1, _, #{Me := 1}, [{local, SmallId, _}]} =
        quod_simplex:test_ingress(StillHeld),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(StillHeld))),
    assert_no_reply(LowerFrom),
    assert_no_reply(SmallFrom).

%% Membership is the deliberate contrast to retained ordinary writes. Drive
%% both committee operations (admit/assert and remove/retract) through real
%% local signing and outbound relay, then close the exact slot: neither
%% direction may enter custody or retarget, and both retain terminal `skipped`.
local_membership_exclusion_is_terminal_without_custody_test() ->
    Ns = <<"t">>,
    Committee = committee(4),
    Validators = pubs(Committee),
    Slot = 4,
    Target = quod_simplex:leader(Slot, Validators),
    {Me, MyId} =
        hd([Member || {Pub, _} = Member <- Committee, Pub =/= Target]),
    {NewMember, _NewMemberId} = id(),
    RemovedMember = hd(Validators -- [Me]),
    Cases =
        [{<<"admit">>, [pa(NewMember)]},
         {<<"remove">>, [rm(RemovedMember)]}],
    _ =
        [begin
             CommitteeId =
                 crypto:hash(
                   sha256,
                   <<"membership-no-custody-view:", Kind/binary>>),
             From = {self(), make_ref()},
             Change = bind_test_id(
                 #transaction{
                    tx_id = <<>>,
                    origin = {Ns, <<0:256>>},
                    proof_id = <<0:256>>, plan_digest = <<0:256>>,
                    goal = durable_goal({membership, Kind}),
                    result = durable_result(),
                    author = Me, sig = none,
                    read_check = #{}, diff = Diff}),
             S = st(#{self => Me, id => MyId,
                      validators => Validators,
                      committee_id => CommitteeId,
                      relay_conns =>
                          #{Target => {self(), make_ref()}},
                      sync => ready, slot => 3, approved => 3,
                      eng =>
                          quod_simplex:eng_with_certs(3, [])}),

             {Sent, []} =
                 quod_simplex:test_append(From, Change, S),
             Frame = receive_ordered_frame(),
             {relay,
              {relay_submit, SubmissionId, AttemptId,
               CommitteeId, Slot, Submission, _Carrier}} =
                 quod_relay:decode_relay_frame(Frame, Ns),
             ?assert(
                quod_transaction:verify_submission(Submission)),
             {ok, Signed} =
                 decode_submission(Ns, Submission),
             ?assert(quod_transaction:verify(
                       test_binding(Ns, Signed#transaction.author), Signed)),
             ?assertEqual(Me, Signed#transaction.author),
             ?assertEqual(1, Signed#transaction.author_seq),
             ?assertEqual(Diff, Signed#transaction.diff),
             ?assertEqual(
                SubmissionId,
                quod_transaction:submission_id(Submission)),
             [{AttemptId, Target, Slot, _Deadline}] =
                 quod_simplex:test_relay_pending(Sent),
             ?assertEqual([], quod_simplex:test_custody(Sent)),

             Finalized = quod_simplex:finalize(Slot, Sent),
             ?assertEqual(
                [], quod_simplex:test_relay_pending(Finalized)),
             ?assertEqual(
                [], quod_simplex:test_custody(Finalized)),
             receive
                 {Tag, Reply} when Tag =:= element(2, From) ->
                     ?assertEqual({error, skipped}, Reply)
             after 0 ->
                 ?assert(false)
             end,
             {AfterDrain, []} =
                 quod_simplex:test_drain_custody(Finalized),
             ?assertEqual(
                [], quod_simplex:test_custody(AfterDrain)),
             ?assertEqual(
                [], quod_simplex:test_relay_pending(AfterDrain)),
             assert_no_reply(From)
         end || {Kind, Diff} <- Cases],
    ok.

%% A locally collected ordinary write has the same custody semantics as an
%% outbound relay. Finalizing its slot without inclusion does not answer the
%% caller; the exact signed submission is placed at the next usable seat.
local_exclusion_retains_exact_submission_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Leader5 = quod_simplex:leader(5, Validators),
    {Leader4, Leader4Id} = lists:keyfind(Leader4, 1, Committee),
    From = {self(), make_ref()},
    S = st(#{self => Leader4, id => Leader4Id,
             validators => Validators, sync => ready,
             slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Collected, _BatchActions} =
        quod_simplex:test_append(From, lt($l, Leader4), S),
    [{SubmissionId, 1, Submission, {local, 4}, Deadline, 1}] =
        quod_simplex:test_custody(Collected),

    Excluded = quod_simplex:finalize(4, Collected),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Excluded),
    assert_no_reply(From),

    {Placed, []} =
        quod_simplex:test_drain_custody(
          quod_simplex:test_state_set(approved, 4, Excluded)),
    [{AttemptId, Leader5, 5, Deadline}] =
        quod_simplex:test_relay_pending(Placed),
    [{SubmissionId, 1, Submission,
      {relay, AttemptId, Leader5, 5, _CommitteeId}, Deadline, 2}] =
        quod_simplex:test_custody(Placed),
    assert_no_reply(From).

%% A request for the next slot may arrive early and wait at that exact proposer;
%% when the parent approves it enters the intended block without another hop.
future_target_drains_at_declared_slot_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Holder = quod_simplex:leader(5, Validators),
    {Holder, HolderId} = lists:keyfind(Holder, 1, Committee),
    [{Author, AuthorId} | _] = [P || {Pub, _} = P <- Committee, Pub =/= Holder],
    Tx = signed_tx(<<"t">>, <<"custody">>,
                   [{assert, {{custody, stable}, true}}], {Author, AuthorId}),
    Before = st(#{self => Holder, id => HolderId, validators => Validators,
                  sync => ready, slot => 3, approved => 3,
                  eng => quod_simplex:eng_with_certs(3, [])}),
    {Held, []} = quod_simplex:test_relayed_append(
                   Author, 5, Tx, Before),
    {1, _, _, _} = quod_simplex:test_ingress(Held),
    B4 = blk(4),
    {E1, _} = quod_simplex:eng_offer(
                {block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    {E2, _} = feed_shares(supports(B4, Committee, 3), E1),
    AtTurn = quod_simplex:test_state_set(
               approved, 4, quod_simplex:test_state_set(eng, E2, Held)),
    {Drained, _} = quod_simplex:test_drain(AtTurn),
    {0, 0, _, []} = quod_simplex:test_ingress(Drained),
    ?assertEqual(1, maps:get(appends, quod_simplex:stats_map(Drained))).

%% A target refusal is only a recovery hint: a Byzantine destination cannot
%% make the author retry an attempt that may still commit. The origin's own
%% finalized slot is the authority that makes the retained submission eligible
%% for an internal placement at the next usable seat.
stale_target_hint_waits_for_local_finality_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader4 = quod_simplex:leader(4, Validators),
    Leader5 = quod_simplex:leader(5, Validators),
    {Me, MyId} =
        hd([P || {Pub, _} = P <- Committee,
                 Pub =/= Leader4, Pub =/= Leader5]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(3, []),
             ingress => [{local, From, lt($u, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{AttemptId, Target, 4, Deadline}] =
        quod_simplex:test_relay_pending(Sent),
    [{SubmissionId, 1, Submission, _Placement, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    Hinted = quod_simplex:test_relay_result(
               Target, AttemptId, {error, not_in_charge, none}, Sent),
    [{AttemptId, Target, 4, _Deadline, true}] =
        quod_simplex:test_relay_pending_detail(Hinted),
    Tag = element(2, From),
    receive
        {Tag, _ForgedOutcome} -> ?assert(false)
    after 0 ->
        ok
    end,
    Finalized = quod_simplex:finalize(4, Hinted),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Finalized),
    assert_no_reply(From),
    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          quod_simplex:test_state_set(approved, 4, Finalized)),
    [{Attempt2, _Target2, 5, Deadline}] =
        quod_simplex:test_relay_pending(Retargeted),
    ?assertNotEqual(AttemptId, Attempt2),
    [{SubmissionId, 1, Submission, _Placement2, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    assert_no_reply(From).

%% Receipt acknowledgement marks the exact retained attempt without creating a
%% retry clock. A spoofed acknowledgement from another peer cannot alter it.
relay_accepted_is_exact_and_timer_free_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    ImmediateLeader = quod_simplex:leader(4, Validators),
    {Me, MyId} = hd([P || {Pub, _} = P <- Committee,
                          Pub =/= ImmediateLeader]),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
             slot => 3, approved => 3, eng => quod_simplex:eng_with_certs(0, []),
             ingress => [{local, From, lt($t, Me), quod_time:mono_ms()}]}),
    {Sent, []} = quod_simplex:test_drain(S),
    [{AttemptId, Target, 4, _Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Sent),
    [Other | _] = Validators -- [Target],
    ?assertEqual(quod_simplex:test_relay_pending_detail(Sent),
                 quod_simplex:test_relay_pending_detail(
                   quod_simplex:test_relay_accepted(
                     Other, AttemptId, Sent))),
    Accepted =
        quod_simplex:test_relay_accepted(Target, AttemptId, Sent),
    [{AttemptId, Target, 4, _Deadline2, true}] =
        quod_simplex:test_relay_pending_detail(Accepted),
    ?assertEqual(1, maps:get(relay_accepted, quod_simplex:stats_map(Accepted))).

%% Duplicate requests are acknowledged again so a sender that missed the first
%% acknowledgement can stop retrying. Deduplication remains before signature work.
duplicate_inflight_relay_is_acknowledged_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"duplicate-inflight">>),
    {Accepted, _Actions} = quod_simplex:test_dispatch_relay(
                             Author, Submit, S),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    {Acked, []} = quod_simplex:test_dispatch_relay(
                    Author, Submit, Accepted),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Acked)),
    ?assertEqual(1, maps:get(relay_duplicates, quod_simplex:stats_map(Acked))).

%% An exact inflight attempt remains answerable after the current committee
%% view advances. Current-view equality gates first admission, not recovery.
inflight_attempt_is_answerable_after_view_change_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"serve-inflight">>),
    {Accepted, _Actions} =
        quod_simplex:test_dispatch_relay(Author, Submit, S),
    ?assertEqual(
       {[], [AttemptId], []},
       quod_simplex:test_relay_state_keys(Accepted)),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),

    NewCommitteeId = crypto:hash(sha256, <<"later-view">>),
    Advanced =
        quod_simplex:test_state_set(
          committee_id, NewCommitteeId, Accepted),
    {Duplicate, []} =
        quod_simplex:test_dispatch_relay(Author, Submit, Advanced),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Duplicate)),
    ?assertEqual(
       1, maps:get(relay_duplicates, quod_simplex:stats_map(Duplicate))).

%% Completed attempts are cached by their immutable full relay reference. A
%% duplicate old-view submit is served from that stored context even after both
%% the local frontier and committee view have advanced.
cached_result_is_served_after_view_change_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, S} =
        relay_receiver_fixture(<<"serve-cache">>),
    {Accepted, _} = quod_simplex:test_dispatch_relay(Author, Submit, S),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId, CommitteeId, Slot},
       receive_relay_control(Ns)),
    Completed = quod_simplex:finalize(Slot, Accepted),
    ?assertEqual(
       {[], [], [AttemptId]},
       quod_simplex:test_relay_state_keys(Completed)),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),

    Advanced =
        quod_simplex:test_state_set(
          committee_id, crypto:hash(sha256, <<"post-cache-view">>),
          Completed),
    {Replayed, []} =
        quod_simplex:test_dispatch_relay(Author, Submit, Advanced),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Replayed)).

%% Destination relay caches are volatile. After a restart, the durable target
%% slot is the authority: an included SubmissionId reconstructs the exact
%% attempt success without re-admitting it. The opaque signature is still
%% verified before any recovery lookup.
destination_restart_reconstructs_committed_result_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, Validators,
     SubmissionId, AttemptId,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      Submission, _Carrier} = Submit,
     Initial} =
        relay_receiver_fixture(<<"restart-committed">>),
    {ok, Transaction} =
        decode_submission(Ns, Submission),
    Dir = relay_store_dir("committed"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    Entries =
        [#entry{index = I, data = noop, timestamp = I}
         || I <- lists:seq(1, Slot - 1)]
        ++ [#entry{index = Slot,
                   data = {batch, [Transaction]},
                   timestamp = Slot}],
    {ok, Store1} = quod_ledger_store:append(Store0, Entries),
    try
        Restarted =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_state_set(
                committee_id, crypto:hash(sha256, <<"post-restart-view">>),
                quod_simplex:test_state_set(
                  store, Store1,
                  quod_simplex:test_state_set(slot, Slot, Initial)))),
        %% Exercise the real mailbox boundary after this former proposer has
        %% been removed from the voting set. Relay recovery must remain live
        %% for observers even though consensus frames are ignored there.
        Observer =
            quod_simplex:test_state_set(
              validators, Validators -- [Target], Restarted),
        ?assertEqual(false, quod_simplex:is_participant(Observer)),
        ?assertEqual({[], [], []},
                     quod_simplex:test_relay_state_keys(Observer)),
        Payload = quod_relay:encode(Ns, Submit),
        {keep_state, Reconstructed, _Actions} =
            quod_simplex:running(
              info,
              {quod_message, {{Author, ignored}, self()},
               quod_simplex:test_relay_chan(Observer), Payload},
              Observer),
        ?assertEqual(
           {relay_result, SubmissionId, AttemptId, CommitteeId,
            Slot, {ok, Slot}},
           receive_relay_control(Ns)),
        ?assertEqual(#{}, quod_simplex:test_outbox(Reconstructed)),
        ?assertEqual(
           {[], [], [AttemptId]},
           quod_simplex:test_relay_state_keys(Reconstructed))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% The authenticated transport peer must be the signed submission author
%% before any volatile-cache or durable-log recovery lookup. Otherwise an
%% attacker could pre-play somebody else's valid envelope and poison the
%% attempt cache, or replay a cached result onto an attacker-owned outbox.
non_author_replay_cannot_poison_or_read_result_cache_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, _Validators,
     SubmissionId, AttemptId,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      Submission, _Carrier} = Submit,
     Initial} =
        relay_receiver_fixture(<<"non-author-replay">>),
    {ok, Transaction} =
        decode_submission(Ns, Submission),
    Dir = relay_store_dir("non_author_replay"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    Entries =
        [#entry{index = I, data = noop, timestamp = I}
         || I <- lists:seq(1, Slot - 1)]
        ++ [#entry{index = Slot,
                   data = {batch, [Transaction]},
                   timestamp = Slot}],
    {ok, Store1} = quod_ledger_store:append(Store0, Entries),
    try
        Restarted =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_state_set(
                store, Store1,
                quod_simplex:test_state_set(slot, Slot, Initial))),

        {RejectedBeforeLookup, []} =
            quod_simplex:test_dispatch_relay(Target, Submit, Restarted),
        ?assertEqual({[], [], []},
                     quod_simplex:test_relay_state_keys(
                       RejectedBeforeLookup)),
        ?assertEqual(#{},
                     quod_simplex:test_outbox(RejectedBeforeLookup)),
        assert_no_relay_control(),

        {Recovered, []} =
            quod_simplex:test_dispatch_relay(
              Author, Submit, RejectedBeforeLookup),
        ?assertEqual({[], [], [AttemptId]},
                     quod_simplex:test_relay_state_keys(Recovered)),
        ?assertEqual(
           {relay_result, SubmissionId, AttemptId, CommitteeId,
            Slot, {ok, Slot}},
           receive_relay_control(Ns)),

        Cached = Recovered,
        CachedEntries = quod_simplex:test_relay_result_entries(Cached),
        {RejectedCachedReplay, []} =
            quod_simplex:test_dispatch_relay(Target, Submit, Cached),
        ?assertEqual(CachedEntries,
                     quod_simplex:test_relay_result_entries(
                       RejectedCachedReplay)),
        ?assertEqual(#{},
                     quod_simplex:test_outbox(RejectedCachedReplay)),
        assert_no_relay_control()
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% Even an authenticated transport peer claiming the envelope's author cannot
%% use a bad signature to prune/read/populate recovery state. Pin this against a
%% durable target slot: the old ordering reconstructed and cached an exclusion
%% before it reached signature verification.
invalid_signature_precedes_cache_and_durable_recovery_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, Validators,
     _SubmissionId, _AttemptId,
     {relay_submit, _, _, _, _, {submit, Author, Signature, Canonical}, Carrier},
     Initial} =
        relay_receiver_fixture(<<"invalid-before-recovery">>),
    InvalidSubmission = {submit, Author, flip1(Signature), Canonical},
    InvalidSubmissionId =
        quod_transaction:submission_id(InvalidSubmission),
    InvalidAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, InvalidSubmissionId, CommitteeId, Slot, Target),
    InvalidSubmit =
        {relay_submit, InvalidSubmissionId, InvalidAttemptId, CommitteeId,
         Slot, InvalidSubmission, Carrier},
    Dir = relay_store_dir("invalid_before_recovery"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} =
        quod_ledger_store:append(
          Store0,
          [#entry{index = I, data = noop, timestamp = I}
           || I <- lists:seq(1, Slot)]),
    try
        Durable =
            quod_simplex:test_state_set(
              store, Store1,
              quod_simplex:test_state_set(slot, Slot, Initial)),
        SeedSubmissionId = <<16#A5:128>>,
        SeedAttemptId = <<16#5A:128>>,
        WithExpiredResult =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_expire_relay_results(
                quod_simplex:test_reply_relay(
                  Author, SeedSubmissionId, SeedAttemptId, CommitteeId,
                  Slot, {error, skipped}, Durable))),
        ?assertEqual(
           {relay_result, SeedSubmissionId, SeedAttemptId, CommitteeId,
            Slot, {error, skipped}},
           receive_relay_control(Ns)),
        [{SeedAttemptId, {error, skipped}, ExpiredAt}] =
            quod_simplex:test_relay_result_entries(WithExpiredResult),
        ?assert(ExpiredAt =< quod_time:mono_ms()),

        {Rejected, []} =
            quod_simplex:test_dispatch_relay(
              Author, InvalidSubmit, WithExpiredResult),
        ?assertEqual(WithExpiredResult, Rejected),
        ?assertEqual(#{}, quod_simplex:test_outbox(Rejected)),
        ?assertEqual(
           {[], [], [SeedAttemptId]},
           quod_simplex:test_relay_state_keys(Rejected)),
        assert_no_relay_control(),

        %% The observer mailbox uses the same guarded recovery path after a
        %% proposer is demoted; it must not reintroduce the pre-verify lookup.
        Observer =
            quod_simplex:test_state_set(
              validators, Validators -- [Target], WithExpiredResult),
        ?assertEqual(false, quod_simplex:is_participant(Observer)),
        Payload = quod_relay:encode(Ns, InvalidSubmit),
        {keep_state, ObserverRejected, _Actions} =
            quod_simplex:running(
              info,
              {quod_message, {{Author, ignored}, self()},
               quod_simplex:test_relay_chan(Observer), Payload},
              Observer),
        ?assertEqual(
           quod_simplex:test_relay_result_entries(Observer),
           quod_simplex:test_relay_result_entries(ObserverRejected)),
        ?assertEqual(
           {[], [], [SeedAttemptId]},
           quod_simplex:test_relay_state_keys(ObserverRejected)),
        ?assertEqual(#{}, quod_simplex:test_outbox(ObserverRejected)),
        assert_no_relay_control()
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% The complementary restart case reconstructs authoritative exclusion from a
%% durable noop target slot. It never fabricates success or reopens placement.
destination_restart_reconstructs_excluded_result_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"restart-excluded">>),
    Dir = relay_store_dir("excluded"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} =
        quod_ledger_store:append(
          Store0,
          [#entry{index = I, data = noop, timestamp = I}
           || I <- lists:seq(1, Slot)]),
    try
        Restarted =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_state_set(
                store, Store1,
                quod_simplex:test_state_set(slot, Slot, Initial))),
        {Reconstructed, []} =
            quod_simplex:test_dispatch_relay(Author, Submit, Restarted),
        ?assertEqual(
           {relay_result, SubmissionId, AttemptId, CommitteeId,
            Slot, {error, not_in_charge, none}},
           receive_relay_control(Ns)),
        ?assertEqual(#{}, quod_simplex:test_outbox(Reconstructed)),
        ?assertEqual(
           {[], [], [AttemptId]},
           quod_simplex:test_relay_state_keys(Reconstructed))
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% A catch-up window can settle both directions of relay ownership at once.
%% Slot 4 contains an inbound attempt already sealed by this destination;
%% slot 5 contains this node's outbound signed submission. Recovery resolves
%% both from durable SubmissionIds before discarding the volatile window.
catchup_window_settles_inbound_and_outbound_relays_test() ->
    {Ns, CommitteeId, InboundSlot = 4, Author, _AuthorId, Self, Validators,
     InboundSubmissionId, InboundAttemptId,
     {relay_submit, InboundSubmissionId, InboundAttemptId, CommitteeId,
      InboundSlot, InboundSubmission, _InboundCarrier} = InboundSubmit,
     Initial} =
        relay_receiver_fixture(<<"catchup-inbound">>),
    {ok, InboundTx} =
        decode_submission(Ns, InboundSubmission),
    Dir = relay_store_dir("catchup_both_directions"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} =
        quod_ledger_store:append(
          Store0,
          [#entry{index = I, data = noop, timestamp = I}
           || I <- lists:seq(1, InboundSlot - 1)]),
    try
        Ready =
            quod_simplex:test_state_set(
              batch_window_ms, 0,
              quod_simplex:test_state_set(store, Store1, Initial)),
        {WithInbound, _Actions} =
            quod_simplex:test_dispatch_relay(
              Author, InboundSubmit, Ready),
        ?assert(quod_simplex:proposal_visible(
                  InboundSlot, WithInbound)),
        ?assertEqual(
           {[], [InboundAttemptId], []},
           quod_simplex:test_relay_state_keys(WithInbound)),
        ?assertEqual(
           {relay_accepted, InboundSubmissionId, InboundAttemptId,
            CommitteeId, InboundSlot},
           receive_relay_control(Ns)),

        %% Once slot 4 is visibly proposed, the earliest usable seat is slot 5.
        %% Clear only captured wire output so the later result assertion is
        %% independent of the initial accepted acknowledgement.
        SourceFrom = {self(), make_ref()},
        SourceChange = lt($w, Self),
        ExpectedSourceTarget =
            quod_simplex:leader(InboundSlot + 1, Validators),
        {WithSource, []} =
            quod_simplex:test_append(
              SourceFrom, SourceChange,
              quod_simplex:test_state_set(
                relay_conns,
                #{Author => {self(), make_ref()},
                  ExpectedSourceTarget => {self(), make_ref()}},
                quod_simplex:test_state_set(
                  outbox, #{}, WithInbound))),
        [{SourceAttemptId, SourceTarget, 5, _Deadline}] =
            quod_simplex:test_relay_pending(WithSource),
        ?assertEqual(ExpectedSourceTarget, SourceTarget),
        ?assertEqual(#{}, quod_simplex:test_outbox(WithSource)),
        SourceFrame = receive_ordered_frame(),
        {relay,
         {relay_submit, SourceSubmissionId, SourceAttemptId, CommitteeId,
          5, SourceSubmission, _SourceCarrier}} =
            quod_relay:decode_relay_frame(SourceFrame, Ns),
        {ok, SourceTx} =
            decode_submission(Ns, SourceSubmission),

        Entries =
            [#entry{index = 4,
                    data = {batch, [InboundTx]},
                    timestamp = 4},
             #entry{index = 5,
                    data = {batch, [SourceTx]},
                    timestamp = 5}],
        %% Drop only the source-submission link. The destination's result uses
        %% its independent relay-only link back to the original author.
        SourceOffline =
            quod_simplex:test_state_set(
              relay_conns,
              #{Author => {self(), make_ref()}},
              WithSource),
        {Recovered, ok} =
            quod_simplex:test_apply_catchup_window(
              recovery, Entries, SourceOffline),

        receive
            {SourceTag, {ok, 5}} ->
                ?assertEqual(element(2, SourceFrom), SourceTag)
        after 0 ->
            ?assert(false)
        end,
        ?assertEqual(
           {relay_result, InboundSubmissionId, InboundAttemptId,
            CommitteeId, 4, {ok, 4}},
           receive_relay_control(Ns)),
        ?assertEqual(
           {[], [], [InboundAttemptId]},
           quod_simplex:test_relay_state_keys(Recovered)),
        ?assertEqual(
           {0, 0, #{}, []},
           quod_simplex:test_ingress(Recovered)),
        {5, DurableStore} =
            quod_simplex:test_committed_store(Recovered),
        ?assertMatch(
           {ok, #entry{index = 5}},
           quod_ledger_store:read_at(DurableStore, 5)),
        ?assertNotEqual(InboundSubmissionId, SourceSubmissionId)
    after
        quod_ledger_store:close(Store1),
        file:del_dir_r(Dir)
    end.

%% The protocol cutover is definitive: `{log,Ns}` accepts consensus only and
%% `{ingress,Ns}` accepts relay only. Neither wrong-channel frame may even
%% replace the other channel's authenticated generation.
relay_channel_cutover_is_strict_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"strict-relay-channel">>),
    LogChan = term_to_binary({log, Ns}, [deterministic]),
    RelayChan = quod_simplex:test_relay_chan(Initial),
    RelayPayload = quod_relay:encode(Ns, Submit),
    ConsensusPayload =
        quod_simplex:encode(
          Ns, {readiness, Slot - 1, true}),

    RelayOnLog =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             LogChan, RelayPayload},
            Initial)),
    ?assertEqual(Initial, RelayOnLog),
    ConsensusOnRelay =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             RelayChan, ConsensusPayload},
            RelayOnLog)),
    ?assertEqual(Initial, ConsensusOnRelay),
    assert_no_relay_control(),

    Accepted =
        running_state(
          quod_simplex:running(
            info,
            {quod_message, {{Author, ignored}, self()},
             RelayChan, RelayPayload},
            ConsensusOnRelay)),
    ?assertEqual(
       {[], [AttemptId], []},
       quod_simplex:test_relay_state_keys(Accepted)),
    ?assertEqual(
       {relay_accepted, SubmissionId, AttemptId,
        CommitteeId, Slot},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Accepted)).

%% A former committee member that owns neither a current destination attempt
%% nor an origin-side pending attempt has no relay capability. Reject it at the
%% authenticated ingress mailbox boundary, close that stream, and do not even
%% prune an expired cache entry (which would prove dispatch was reached).
removed_relay_source_is_rejected_before_dispatch_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, Validators,
     _SubmissionId, _AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"removed-relay-source">>),
    SeedSubmissionId = <<16#C1:128>>,
    SeedAttemptId = <<16#C2:128>>,
    Seeded =
        quod_simplex:test_expire_relay_results(
          quod_simplex:test_reply_relay(
            Author, SeedSubmissionId, SeedAttemptId, CommitteeId,
            Slot, {error, skipped}, Initial)),
    ?assertEqual(
       {relay_result, SeedSubmissionId, SeedAttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    Removed =
        quod_simplex:test_state_set(
          validators, Validators -- [Author], Seeded),
    ?assert(quod_simplex:is_participant(Removed)),
    {InLink, Token} = spawn_close_aware_link(),
    Payload = quod_relay:encode(Ns, Submit),
    {keep_state, Rejected} =
        quod_simplex:running(
          info,
          {quod_message, {{Author, ignored}, InLink},
           quod_simplex:test_relay_chan(Removed), Payload},
          Removed),
    await_link_closed(InLink, Token),
    ?assertEqual(Removed, Rejected),
    [{SeedAttemptId, {error, skipped}, ExpiredAt}] =
        quod_simplex:test_relay_result_entries(Rejected),
    ?assert(ExpiredAt =< quod_time:mono_ms()),
    assert_no_relay_control().

%% A destination can race local finality: by the time its valid result reaches
%% us, the exact pending attempt may already be gone. A still-current committee
%% member continues to own the shared ingress stream; dispatch safely ignores
%% the unmatched hint instead of resetting that stream.
late_current_member_result_does_not_close_ingress_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     SubmissionId, AttemptId, _Submit, Initial} =
        relay_receiver_fixture(<<"late-current-result">>),
    {InLink, Token} = spawn_close_aware_link(),
    Monitor = erlang:monitor(process, InLink),
    Tracked =
        quod_simplex:test_state_set(
          relay_inbound_conns,
          #{Author => {InLink, Monitor}},
          Initial),
    Payload =
        quod_relay:encode(
          Ns,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}}),
    {keep_state, Ignored, []} =
        quod_simplex:running(
          info,
          {quod_message, {{Author, ignored}, InLink},
           quod_simplex:test_relay_chan(Tracked), Payload},
          Tracked),
    {_, [Author], _} =
        quod_simplex:test_relay_link_peers(Ignored),
    assert_link_not_closed(InLink, Token),
    ensure_close_aware_link_closed(InLink, Token).

%% quod_conn may resolve several open_link waiters with the same stream pid.
%% Repeating that exact link_up is idempotent on both channels: it neither
%% replaces the maps nor closes the already-adopted live stream.
duplicate_same_pid_link_up_is_idempotent_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    {Consensus, ConsensusToken} = spawn_close_aware_link(),
    {Relay, RelayToken} = spawn_close_aware_link(),
    try
        S =
            st(#{self => Self, validators => [Self, Peer],
                 sync => ready, slot => 3, approved => 3,
                 eng => quod_simplex:eng_with_certs(3, []),
                 conns =>
                     #{Peer =>
                           {Consensus,
                            erlang:monitor(process, Consensus)}},
                 relay_conns =>
                     #{Peer =>
                           {Relay,
                            erlang:monitor(process, Relay)}}}),
        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        RelayChan = quod_simplex:test_relay_chan(S),
        AfterConsensus =
            running_state(
              quod_simplex:running(
                info, {link_up, Peer, LogChan, Consensus}, S)),
        AfterRelay =
            running_state(
              quod_simplex:running(
                info, {link_up, Peer, RelayChan, Relay},
                AfterConsensus)),
        ?assertEqual(
           quod_simplex:test_link_peers(S),
           quod_simplex:test_link_peers(AfterRelay)),
        ?assertEqual(
           quod_simplex:test_relay_link_peers(S),
           quod_simplex:test_relay_link_peers(AfterRelay)),
        assert_link_not_closed(Consensus, ConsensusToken),
        assert_link_not_closed(Relay, RelayToken)
    after
        ensure_close_aware_link_closed(Consensus, ConsensusToken),
        ensure_close_aware_link_closed(Relay, RelayToken)
    end.

%% Relay pruning keeps the union of committee, outbound-attempt, and inbound-
%% attempt owners. In particular, subtracting Self must not bind over the later
%% unions: that precedence bug removed an active peer when the same peer also
%% appeared in relay_pending, and discarded inflight-only peers entirely.
relay_pruning_retains_pending_and_inflight_owners_test() ->
    [{Self, SelfId}, {ActivePeer, _ActiveId},
     {InflightPeer, InflightId}] = committee(3),
    {ActivePid, ActiveToken} = spawn_stubborn_link(),
    {InflightPid, InflightToken} = spawn_stubborn_link(),
    try
        Base =
            st(#{self => Self, id => SelfId,
                 validators => [Self, ActivePeer, InflightPeer],
                 sync => ready, slot => 3, approved => 3,
                 eng => quod_simplex:eng_with_certs(3, []),
                 relay_conns =>
                     #{ActivePeer =>
                           {ActivePid,
                            erlang:monitor(process, ActivePid)},
                       InflightPeer =>
                           {InflightPid,
                            erlang:monitor(process, InflightPid)}},
                 relay_dialing =>
                     #{ActivePeer => 101, InflightPeer => 202}}),
        {ok, WithPending} =
            quod_simplex:test_put_pending_relay(
              ActivePeer, 4, Base),
        InflightTx =
            signed_tx(
              <<"t">>, <<"prune-inflight-owner">>,
              [{assert, {{prune, inflight_owner}, true}}],
              {InflightPeer, InflightId}),
        {relayed, InflightRef} =
            quod_simplex:test_relay_origin(
              InflightPeer, 4, InflightTx, WithPending),
        InflightKey = make_ref(),
        MembershipAdvanced =
            quod_simplex:test_state_set(
              validators, [Self, ActivePeer], WithPending),
        Owned =
            quod_simplex:test_state_set(
              relay_inflight,
              #{InflightKey => InflightRef},
              MembershipAdvanced),
        [{_PendingAttemptId, ActivePeer, 4, _Deadline}] =
            quod_simplex:test_relay_pending(Owned),
        {[_PendingKey], [InflightKey], []} =
            quod_simplex:test_relay_state_keys(Owned),

        Pruned = quod_simplex:test_prune_relay_links(Owned),
        ExpectedPeers = lists:sort([ActivePeer, InflightPeer]),
        ?assertEqual(
           {ExpectedPeers, [], ExpectedPeers},
           quod_simplex:test_relay_link_peers(Pruned)),
        assert_stubborn_link_not_closed(ActivePid, ActiveToken),
        assert_stubborn_link_not_closed(InflightPid, InflightToken)
    after
        ensure_stubborn_link_closed(ActivePid, ActiveToken),
        ensure_stubborn_link_closed(InflightPid, InflightToken)
    end.

%% An ordered-send failure kills only the dedicated ingress stream. Its DOWN
%% and link_error events cannot remove consensus links, readiness, queued
%% evidence, or consensus dial state.
relay_transport_failure_isolated_from_consensus_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = committee(2),
    {ConsensusOut, ConsensusOutToken} = spawn_close_aware_link(),
    {ConsensusIn, ConsensusInToken} = spawn_close_aware_link(),
    {RelayOut, RelayOutToken} = spawn_close_aware_link(),
    {RelayIn, RelayInToken} = spawn_close_aware_link(),
    try
        S =
            st(#{self => Self, validators => [Self, Peer],
                 sync => ready, slot => 3, approved => 3,
                 eng => quod_simplex:eng_with_certs(3, []),
                 conns =>
                     #{Peer =>
                           {ConsensusOut,
                            erlang:monitor(process, ConsensusOut)}},
                 inbound_conns =>
                     #{Peer =>
                           {ConsensusIn,
                            erlang:monitor(process, ConsensusIn)}},
                 peer_readiness =>
                     #{Peer =>
                           {ConsensusIn, 3, true,
                            quod_time:mono_ms()}},
                 outbox => #{Peer => [<<"consensus-evidence">>]},
                 dialing => #{Peer => 101},
                 relay_conns =>
                     #{Peer =>
                           {RelayOut,
                            erlang:monitor(process, RelayOut)}},
                 relay_inbound_conns =>
                     #{Peer =>
                           {RelayIn,
                            erlang:monitor(process, RelayIn)}},
                 relay_dialing => #{Peer => 202}}),
        AfterDown =
            running_state(
              quod_simplex:running(
                info,
                {'DOWN', make_ref(), process, RelayOut,
                 {ordered_send_failed, send_queue_full}},
                S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], [Peer]},
           quod_simplex:test_link_peers(AfterDown)),
        ?assertEqual(
           {[], [Peer], [Peer]},
           quod_simplex:test_relay_link_peers(AfterDown)),
        QuorumProbe =
            quod_simplex:test_state_set(
              head_progress,
              {4, awaiting_proposal, false},
              AfterDown),
        ?assertEqual(
           {4, awaiting_proposal, true},
           quod_simplex:test_progress(
             quod_simplex:reconcile_head_progress(QuorumProbe))),

        RelayChan = quod_simplex:test_relay_chan(S),
        AfterRelayError =
            running_state(
              quod_simplex:running(
                info, {link_error, Peer, RelayChan}, S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], [Peer]},
           quod_simplex:test_link_peers(AfterRelayError)),
        ?assertEqual(
           {[Peer], [Peer], []},
           quod_simplex:test_relay_link_peers(AfterRelayError)),

        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        AfterLogError =
            running_state(
              quod_simplex:running(
                info, {link_error, Peer, LogChan}, S)),
        ?assertEqual(
           {[Peer], [Peer], [Peer], []},
           quod_simplex:test_link_peers(AfterLogError)),
        ?assertEqual(
           {[Peer], [Peer], [Peer]},
           quod_simplex:test_relay_link_peers(AfterLogError))
    after
        ensure_close_aware_link_closed(
          ConsensusOut, ConsensusOutToken),
        ensure_close_aware_link_closed(
          ConsensusIn, ConsensusInToken),
        ensure_close_aware_link_closed(
          RelayOut, RelayOutToken),
        ensure_close_aware_link_closed(
          RelayIn, RelayInToken)
    end.

%% Recovery invalidation must also retire, rather than synchronously close and
%% forget, an affected ingress generation. The old link deliberately ignores
%% `close`; while it remains alive, its already-queued relay frame must not
%% recreate the discarded inflight attempt. The real monitor DOWN is the only
%% event that removes the tombstone.
relay_recovery_invalidation_is_nonblocking_and_monotonic_test() ->
    {Ns, _CommitteeId, Slot, Author, _AuthorId, _Target, _Validators,
     _SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(
          <<"recovery-retirement-barrier">>),
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    try
        Linked =
            quod_simplex:test_state_set(
              relay_inbound_conns,
              #{Author => {OldPid, OldRef}},
              Initial),
        {WithInflight, _Actions} =
            quod_simplex:test_dispatch_relay(
              Author, Submit, Linked),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(WithInflight)),
        _Accepted = receive_relay_control(Ns),

        {InvalidateUs, Invalidated} =
            timer:tc(
              fun() ->
                      quod_simplex:
                          test_invalidate_relay_generation(
                            Slot - 1, WithInflight)
              end),
        ?assert(InvalidateUs < 250000),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(Invalidated)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Invalidated)),

        %% The peer is still a committee member and the exact attempt remains
        %% inflight in this focused helper state. Without the tombstone, this
        %% frame would re-adopt OldPid and emit another relay_accepted.
        RelayPayload = quod_relay:encode(Ns, Submit),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, OldPid},
                 quod_simplex:test_relay_chan(Invalidated),
                 RelayPayload},
                Invalidated)),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(AfterStale)),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(AfterStale)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),
        assert_no_relay_control(),

        OldDown =
            release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(
                info, OldDown, AfterStale)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown))
    after
        ensure_stubborn_link_closed(OldPid, OldToken)
    end.

%% Recovery invalidates only sources whose volatile relay ownership was
%% discarded. Their exact inbound generation is closed and forgotten; other
%% authenticated links and their readiness claims remain usable. A relay frame
%% already queued with the closed pid cannot resurrect the discarded attempt.
reseat_invalidates_only_relay_affected_inbound_generation_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, Validators,
     SubmissionId, AttemptId, Submit, Initial} =
        relay_receiver_fixture(<<"reseat-generation">>),
    [KeepPeer1, KeepPeer2] = Validators -- [Target, Author],
    {AffectedPid, AffectedToken} = spawn_close_aware_link(),
    {AuthorConsensusPid, AuthorConsensusToken} =
        spawn_close_aware_link(),
    {KeepPid1, KeepToken1} = spawn_close_aware_link(),
    {KeepPid2, KeepToken2} = spawn_close_aware_link(),
    ConsensusLinks =
        #{Author => {AuthorConsensusPid, make_ref()},
          KeepPeer1 => {KeepPid1, make_ref()},
          KeepPeer2 => {KeepPid2, make_ref()}},
    RelayLinks =
        #{Author => {AffectedPid, make_ref()}},
    Readiness =
        #{Author =>
              {AuthorConsensusPid, Slot - 1, true,
               quod_time:mono_ms()},
          KeepPeer1 =>
              {KeepPid1, Slot - 1, true, quod_time:mono_ms()},
          KeepPeer2 =>
              {KeepPid2, Slot - 1, true, quod_time:mono_ms()}},
    try
        Linked =
            quod_simplex:test_state_set(
              peer_readiness, Readiness,
              quod_simplex:test_state_set(
                relay_inbound_conns, RelayLinks,
                quod_simplex:test_state_set(
                  inbound_conns, ConsensusLinks, Initial))),
        {WithInflight, _Actions} =
            quod_simplex:test_dispatch_relay(
              Author, Submit, Linked),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(WithInflight)),
        ?assertEqual(
           {relay_accepted, SubmissionId, AttemptId,
            CommitteeId, Slot},
           receive_relay_control(Ns)),

        FutureSubmissionId = <<16#F1:128>>,
        FutureAttemptId = <<16#F2:128>>,
        HistoricalSubmissionId = <<16#A1:128>>,
        HistoricalAttemptId = <<16#A2:128>>,
        WithFutureResult =
            quod_simplex:test_reply_relay(
              Author, FutureSubmissionId, FutureAttemptId,
              CommitteeId, Slot + 1, {error, skipped}, WithInflight),
        ?assertEqual(
           {relay_result, FutureSubmissionId, FutureAttemptId,
            CommitteeId, Slot + 1, {error, skipped}},
           receive_relay_control(Ns)),
        WithResults =
            quod_simplex:test_state_set(
              outbox, #{},
              quod_simplex:test_reply_relay(
                KeepPeer1, HistoricalSubmissionId, HistoricalAttemptId,
                CommitteeId, Slot - 1, {error, skipped},
                WithFutureResult)),
        ?assertEqual(
           lists:sort([FutureAttemptId, HistoricalAttemptId]),
           [Key || {Key, _Reply, _Expires} <-
                       quod_simplex:test_relay_result_entries(WithResults)]),

        Reseated = quod_simplex:reseat_engine(Slot - 1, WithResults),
        await_link_closed(AffectedPid, AffectedToken),
        ?assertNot(is_process_alive(AffectedPid)),
        ?assert(is_process_alive(AuthorConsensusPid)),
        ?assert(is_process_alive(KeepPid1)),
        ?assert(is_process_alive(KeepPid2)),
        {_, InboundPeers, _, _} =
            quod_simplex:test_link_peers(Reseated),
        ?assertEqual(
           lists:sort([Author, KeepPeer1, KeepPeer2]), InboundPeers),
        ?assertEqual(
           {[Author], [], []},
           quod_simplex:test_relay_link_peers(Reseated)),
        ?assertEqual(
           {[], [], [HistoricalAttemptId]},
           quod_simplex:test_relay_state_keys(Reseated)),

        %% Every consensus/readiness generation survives the relay-only reset.
        QuorumProbe =
            quod_simplex:test_state_set(
              head_progress,
              {Slot, awaiting_proposal, false},
              Reseated),
        ?assertEqual(
           {Slot, awaiting_proposal, true},
           quod_simplex:test_progress(
             quod_simplex:reconcile_head_progress(QuorumProbe))),

        QueuedPayload = quod_relay:encode(Ns, Submit),
        BeforeOldFrame =
            quod_simplex:test_relay_state_keys(Reseated),
        {keep_state, AfterOldFrame, _OldActions} =
            quod_simplex:running(
              info,
              {quod_message,
               {{Author, ignored}, AffectedPid},
               quod_simplex:test_relay_chan(Reseated), QueuedPayload},
              Reseated),
        ?assertEqual(
           BeforeOldFrame,
           quod_simplex:test_relay_state_keys(AfterOldFrame)),
        {_, AfterOldInboundPeers, _, _} =
            quod_simplex:test_link_peers(AfterOldFrame),
        ?assertEqual(InboundPeers, AfterOldInboundPeers)
    after
        ensure_close_aware_link_closed(AffectedPid, AffectedToken),
        ensure_close_aware_link_closed(
          AuthorConsensusPid, AuthorConsensusToken),
        ensure_close_aware_link_closed(KeepPid1, KeepToken1),
        ensure_close_aware_link_closed(KeepPid2, KeepToken2)
    end.

%% Replacing a live inbound generation is non-blocking and monotonic. The old
%% process deliberately ignores `close` and stays alive, so this pins both
%% halves of the contract: replacement cannot wait for DOWN, and a queued frame
%% from that still-live retired pid cannot reverse the generation.
queued_old_inbound_frame_cannot_reverse_link_replacement_test() ->
    {Ns, CommitteeId, Slot, Author, _AuthorId, Target, _Validators,
     SubmissionId, AttemptId,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      {submit, Author, Signature, Canonical}, Carrier} = Submit,
    Initial} =
        relay_receiver_fixture(<<"replace-generation">>),
    {ConsensusPid, ConsensusToken} = spawn_close_aware_link(),
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    {NewPid, NewToken} = spawn_close_aware_link(),
    try
        OldGeneration =
            quod_simplex:test_state_set(
              peer_readiness,
              #{Author =>
                    {ConsensusPid, Slot - 1, true,
                     quod_time:mono_ms()}},
              quod_simplex:test_state_set(
                relay_inbound_conns,
                #{Author => {OldPid, OldRef}},
                quod_simplex:test_state_set(
                  inbound_conns,
                  #{Author => {ConsensusPid, make_ref()}},
                  Initial))),
        InvalidSubmission =
            {submit, Author, flip1(Signature), Canonical},
        InvalidSubmissionId =
            quod_transaction:submission_id(InvalidSubmission),
        InvalidAttemptId =
            quod_transaction:relay_attempt_id(
              Ns, InvalidSubmissionId, CommitteeId, Slot, Target),
        ReplacementPayload =
            quod_relay:encode(
              Ns,
              {relay_submit, InvalidSubmissionId, InvalidAttemptId,
               CommitteeId, Slot, InvalidSubmission, Carrier}),
        RelayChan = quod_simplex:test_relay_chan(OldGeneration),
        {ReplaceUs, ReplaceResult} =
            timer:tc(
              fun() ->
                      quod_simplex:running(
                        info,
                        {quod_message,
                         {{Author, ignored}, NewPid},
                         RelayChan, ReplacementPayload},
                        OldGeneration)
              end),
        %% The removed implementation waited at least 500ms for DOWN. Leave a
        %% generous scheduler margin while still proving this callback cannot
        %% contain that synchronous wait.
        ?assert(ReplaceUs < 250000),
        Replaced = running_state(ReplaceResult),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assert(is_process_alive(NewPid)),
        ?assert(is_process_alive(ConsensusPid)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Replaced)),
        ?assertEqual(
           {[], [], []},
           quod_simplex:test_relay_state_keys(Replaced)),
        {[], [Author], [], _ConsensusDialsAfterReplace} =
            quod_simplex:test_link_peers(Replaced),
        ?assertEqual(
           {[Author], [Author], []},
           quod_simplex:test_relay_link_peers(Replaced)),

        RelayPayload = quod_relay:encode(Ns, Submit),
        AfterQueuedOld =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, OldPid},
                 RelayChan, RelayPayload},
                Replaced)),
        ?assertEqual(
           {[], [], []},
           quod_simplex:test_relay_state_keys(AfterQueuedOld)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterQueuedOld)),
        ?assert(is_process_alive(NewPid)),
        assert_no_relay_control(),

        AcceptedOnNew =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Author, ignored}, NewPid},
                 RelayChan, RelayPayload},
                AfterQueuedOld)),
        ?assertEqual(
           {[], [AttemptId], []},
           quod_simplex:test_relay_state_keys(AcceptedOnNew)),
        ?assertMatch(
           {relay_accepted, _, AttemptId, _, Slot},
           receive_relay_control(Ns)),
        {[], [Author], [], _ConsensusDialsAfterAccept} =
            quod_simplex:test_link_peers(AcceptedOnNew),
        ?assertEqual(
           {[Author], [Author], []},
           quod_simplex:test_relay_link_peers(AcceptedOnNew)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AcceptedOnNew)),

        OldDown = release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(info, OldDown, AcceptedOnNew)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown)),
        ?assert(is_process_alive(NewPid))
    after
        ensure_close_aware_link_closed(ConsensusPid, ConsensusToken),
        ensure_stubborn_link_closed(OldPid, OldToken),
        ensure_close_aware_link_closed(NewPid, NewToken)
    end.

%% Consensus/readiness uses the same retirement machinery but a distinct
%% generation map. A stale live log-stream pid must neither block replacement
%% nor overwrite the readiness reported on the new authenticated generation.
stale_live_consensus_generation_cannot_block_or_reverse_test() ->
    [{Self, _SelfId}, {Peer, _PeerId}] = Committee = committee(2),
    Validators = pubs(Committee),
    Slot = 3,
    {OldPid, OldToken} = spawn_stubborn_link(),
    OldRef = erlang:monitor(process, OldPid),
    {NewPid, NewToken} = spawn_close_aware_link(),
    try
        OldGeneration =
            st(#{self => Self, validators => Validators,
                 slot => Slot, approved => Slot, sync => ready,
                 eng => quod_simplex:eng_with_certs(Slot, []),
                 head_progress =>
                     {Slot + 1, awaiting_proposal, false},
                 inbound_conns =>
                     #{Peer => {OldPid, OldRef}},
                 peer_readiness =>
                     #{Peer =>
                           {OldPid, Slot, true,
                            quod_time:mono_ms()}}}),
        LogChan = term_to_binary({log, <<"t">>}, [deterministic]),
        ReadyPayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, true}),
        {ReplaceUs, ReplaceResult} =
            timer:tc(
              fun() ->
                      quod_simplex:running(
                        info,
                        {quod_message,
                         {{Peer, ignored}, NewPid},
                         LogChan, ReadyPayload},
                        OldGeneration)
              end),
        ?assert(ReplaceUs < 250000),
        Replaced = running_state(ReplaceResult),
        await_stubborn_close_requested(OldPid, OldToken),
        ?assert(is_process_alive(OldPid)),
        ?assert(is_process_alive(NewPid)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(Replaced)),
        ?assertEqual(
           {Slot + 1, awaiting_proposal, true},
           quod_simplex:test_progress(Replaced)),

        %% If the old live pid were allowed to re-adopt itself, this false
        %% readiness would bind to it and remove the quorum-ready edge.
        StalePayload =
            quod_simplex:encode(
              <<"t">>, {readiness, Slot, false}),
        AfterStale =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, OldPid},
                 LogChan, StalePayload},
                Replaced)),
        ?assertEqual(
           {Slot + 1, awaiting_proposal, true},
           quod_simplex:test_progress(AfterStale)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterStale)),
        assert_link_not_closed(NewPid, NewToken),

        %% The same false readiness is accepted on the actual current pid,
        %% proving stale rejection did not wedge or discard the replacement.
        AfterNew =
            running_state(
              quod_simplex:running(
                info,
                {quod_message,
                 {{Peer, ignored}, NewPid},
                 LogChan, StalePayload},
                AfterStale)),
        ?assertEqual(
           {Slot + 1, awaiting_proposal, false},
           quod_simplex:test_progress(AfterNew)),
        ?assertEqual(
           [OldPid],
           quod_simplex:test_retired_inbound(AfterNew)),

        OldDown = release_stubborn_link(OldPid, OldToken, OldRef),
        AfterOldDown =
            running_state(
              quod_simplex:running(info, OldDown, AfterNew)),
        ?assertEqual(
           [],
           quod_simplex:test_retired_inbound(AfterOldDown)),
        ?assertEqual(
           {Slot + 1, awaiting_proposal, false},
           quod_simplex:test_progress(AfterOldDown)),
        ?assert(is_process_alive(NewPid))
    after
        ensure_stubborn_link_closed(OldPid, OldToken),
        ensure_close_aware_link_closed(NewPid, NewToken)
    end.

%% Terminal result state is write-once. Repeating the identical completion may
%% re-send it but cannot extend expiry; a same-key divergent context emits
%% nothing and cannot replace the cached answer.
terminal_cache_is_write_once_test() ->
    Ns = <<"t">>,
    Peer = <<1:256>>,
    SubmissionId = <<2:128>>,
    AttemptId = <<3:128>>,
    CommitteeId = <<4:256>>,
    Slot = 7,
    S = st(#{self => <<5:256>>, validators => [<<5:256>>],
             relay_conns => #{Peer => {self(), make_ref()}}}),
    First =
        quod_simplex:test_reply_relay(
          Peer, SubmissionId, AttemptId, CommitteeId, Slot,
          {error, skipped}, S),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    [{Key = AttemptId, {error, skipped}, Expires}] =
        quod_simplex:test_relay_result_entries(First),
    Exact =
        quod_simplex:test_reply_relay(
          Peer, SubmissionId, AttemptId, CommitteeId, Slot,
          {error, skipped}, First),
    ?assertEqual(
       {relay_result, SubmissionId, AttemptId, CommitteeId,
        Slot, {error, skipped}},
       receive_relay_control(Ns)),
    ?assertEqual(
       [{Key, {error, skipped}, Expires}],
       quod_simplex:test_relay_result_entries(Exact)),

    DivergentBase = quod_simplex:test_state_set(outbox, #{}, Exact),
    Divergent =
        quod_simplex:test_reply_relay(
          Peer, flip1(SubmissionId), AttemptId, CommitteeId, Slot,
          {error, bad_change}, DivergentBase),
    ?assertEqual(
       [{Key, {error, skipped}, Expires}],
       quod_simplex:test_relay_result_entries(Divergent)),
    ?assertEqual(#{}, quod_simplex:test_outbox(Divergent)),
    assert_no_relay_control().

%% Only a brand-new attempt is gated on the current committee revision and this
%% node's exact ownership of the declared slot.
first_admission_requires_current_view_and_exact_owner_test() ->
    {Ns, CommitteeId, Slot, Author, AuthorId, Target, Validators,
     _SubmissionId, _AttemptId, _Submit, S} =
        relay_receiver_fixture(<<"first-admission">>),
    Tx = signed_tx(
           Ns, <<"first-admission">>,
           [{assert, {{relay, first_admission}, true}}],
           {Author, AuthorId}),
    {ok, Submission} = quod_transaction:submission(
                         test_binding(Ns, Author), Tx),
    SubmissionId = quod_transaction:submission_id(Submission),

    StaleCommitteeId = crypto:hash(sha256, <<"stale-view">>),
    StaleAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, StaleCommitteeId, Slot, Target),
    StaleSubmit =
        {relay_submit, SubmissionId, StaleAttemptId,
         StaleCommitteeId, Slot, Submission, []},
    {Stale, []} =
        quod_simplex:test_dispatch_relay(Author, StaleSubmit, S),
    ?assertEqual(
       {relay_result, SubmissionId, StaleAttemptId, StaleCommitteeId,
        Slot, {error, not_in_charge, none}},
       receive_relay_control(Ns)),
    ?assertEqual(
       {[], [], [StaleAttemptId]},
       quod_simplex:test_relay_state_keys(Stale)),

    WrongSlot =
        hd([Candidate
            || Candidate <- lists:seq(Slot + 1, Slot + length(Validators)),
               quod_simplex:leader(Candidate, Validators) =/= Target]),
    WrongAttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, WrongSlot, Target),
    WrongSubmit =
        {relay_submit, SubmissionId, WrongAttemptId,
         CommitteeId, WrongSlot, Submission, []},
    {WrongOwner, []} =
        quod_simplex:test_dispatch_relay(Author, WrongSubmit, S),
    ?assertEqual(
       {relay_result, SubmissionId, WrongAttemptId, CommitteeId,
        WrongSlot, {error, not_in_charge, none}},
       receive_relay_control(Ns)),
    ?assertEqual(#{}, quod_simplex:test_outbox(WrongOwner)).

%% Source hints bind to the stored peer, submission, attempt, committee, and
%% slot—not the source's later current view. Even a perfectly matching success
%% or error remains only a hint: the origin's durable log decides the outcome.
source_ignores_foreign_metadata_and_waits_for_local_finality_test() ->
    {_Ns, CommitteeId, Slot, From, Target, Validators,
     SubmissionId, AttemptId, _InitialFrame, Sent} =
        outbound_fixture(<<"source-match">>),
    [{SubmissionId, 1, Submission, _OriginalPlacement,
      Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    [Other | _] = Validators -- [Target],
    NewCommitteeId =
        crypto:hash(sha256, <<"source-new-view">>),
    Advanced =
        quod_simplex:test_state_set(
          committee_id, NewCommitteeId, Sent),
    BadAccepted =
        [{Other,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot}},
         {Target,
          {relay_accepted, flip1(SubmissionId), AttemptId,
           CommitteeId, Slot}},
         {Target,
          {relay_accepted, SubmissionId, AttemptId,
           crypto:hash(sha256, <<"foreign-view">>), Slot}},
         {Target,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot + 1}}],
    _ =
        [begin
             {Ignored, []} =
                 quod_simplex:test_dispatch_relay(Peer, Frame, Advanced),
             ?assertEqual(
                quod_simplex:test_relay_pending_detail(Advanced),
                quod_simplex:test_relay_pending_detail(Ignored))
         end || {Peer, Frame} <- BadAccepted],

    {Accepted, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_accepted, SubmissionId, AttemptId,
           CommitteeId, Slot},
          Advanced),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(Accepted),

    BadResults =
        [{Other,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}}},
         {Target,
          {relay_result, flip1(SubmissionId), AttemptId,
           CommitteeId, Slot, {ok, Slot}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           crypto:hash(sha256, <<"wrong-result-view">>),
           Slot, {ok, Slot}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot + 1, {ok, Slot + 1}}},
         {Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot + 1}}}],
    _ =
        [begin
             {Ignored, []} =
                 quod_simplex:test_dispatch_relay(Peer, Frame, Accepted),
             ?assertEqual(
                quod_simplex:test_relay_pending_detail(Accepted),
                quod_simplex:test_relay_pending_detail(Ignored))
         end || {Peer, Frame} <- BadResults],

    {SuccessHint, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {ok, Slot}},
          Accepted),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(SuccessHint),
    Tag = element(2, From),
    receive
        {Tag, _ForgedSuccess} ->
            ?assert(false)
    after 0 ->
        ok
    end,

    {ErrorHint, []} =
        quod_simplex:test_dispatch_relay(
          Target,
          {relay_result, SubmissionId, AttemptId,
           CommitteeId, Slot, {error, not_in_charge, none}},
          SuccessHint),
    [{AttemptId, Target, Slot, Deadline, true}] =
        quod_simplex:test_relay_pending_detail(ErrorHint),
    receive
        {Tag, _ForgedError} ->
            ?assert(false)
    after 0 ->
        ok
    end,

    %% Local exclusion is authoritative, but it makes the exact retained
    %% submission ready for a new placement; it never manufactures a public
    %% retry from either remote hint.
    Finalized = quod_simplex:finalize(Slot, ErrorHint),
    ?assertEqual([], quod_simplex:test_relay_pending(Finalized)),
    [{SubmissionId, 1, Submission, ready, Deadline, 1}] =
        quod_simplex:test_custody(Finalized),
    assert_no_reply(From),
    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          quod_simplex:test_state_set(approved, Slot, Finalized)),
    [{Attempt2, _Target2, Slot2, Deadline}] =
        quod_simplex:test_relay_pending(Retargeted),
    ?assertEqual(Slot + 1, Slot2),
    ?assertNotEqual(AttemptId, Attempt2),
    ?assertEqual(#{}, quod_simplex:test_outbox(Retargeted)),
    RetargetFrame = receive_ordered_frame(),
    {relay,
     {relay_submit, SubmissionId, Attempt2, NewCommitteeId, Slot2,
      Submission, _RetargetCarrier}} =
        quod_relay:decode_relay_frame(RetargetFrame, <<"t">>),
    %% Hints never reset the original lifetime bound.
    ?assert(Deadline > quod_time:mono_ms()).

%% The custody deadline is anchored once at original arrival. Retargeting keeps
%% that exact deadline, and expiry removes both custody and its active placement
%% while sending one ambiguous `unavailable` signal upstream. `quod_prolog`
%% deliberately keeps the public caller parked and eventually reports
%% `outcome_unknown`.
custody_deadline_survives_retarget_and_expires_once_test() ->
    {Ns, _CommitteeId, Slot, From, _Target, _Validators,
     SubmissionId, Attempt1, _InitialFrame, Sent} =
        outbound_fixture(<<"custody-deadline">>),
    [{SubmissionId, 1, Submission, _Placement1, Deadline, 1}] =
        quod_simplex:test_custody(Sent),
    Ready = quod_simplex:finalize(Slot, Sent),
    {Retargeted, []} =
        quod_simplex:test_drain_custody(
          quod_simplex:test_state_set(approved, Slot, Ready)),
    [{SubmissionId, 1, Submission, Placement2, Deadline, 2}] =
        quod_simplex:test_custody(Retargeted),
    case Placement2 of
        {local, Slot2} ->
            ?assertEqual(Slot + 1, Slot2);
        {relay, Attempt2, _Target2, Slot2, _View2} ->
            ?assertEqual(Slot + 1, Slot2),
            ?assertNotEqual(Attempt1, Attempt2),
            RetargetFrame = receive_ordered_frame(),
            {relay,
             {relay_submit, SubmissionId, Attempt2, _CommitteeId2,
              Slot2, Submission, _Carrier}} =
                quod_relay:decode_relay_frame(RetargetFrame, Ns)
    end,

    Expired = quod_simplex:test_expire_custody(Retargeted),
    ?assertEqual([], quod_simplex:test_custody(Expired)),
    ?assertEqual([], quod_simplex:test_relay_pending(Expired)),
    {_, ExpectRef} = From,
    receive
        {ExpectRef, Reply} ->
            ?assertEqual({error, not_in_charge, unavailable}, Reply)
    after 0 ->
        ?assert(false)
    end,
    assert_no_reply(From).

%% The emitted frame binds the signed envelope to one committee/slot/target
%% attempt. A timer reconciliation never duplicates it on a live reliable
%% stream; a replacement link reconstructs the exact retained bytes once.
relay_emission_is_attempt_scoped_and_link_recovery_is_immutable_test() ->
    {Ns, CommitteeId, Slot, _From, Target, _Validators,
     SubmissionId, AttemptId, Frame, Sent} =
        outbound_fixture(<<"wire-attempt">>),
    ?assertEqual(#{}, quod_simplex:test_outbox(Sent)),
    {relay,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      Submission, _TraceCarrier}} =
        quod_relay:decode_relay_frame(Frame, Ns),
    ?assertEqual(
       AttemptId,
       quod_transaction:relay_attempt_id(
         Ns, quod_transaction:submission_id(Submission),
         CommitteeId, Slot, Target)),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Sent),
    Reconciled = quod_simplex:test_reconcile_relays(Sent),
    assert_no_ordered_frame(),
    ?assertEqual(#{}, quod_simplex:test_outbox(Reconciled)),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Reconciled),

    Disconnected = quod_simplex:test_state_set(
                     relay_conns, #{}, Reconciled),
    RelayChan = quod_simplex:test_relay_chan(Disconnected),
    Reconnected = running_state(
                    quod_simplex:running(
                      info, {link_up, Target, RelayChan, self()},
                      Disconnected)),
    ?assertEqual(Frame, receive_ordered_frame()),
    assert_no_ordered_frame(),
    [{AttemptId, Target, Slot, Deadline, false}] =
        quod_simplex:test_relay_pending_detail(Reconnected).

%% Signature verification consumes the opaque canonical bytes as bytes. An
%% invalid signature must prevent the later unsafe canonical ETF decode from
%% even interning an atom embedded in those bytes.
signature_is_checked_before_canonical_decode_test() ->
    {Ns, CommitteeId, Slot, Author, AuthorId, Target, _Validators,
     _SubmissionId, _AttemptId, _Submit, S} =
        relay_receiver_fixture(<<"verify-before-decode">>),
    Tx = signed_tx(
           Ns, <<"verify-before-decode">>,
           [{assert, {{relay, opaque}, true}}],
           {Author, AuthorId}),
    {ok, {submit, Author, _GoodSignature, Canonical}} =
        quod_transaction:submission(test_binding(Ns, Author), Tx),
    AtomName =
        iolist_to_binary(
          io_lib:format(
            "qars_~11..0B",
            [erlang:unique_integer([positive]) rem 100000000000])),
    ?assertEqual(16, byte_size(AtomName)),
    ?assertException(
       error, badarg, binary_to_existing_atom(AtomName, utf8)),
    Poisoned =
        binary:replace(
          Canonical, <<"quod_transaction">>, AtomName, [global]),
    Submission = {submit, Author, <<0:512>>, Poisoned},
    SubmissionId = quod_transaction:submission_id(Submission),
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, Slot, Target),
    Wire =
        quod_relay:encode(
          Ns, {relay_submit, SubmissionId, AttemptId, CommitteeId,
               Slot, Submission, []}),
    {relay, Decoded} = quod_relay:decode_relay_frame(Wire, Ns),
    {Rejected, []} =
        quod_simplex:test_dispatch_relay(Author, Decoded, S),
    ?assertException(
       error, badarg, binary_to_existing_atom(AtomName, utf8)),
    %% A failed opaque-signature check is silent and leaves even volatile
    %% recovery state untouched.
    ?assertEqual(S, Rejected),
    ?assertEqual(#{}, quod_simplex:test_outbox(Rejected)),
    ?assertEqual({[], [], []},
                 quod_simplex:test_relay_state_keys(Rejected)).

%% A decoded but unsupported or malformed relay term cannot crash or mutate the
%% state owner. The wire codec normally rejects the malformed shape first; this
%% keeps the state-machine boundary fail-closed as well.
unsupported_and_malformed_relay_terms_are_safely_dropped_test() ->
    S = st(#{self => <<0:256>>, validators => [<<0:256>>],
             slot => 6, approved => 6,
             eng => quod_simplex:eng_with_certs(6, [])}),
    Messages =
        [{relay_unsupported, <<"opaque">>},
         {relay_submit, <<1:120>>, <<2:128>>, <<3:256>>, 7,
          malformed_submission, []}],
    _ =
        [begin
             {S1, Actions} =
                 quod_simplex:test_dispatch_relay(<<1:256>>, Message, S),
             ?assertEqual(S, S1),
             ?assertEqual([], Actions)
         end || Message <- Messages],
    ok.

%% A leader latched into a final-vote camp for its OWN in-flight slot must STILL redrive
%% the proposal on every Δ: the link send is fire-and-forget, so the Δ re-fire is the
%% only retransmit of a lost proposal frame. (Live regression: a leader that
%% complaint-signed its slot before proposing stopped redriving, no follower ever saw
%% the proposal, and the burst wedged with zero support votes.)
latched_leader_still_redrives_proposal_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    {Me, MyId} = lists:keyfind(quod_simplex:leader(4, Validators), 1, Committee),
    B4 = blk(4),
    BH = quod_simplex:block_hash(B4),
    {E1, _} = quod_simplex:eng_offer({block, B4}, quod_simplex:eng_new(?DOMAIN, Validators, 3)),
    %% latch the complaint exactly as the pre-proposal timeout path does
    Sink = spawn(fun Loop() -> receive _ -> Loop() end end),
    try
        Inbound = maps:from_list([{P, {Sink, make_ref()}} || P <- Validators, P =/= Me]),
        Readiness = voting_readiness([P || P <- Validators, P =/= Me], Sink, 3),
        SReady = st(#{self => Me, id => MyId, validators => Validators, sync => ready,
                      slot => 3, approved => 3, eng => E1,
                      inbound_conns => Inbound, peer_readiness => Readiness,
                      head_progress => {4, awaiting_proposal, true}}),
        Complained = quod_simplex:on_progress_timeout(4, SReady),
        ?assertEqual({none, false, true}, quod_simplex:test_round(4, Complained)),
        %% now it proposes (the drain would do this); then the next Δ must RE-SEND it
        Redriven = quod_simplex:on_progress_timeout(
                     4, quod_simplex:test_state_set(
                          local_proposal, {4, BH}, Complained)),
        ?assertEqual(1, maps:get(redrives, quod_simplex:stats_map(Redriven)))
    after
        exit(Sink, kill)
    end.

%% The quod_metrics matcher and stats_map can never drift: every key the Prometheus
%% refresh pattern requires must exist in the stats map (a miss silently zeroes ALL
%% consensus gauges).
metrics_matcher_lockstep_test() ->
    {Me, Id} = id(),
    Stats = quod_simplex:stats_map(
              st(#{self => Me, id => Id, validators => [Me], sync => ready,
                   slot => 1, approved => 1,
                   eng => quod_simplex:eng_with_certs(0, [])})),
    Missing = quod_metrics:consensus_stat_keys() -- maps:keys(Stats),
    ?assertEqual([], Missing).

%%%===================================================================
%%% boundary / edge / Byzantine (fixes from the review)
%%%===================================================================

%% Positive control for the rejection tests: a cert forms at EXACTLY quorum and not one below.
cert_boundary_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],           %% N=4, quorum=3
    Vals = [P || {P, _} <- Ids],
    H    = quod_simplex:block_hash(blk(1)),
    Sh   = fun(N) -> [quod_simplex:make_share(?DOMAIN, support, 1, H, Id) || {_, Id} <- take(N, Ids)] end,
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Sh(2), Vals)),
    ?assertMatch({ok, _},               quod_simplex:form_cert(?DOMAIN, support, 1, H, Sh(3), Vals)).

%% The live sole-founder path: N=1, quorum=1, a self-signed cert forms and verifies.
sole_validator_cert_test() ->
    {P, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    {ok, C} = quod_simplex:form_cert(?DOMAIN, commit, 1, H, [quod_simplex:make_share(?DOMAIN, commit, 1, H, Id)], [P]),
    ?assert(quod_simplex:verify_cert(?DOMAIN, C, [P])).

%% An empty validator set must NOT crash (quorum(0)) — clean insufficient / false.
empty_validators_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assertEqual({error, insufficient},
                 quod_simplex:form_cert(?DOMAIN, support, 1, H, [quod_simplex:make_share(?DOMAIN, support, 1, H, Id)], [])),
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, #cert{kind = support, slot = 1, block_hash = H, sigs = []}, [])).

%% A complaint (slot-only, block_hash=none) cert forms and verifies.
complaint_cert_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    Sh   = [quod_simplex:make_share(?DOMAIN, complaint, 2, none, Id) || {_, Id} <- take(3, Ids)],
    {ok, C} = quod_simplex:form_cert(?DOMAIN, complaint, 2, none, Sh, Vals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, C, Vals)).

%%%===================================================================
%%% f+1 complaint amplification threshold (Slice B: growth liveness)
%%%===================================================================

%% The leader of an in-flight slot (and any node ingesting a complaint share) joins a complaint only on
%% `f+1` distinct PEER complaint shares — enough to guarantee ≥1 HONEST complainer, so a lone Byzantine
%% can't force a skip, yet a genuine stall still gets amplified. The threshold is DERIVED from quorum/1
%% (`f = N − quorum(N)`), so it must track the cert arithmetic exactly at every committee size.
complaint_amplified_threshold_test() ->
    Bucket = fun(Signers) -> maps:from_list([{S, dummy} || S <- Signers]) end,
    %% peers are just distinct signer keys; `self` (the atom `me`) is excluded from the count.
    Vs = fun(N) -> [me | [{peer, I} || I <- lists:seq(1, N - 1)]] end,
    Peers = fun(K) -> Bucket([{peer, I} || I <- lists:seq(1, K)]) end,
    Amp = fun(N, K) -> quod_simplex:complaint_amplified(me, Vs(N), Peers(K)) end,
    %% f+1 by committee size: N=2,3 ⇒ 1 (f=0); N=4,5,6 ⇒ 2 (f=1); N=7 ⇒ 3 (f=2).
    ?assertNot(Amp(2, 0)), ?assert(Amp(2, 1)),                 %% N=2: one peer suffices
    ?assertNot(Amp(3, 0)), ?assert(Amp(3, 1)),                 %% N=3: still one (f=0)
    ?assertNot(Amp(4, 1)), ?assert(Amp(4, 2)),                 %% N=4: needs two (f=1)
    ?assertNot(Amp(7, 2)), ?assert(Amp(7, 3)),                 %% N=7: needs three (f=2)
    %% our OWN complaint share is not independent evidence — self is excluded from the count.
    ?assertNot(quod_simplex:complaint_amplified(me, Vs(2), Bucket([me]))),
    ?assert(quod_simplex:complaint_amplified(me, Vs(2), Bucket([me, {peer, 1}]))),
    %% Cached shares from outsiders or removed validators do not count in the current committee.
    ?assertNot(quod_simplex:complaint_amplified(
                 me, Vs(4), Bucket([{peer, 1}, outsider]))),
    ?assert(quod_simplex:complaint_amplified(
              me, Vs(4), Bucket([{peer, 1}, {peer, 2}, outsider]))).

%% Malformed shapes are rejected even with a valid signature over their (malformed) bytes.
share_shape_test() ->
    {_, Id} = id(),
    H = quod_simplex:block_hash(blk(1)),
    ?assert(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, support, 1, H, Id))),
    ?assertNot(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, complaint, 1, H, Id))),   %% complaint w/ hash
    ?assertNot(quod_simplex:verify_share(?DOMAIN, quod_simplex:make_share(?DOMAIN, support, 1, <<1, 2, 3>>, Id))),  %% short hash
    Wrapped = (quod_simplex:make_share(?DOMAIN, support, 1, H, Id))#share{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:verify_share(?DOMAIN, Wrapped)).   %% slot encoding must never wrap modulo 2^64

%% A share whose FIELDS claim block H but whose signature is over a DIFFERENT block: form_cert
%% re-verifies over the cert's canonical bytes, so the liar does not count (proves fields aren't trusted).
fields_lie_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H      = quod_simplex:block_hash(blk(1)),
    HOther = quod_simplex:block_hash(blk(9)),
    [{_, A}, {_, B}, {_, C} | _] = Ids,
    Liar = (quod_simplex:make_share(?DOMAIN, support, 1, HOther, C))#share{block_hash = H},  %% sig over HOther, claims H
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H, A),
              quod_simplex:make_share(?DOMAIN, support, 1, H, B), Liar],
    ?assertEqual({error, insufficient}, quod_simplex:form_cert(?DOMAIN, support, 1, H, Shares, Vals)).

%% A cert carrying MORE signatures than validators is rejected before any verify work (amplification cap).
verify_cert_caps_sigs_test() ->
    Ids  = [id() || _ <- lists:seq(1, 4)],
    Vals = [P || {P, _} <- Ids],
    H = quod_simplex:block_hash(blk(1)),
    Bloat = [{P, <<0:512>>} || P <- Vals] ++ [{<<X:256>>, <<0:512>>} || X <- lists:seq(1, 20)],
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, #cert{kind = support, slot = 1, block_hash = H, sigs = Bloat}, Vals)),
    {ok, Good} = quod_simplex:form_cert(?DOMAIN, support, 1, H, supports(blk(1), Ids, 3), Vals),
    [First | _] = Good#cert.sigs,
    Improper = Good#cert{sigs = [First | bad_tail]},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Improper, Vals)),
    Wrapped = Good#cert{slot = (1 bsl 64) + 1},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Wrapped, Vals)).

validator_cap_certificate_boundary_test() ->
    N = ?MAX_VALIDATORS,
    Ids = committee(N + 1),
    AtLimitIds = take(N, Ids),
    AtLimitVals = pubs(AtLimitIds),
    H = quod_simplex:block_hash(blk(1)),
    AtLimitShares =
        [quod_simplex:make_share(?DOMAIN, support, 1, H, Id)
         || {_, Id} <- take(quod_simplex:quorum(N), AtLimitIds)],
    {ok, AtLimitCert} = quod_simplex:form_cert(
                          ?DOMAIN, support, 1, H,
                          AtLimitShares, AtLimitVals),
    ?assert(quod_simplex:verify_cert(?DOMAIN, AtLimitCert, AtLimitVals)),
    Vals = pubs(Ids),
    Shares = [quod_simplex:make_share(?DOMAIN, support, 1, H, Id)
              || {_, Id} <- take(quod_simplex:quorum(N + 1), Ids)],
    Cert = #cert{kind = support, slot = 1, block_hash = H,
                 sigs = [{Share#share.signer, Share#share.sig}
                         || Share <- Shares]},
    ?assertNot(quod_simplex:verify_cert(?DOMAIN, Cert, Vals)),
    ?assertEqual(
       {error, insufficient},
       quod_simplex:form_cert(
         ?DOMAIN, support, 1, H, Shares, Vals)).

%%%===================================================================
%%% consensus engine — certificate pool + block tree (§2.3)
%%%===================================================================

%% With durable base H, depth-one pipelining needs both H+1 and H+2:
%% child traffic can race ahead of its parent. H+3 is recovery history, not
%% volatile engine state. Pin every object kind so a future call-site bypass
%% cannot reopen one of the maps independently.
eng_live_horizon_accepts_h2_and_drops_h3_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    H2Block = blk(7),
    H3Block = blk(8),
    H2Hash = quod_simplex:block_hash(H2Block),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, 5),
    {E1, []} = quod_simplex:eng_offer({block, H2Block}, E0),
    ?assertEqual(H2Block, quod_simplex:eng_retained_block(7, E1)),
    ?assertEqual(
       #{blocks => 1, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(E1)),
    {BlockDropped, []} = quod_simplex:eng_offer({block, H3Block}, E1),
    ?assertEqual(E1, BlockDropped),

    [{_, FirstSigner} | _] = Committee,
    H2Share =
        quod_simplex:make_share(
          ?DOMAIN, support, 7, H2Hash, FirstSigner),
    {E2, []} = quod_simplex:eng_offer({share, H2Share}, E1),
    ?assertEqual(
       #{blocks => 1, share_buckets => 1, seen_votes => 1, certs => 0},
       quod_simplex:eng_pool_sizes(E2)),
    H3Share =
        quod_simplex:make_share(
          ?DOMAIN, support, 8, quod_simplex:block_hash(H3Block),
          FirstSigner),
    {ShareDropped, []} = quod_simplex:eng_offer({share, H3Share}, E2),
    ?assertEqual(E2, ShareDropped),

    {ok, H2Cert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, 7, H2Hash,
          supports(H2Block, Committee, 3), Validators),
    {E3, _} = quod_simplex:eng_offer({cert, H2Cert}, E2),
    ?assertMatch(
       #cert{},
       quod_simplex:persisted_cert(support, 7, H2Hash, E3)),
    {ok, H3Cert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, 8, quod_simplex:block_hash(H3Block),
          supports(H3Block, Committee, 3), Validators),
    {CertDropped, []} = quod_simplex:eng_offer({cert, H3Cert}, E3),
    ?assertEqual(E3, CertDropped).

%% A far finalizer is verified once and represented by one scalar recovery
%% hint. It must neither populate the certificate pool nor remain authoritative
%% after the validator set changes. Once base advances enough, retransmission
%% takes the ordinary retained-certificate path.
eng_far_finalizer_is_bounded_recovery_hint_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    FarBlock = blk(8),
    FarHash = quod_simplex:block_hash(FarBlock),
    {ok, FarCert} =
        quod_simplex:form_cert(
          ?DOMAIN, commit, 8, FarHash,
          commits(FarBlock, Committee, 3), Validators),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, 5),
    {Hinted, []} = quod_simplex:eng_offer({cert, FarCert}, E0),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Hinted)),
    ?assertEqual(
       #{blocks => 0, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(Hinted)),
    ?assertEqual(
       none, quod_simplex:persisted_cert(commit, 8, FarHash, Hinted)),
    [{Self, _} | _] = Committee,
    Ready =
        st(#{self => Self, validators => Validators, slot => 5,
             approved => 5, eng => Hinted, sync => ready}),
    ?assertNot(quod_simplex:caught_up(Ready)),
    ?assertNot(quod_simplex:may_vote(Ready)),
    ?assert(quod_simplex:should_sync(Ready)),

    Advanced = quod_simplex:eng_prune(6, Hinted),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Advanced)),
    {InsideWindow, _} =
        quod_simplex:eng_offer({cert, FarCert}, Advanced),
    ?assertMatch(
       #cert{},
       quod_simplex:persisted_cert(
         commit, 8, FarHash, InsideWindow)),

    NewCommittee = committee(4),
    NewValidators = pubs(NewCommittee),
    Changed = quod_simplex:eng_set_validators(NewValidators, Hinted),
    ?assertEqual(5, quod_simplex:ahead_cert_ceiling(Changed)),
    {OldSetRejected, []} =
        quod_simplex:eng_offer({cert, FarCert}, Changed),
    ?assertEqual(Changed, OldSetRejected),
    {ok, NewSetCert} =
        quod_simplex:form_cert(
          ?DOMAIN, commit, 8, FarHash,
          commits(FarBlock, NewCommittee, 3), NewValidators),
    {Rehinted, []} =
        quod_simplex:eng_offer({cert, NewSetCert}, Changed),
    ?assertEqual(8, quod_simplex:ahead_cert_ceiling(Rehinted)),
    ?assertEqual(
       #{blocks => 0, share_buckets => 0, seen_votes => 0, certs => 0},
       quod_simplex:eng_pool_sizes(Rehinted)).

%% A Byzantine validator can sign arbitrarily many hashes for one live slot.
%% Only its first verified vote is retained, so both the signer index and the
%% hash-bucket map remain constant while later valid conflicts are discarded.
eng_conflicting_share_spam_is_bounded_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    [{_, Signer} | _] = Committee,
    Hashes =
        [crypto:hash(sha256, <<"conflicting-share", N:64>>)
         || N <- lists:seq(1, 64)],
    Shares =
        [quod_simplex:make_share(?DOMAIN, support, 6, Hash, Signer)
         || Hash <- Hashes],
    ?assert(lists:all(
              fun(Share) ->
                      quod_simplex:verify_share(?DOMAIN, Share)
              end, Shares)),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, 5),
    Bounded =
        lists:foldl(
          fun(Share, Eng) ->
                  {Eng1, _} = quod_simplex:eng_offer({share, Share}, Eng),
                  Eng1
          end, E0, Shares),
    ?assertEqual(
       #{blocks => 0, share_buckets => 1, seen_votes => 1, certs => 0},
       quod_simplex:eng_pool_sizes(Bounded)).

%% A Byzantine leader's second ordinary proposal reaches the real driver seam:
%% it is structurally valid and from the correct authenticated leader, but the
%% engine's first-block latch rejects it. The driver must not dereference the
%% rejected hash or mutate any state.
ordinary_block_equivocation_is_bounded_and_does_not_crash_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    First =
        #block{
           slot = 6, parent = 5,
           payload =
               {batch,
                [signed_tx(
                   <<"t">>, <<"equivocation-first">>,
                   [{assert, {{equivocation, first}, true}}],
                   {Leader, LeaderId})]}},
    Second =
        #block{
           slot = 6, parent = 5,
           payload =
               {batch,
                [signed_tx(
                   <<"t">>, <<"equivocation-second">>,
                   [{assert, {{equivocation, second}, true}}],
                   {Leader, LeaderId})]}},
    Initial =
        st(#{self => Leader, id => LeaderId, validators => Validators,
             slot => 5, approved => 5,
             eng => quod_simplex:eng_new(?DOMAIN, Validators, 5),
             sync => ready}),
    Supported =
        quod_simplex:dispatch(Leader, {propose, First, []}, Initial),
    FirstHash = quod_simplex:block_hash(First),
    ?assertEqual(
       {FirstHash, false, false},
       quod_simplex:test_round(6, Supported)),
    Rejected =
        quod_simplex:dispatch(Leader, {propose, Second, []}, Supported),
    ?assertEqual(Supported, Rejected).

%% Record field types are not runtime checks: an authenticated Byzantine
%% leader can still put an arbitrary term in a wire-decoded block payload.
%% Proposal admission must classify that term and reject it, never narrow the
%% function head to canonical batches and crash the ontology process.
malformed_leader_payload_is_rejected_without_crash_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Leader = quod_simplex:leader(6, Validators),
    {Leader, LeaderId} = lists:keyfind(Leader, 1, Committee),
    Malformed = #block{slot = 6, parent = 5,
                       payload = malformed_payload, timestamp = 0},
    Initial =
        st(#{self => Leader, id => LeaderId, validators => Validators,
             slot => 5, approved => 5,
             eng => quod_simplex:eng_new(?DOMAIN, Validators, 5),
             sync => ready}),
    ?assertEqual(
       Initial,
       quod_simplex:dispatch(Leader, {propose, Malformed, []}, Initial)).

%% First-block-wins bounds ordinary equivocation, but certified-block recovery
%% must still replace an unnotarized losing copy. The replacement removes the
%% old payload, whereas an already-notarized slot is immutable even if a
%% synthetic second quorum certificate is presented.
eng_certified_alternate_replaces_only_unnotarized_block_test() ->
    Committee = committee(4),
    Validators = pubs(Committee),
    Losing = blk(6),
    Winning = Losing#block{timestamp = 1},
    WinningHash = quod_simplex:block_hash(Winning),
    {ok, WinningCert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, 6, WinningHash,
          supports(Winning, Committee, 3), Validators),
    E0 = quod_simplex:eng_new(?DOMAIN, Validators, 5),
    {LosingHeld, []} = quod_simplex:eng_offer({block, Losing}, E0),
    {Certified, _} =
        quod_simplex:eng_offer({cert, WinningCert}, LosingHeld),
    {Replaced, ReplacedEvents} =
        quod_simplex:eng_offer({block, Winning}, Certified),
    ?assertEqual(Winning, quod_simplex:eng_retained_block(6, Replaced)),
    ?assertEqual(
       #{blocks => 1, share_buckets => 0, seen_votes => 0, certs => 1},
       quod_simplex:eng_pool_sizes(Replaced)),
    ?assert(lists:member({notarized, Winning}, ReplacedEvents)),

    LosingHash = quod_simplex:block_hash(Losing),
    {ok, LosingCert} =
        quod_simplex:form_cert(
          ?DOMAIN, support, 6, LosingHash,
          supports(Losing, Committee, 3), Validators),
    {LosingAgain, []} = quod_simplex:eng_offer({block, Losing}, E0),
    {Notarized, _} =
        quod_simplex:eng_offer({cert, LosingCert}, LosingAgain),
    ?assertEqual(Losing, maps:get(6, quod_simplex:eng_tree(Notarized))),
    {TwoCerts, _} =
        quod_simplex:eng_offer({cert, WinningCert}, Notarized),
    {StillNotarized, []} =
        quod_simplex:eng_offer({block, Winning}, TwoCerts),
    ?assertEqual(TwoCerts, StillNotarized),
    ?assertEqual(
       Losing, quod_simplex:eng_retained_block(6, StillNotarized)),
    ?assertEqual(
       Losing, maps:get(6, quod_simplex:eng_tree(StillNotarized))),
    ?assertEqual(1, maps:get(
                      blocks,
                      quod_simplex:eng_pool_sizes(StillNotarized))).

%% N=4 (quorum 3): a block notarizes at the 3rd support share, commits at the 3rd commit share.
eng_notarize_then_commit_test() ->
    C = committee(4),
    B = blk(1),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C), 0),
    {E1, _} = quod_simplex:eng_offer({block, B}, E0),
    {E2, Ev2} = feed_shares(supports(B, C, 2), E1),        %% 2 < quorum 3
    ?assertNot(lists:member({notarized, B}, Ev2)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E2))),
    {E3, Ev3} = feed_shares(supports(B, C, 3) -- supports(B, C, 2), E2),   %% the 3rd share
    ?assert(lists:member({notarized, B}, Ev3)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_tree(E3))),
    {E4, Ev4} = feed_shares(commits(B, C, 3), E3),
    ?assert(lists:member({committed, 1, B}, Ev4)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_committed(E4))).

%% Slice E — the weak-cert finalize guard (the mid-flight committee-change / stale-cert hazard). A commit
%% cert that met quorum under a committee is SUB-QUORUM once the committee grows; finalizing it would fork a
%% laggard from the honest network. persisted_cert returns none (the trigger the statem refuses on),
%% eng_evict_final backs out the premature commit-marking, and a fresh share under the grown set re-forms a
%% genuine cert that re-commits — proving the wait re-drives rather than wedging forever.
weak_cert_guard_test() ->
    C5 = committee(5),
    C4 = take(4, C5),               %% the 4-set is the first 4 of the 5-set (all still members after growth)
    B  = blk(1),
    BH = quod_simplex:block_hash(B),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C4), 0),
    {E1, _}  = quod_simplex:eng_offer({block, B}, E0),
    {E2, _}  = feed_shares(supports(B, C4, 3), E1),                         %% notarize under the 4-set
    {E3, Ev} = feed_shares(commits(B, C4, 3), E2),                          %% commit cert forms (quorum(4)=3)
    ?assert(lists:member({committed, 1, B}, Ev)),
    ?assertMatch(#cert{}, quod_simplex:persisted_cert(commit, 1, BH, E3)),  %% valid under the 4-set

    %% the committee grows to 5 (quorum 4): the 3-sig cert is now sub-quorum.
    E4 = quod_simplex:eng_set_validators(pubs(C5), E3),
    ?assertEqual(none, quod_simplex:persisted_cert(commit, 1, BH, E4)),     %% THE TRIGGER the statem refuses on

    %% back out the premature commit-marking, then a 4th distinct share under the 5-set re-forms + re-commits.
    E5 = quod_simplex:eng_evict_final(commit, 1, BH, E4),
    ?assertNot(maps:is_key(1, quod_simplex:eng_committed(E5))),             %% un-marked ⇒ detect_commits can re-fire
    {E6, Ev6} = feed_shares(commits(B, C5, 5) -- commits(B, C4, 3), E5),    %% shares from members 4 + 5
    ?assert(lists:member({committed, 1, B}, Ev6)),                          %% re-committed under the 5-set
    ?assertMatch(#cert{}, quod_simplex:persisted_cert(commit, 1, BH, E6)).  %% now a genuine 4-sig cert

%% Verified shares may stay cached across a committee transition, but a removed signer must stop counting.
%% Re-offering a current member's duplicate exercises the no-reverify/re-form path: one current + one removed
%% share is below quorum(3)=3; only after both remaining current members sign may it notarize.
cached_removed_share_not_counted_test() ->
    C4 = committee(4),
    [C1, _Removed, C3, C4th] = C4,
    C3set = [C1, C3, C4th],
    B = blk(1),
    [S1, SRemoved] = supports(B, C4, 2),
    {E1, _} = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C4), 0)),
    {E2, _} = feed_shares([S1, SRemoved], E1),
    E3 = quod_simplex:eng_set_validators(pubs(C3set), E2),
    {E4, Ev4} = quod_simplex:eng_offer({share, S1}, E3),
    ?assertNot(lists:member({notarized, B}, Ev4)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E4))),
    [_Same, S3, S4] = supports(B, C3set, 3),
    {E5, Ev5} = quod_simplex:eng_offer({share, S3}, E4),
    ?assertNot(lists:member({notarized, B}, Ev5)),
    {E6, Ev6} = quod_simplex:eng_offer({share, S4}, E5),
    ?assert(lists:member({notarized, B}, Ev6)),
    ?assertEqual(B, maps:get(1, quod_simplex:eng_tree(E6))).

%% N=1 (quorum 1): the sole validator's own shares notarize + commit instantly (the degenerate case).
eng_sole_validator_test() ->
    C = committee(1),
    B = blk(1),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C), 0)),
    {E2, Ev2} = feed_shares(supports(B, C, 1), E1),
    ?assert(lists:member({notarized, B}, Ev2)),
    {_E3, Ev3} = feed_shares(commits(B, C, 1), E2),
    ?assert(lists:member({committed, 1, B}, Ev3)).

%% A block whose parent is not yet notarized WAITS, then rides in on the parent's settle (fixpoint).
eng_parent_ordering_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),                              %% B2's parent is slot 1
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C), 0),
    {E1, _}   = quod_simplex:eng_offer({block, B2}, E0),
    {E2, Ev2} = feed_shares(supports(B2, C, 3), E1),       %% B2 fully supported BEFORE B1
    ?assertNot(lists:member({notarized, B2}, Ev2)),
    ?assertNot(maps:is_key(2, quod_simplex:eng_tree(E2))),
    {E3, _}   = quod_simplex:eng_offer({block, B1}, E2),
    {E4, Ev4} = feed_shares(supports(B1, C, 3), E3),
    ?assert(lists:member({notarized, B1}, Ev4)),
    ?assert(lists:member({notarized, B2}, Ev4)),           %% B2 notarizes on the SAME settle as B1
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E4))).

%% Consensus ordering is pipelined independently of state execution: a child can
%% notarize and even obtain its own commit certificate while its parent has no commit
%% certificate yet. The driver buffers finalization and applies slots in order.
eng_child_finalizes_before_parent_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),
    E0 = quod_simplex:eng_new(?DOMAIN, pubs(C), 0),
    {E1, _} = quod_simplex:eng_offer({block, B1}, E0),
    {E2, _} = quod_simplex:eng_offer({block, B2}, E1),
    {E3, _} = feed_shares(supports(B1, C, 3), E2),
    {E4, _} = feed_shares(supports(B2, C, 3), E3),
    ?assert(maps:is_key(1, quod_simplex:eng_tree(E4))),
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E4))),
    ?assertEqual(#{}, quod_simplex:eng_committed(E4)),
    {E5, Events} = feed_shares(commits(B2, C, 3), E4),
    ?assert(lists:member({committed, 1, B1}, Events)),
    ?assert(lists:member({committed, 2, B2}, Events)),
    ?assert(maps:is_key(1, quod_simplex:eng_committed(E5))),
    ?assert(maps:is_key(2, quod_simplex:eng_committed(E5))).

%% A support share from a non-validator does not count toward the quorum.
eng_rejects_outsider_test() ->
    C = committee(4),
    {_, Outsider} = id(),
    B = blk(1),
    {E1, _}    = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C), 0)),
    Bad = quod_simplex:make_share(?DOMAIN, support, 1, quod_simplex:block_hash(B), Outsider),
    {E2, Ev2}  = feed_shares(supports(B, C, 2) ++ [Bad], E1),   %% 2 valid + 1 outsider
    ?assertNot(lists:member({notarized, B}, Ev2)),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E2))).

%% A cert learned from a peer is added + re-disseminated ONCE (never twice), and notarizes the block.
eng_relays_cert_once_test() ->
    C = committee(4),
    B = blk(1),
    {ok, SC} = quod_simplex:form_cert(?DOMAIN, support, 1, quod_simplex:block_hash(B), supports(B, C, 3), pubs(C)),
    {E1, _}   = quod_simplex:eng_offer({block, B}, quod_simplex:eng_new(?DOMAIN, pubs(C), 0)),
    {E2, Ev2} = quod_simplex:eng_offer({cert, SC}, E1),
    ?assert(lists:member({broadcast, SC}, Ev2)),
    ?assert(lists:member({notarized, B}, Ev2)),
    {_E3, Ev3} = quod_simplex:eng_offer({cert, SC}, E2),
    ?assertEqual([], [X || {broadcast, _} = X <- Ev3]).     %% not re-broadcast

%% The Stage-2c leader ROTATES round-robin over the sorted set, order-independently across nodes.
eng_leader_rotates_test() ->
    Ps     = pubs(committee(4)),
    Sorted = lists:sort(Ps),
    ?assertEqual(lists:min(Ps), quod_simplex:leader(1, Ps)),        %% slot 1 → lowest pubkey
    ?assertEqual(hd(tl(Sorted)), quod_simplex:leader(2, Ps)),      %% slot 2 → next (rotation)
    ?assertEqual(quod_simplex:leader(1, Ps), quod_simplex:leader(5, Ps)),   %% wraps at N=4 (1 ≡ 5)
    ?assertNotEqual(quod_simplex:leader(1, Ps), quod_simplex:leader(2, Ps)),
    ?assertEqual(quod_simplex:leader(3, Ps),                        %% order-independent (sorts internally)
                 quod_simplex:leader(3, lists:reverse(Ps))).

%% A ⅔ complaint cert skips the slot: the engine emits {skipped, V} once and re-disseminates the cert.
eng_complaint_skips_test() ->
    C   = committee(4),
    Sh  = [quod_simplex:make_share(?DOMAIN, complaint, 2, none, Id) || {_, Id} <- take(3, C)],   %% quorum(4)=3
    E0  = quod_simplex:eng_new(?DOMAIN, pubs(C), 0),
    {E1, Ev1} = feed_shares(Sh, E0),
    ?assert(lists:member({skipped, 2}, Ev1)),
    ?assert(lists:any(fun({broadcast, #cert{kind = complaint, slot = 2}}) -> true; (_) -> false end, Ev1)),
    {_E2, Ev2} = feed_shares(Sh, E1),                              %% re-offering does NOT re-skip (deduped)
    ?assertEqual([], [X || {skipped, _} = X <- Ev2]).

%% An empty committee has no leader — `leader/2` returns `none` (never `rem 0`-crashes) so a committee that
%% somehow emptied leaves the statem gracefully wedged instead of crash-looping.
leader_empty_committee_test() ->
    ?assertEqual(none, quod_simplex:leader(1, [])),
    ?assertEqual(none, quod_simplex:leader(7, [])).

%% The commit/complaint guards are mutually exclusive per slot — the whole safety argument.
guards_mutual_exclusion_test() ->
    ?assert(quod_simplex:may_commit(5, [])),
    ?assertNot(quod_simplex:may_commit(5, [5])),        %% complained 5 ⇒ must not commit it
    ?assert(quod_simplex:may_complain(5, [])),
    ?assertNot(quod_simplex:may_complain(5, [5])).      %% commit-signed 5 ⇒ must not complain it

%% The committee projection: a transaction's diff folds into {added, removed} `peer_admitted` pubkeys —
%% a re-asserted member is idempotent, a non-peer_admitted op is ignored. `apply_committee_delta/2` applies
%% the delta onto a set, sorted + deduped — the ONE function used by BOTH the boot re-fold AND the live swap
%% on commit, so the running set can never drift from a fresh re-fold. (The end-to-end fold over a committed
%% log is exercised by the gen_statem CT `t_restart_replays`.)
committee_delta_test() ->
    [A, B, C] = [P || {P, _} <- committee(3)],
    Tx = tx([pa(A), pa(B), pa(A), rm(B), {assert, {{other, foo}, true}}]),   %% +A +B +A(dup) -B, noise
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta(Tx)),
    ?assertEqual({[A], [B]}, quod_simplex:committee_delta({batch, [Tx]})),
    ?assertEqual([A], quod_simplex:apply_committee_delta(Tx, [])),
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(Tx, [A, C, B])),  %% A dup, C kept, B dropped
    ?assertEqual({[], []}, quod_simplex:committee_delta({batch, [Tx | bad_tail]})),
    ?assertEqual({[], []}, quod_simplex:committee_delta(noop)),                 %% a noop carries no change
    ?assertEqual(lists:usort([A, C]), quod_simplex:apply_committee_delta(noop, [C, A])).

%% Slice D dial-hint extractor: the SIBLING of committee_delta yielding each peer_admitted ASSERT's
%% {Pk, {Host, Port}}. Retracts and noise yield nothing (removal ≠ reachability change); a `noop` (the
%% skip entries that populate catch-up windows) yields []; last-wins is the map fold's job at the hook.
admitted_endpoints_test() ->
    [A, B, _] = [P || {P, _} <- committee(3)],
    Full = tx([{assert,  {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
               {retract, {{peer_admitted, B, "10.0.0.2", 9002, B}, true}},   %% retract → not a hint
               {assert,  {{other, foo}, true}}]),                            %% noise → ignored
    ?assertEqual([{A, {"10.0.0.1", 9001}}], quod_simplex:admitted_endpoints({batch, [Full]})),
    ?assertEqual([], quod_simplex:admitted_endpoints(noop)),                  %% skip entry: no hint, no crash
    ?assertEqual([], quod_simplex:admitted_endpoints({batch, [tx([rm(A)])]})), %% retract-only
    %% undefined host/port (bare-pubkey genesis members) is EXTRACTED here; is_endpoint drops it at learn.
    ?assertEqual([{A, {undefined, undefined}}],
                 quod_simplex:admitted_endpoints({batch, [tx([pa(A)])]})),
    ?assertEqual([], quod_simplex:admitted_endpoints({batch, [Full | bad_tail]})),
    %% a repeated pubkey yields BOTH assert pairs in order — the maps:from_list at the hook takes last-wins.
    Dup = tx([{assert, {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
              {assert, {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}]),
    ?assertEqual([{A, {"10.0.0.1", 9001}}, {A, {"10.0.0.9", 9009}}],
                 quod_simplex:admitted_endpoints({batch, [Dup]})),
    ?assertEqual({"10.0.0.9", 9009},
                 maps:get(A, maps:from_list(quod_simplex:admitted_endpoints({batch, [Dup]})))).

validator_routes_follow_the_committee_history_test() ->
    [A, B, _] = [P || {P, _} <- committee(3)],
    Ns = <<"routes:history">>,
    P0 = quod_simplex:history_projection(),
    E1 = #entry{index = 1,
                data = {batch, [tx([
                    {assert, {{peer_admitted, A, "10.0.0.1", 9001, A}, true}},
                    {assert, {{peer_admitted, B, "10.0.0.2", 9002, B}, true}}
                ])]}},
    P1 = quod_simplex:history_advance(Ns, E1, P0),
    ?assertEqual(
       #{A => {"10.0.0.1", 9001}, B => {"10.0.0.2", 9002}},
       quod_simplex:history_validator_routes(P1)),
    E2 = #entry{index = 2,
                data = {batch, [tx([
                    {assert, {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}
                ])]}},
    P2 = quod_simplex:history_advance(Ns, E2, P1),
    ?assertEqual(
       #{A => {"10.0.0.9", 9009}, B => {"10.0.0.2", 9002}},
       quod_simplex:history_validator_routes(P2)),
    [{1, Committee, CommitteeId, RefreshedRoutes}] =
        maps:get(committee_views, P2),
    ?assertEqual(lists:sort([A, B]), Committee),
    ?assertEqual(maps:get(committee_id, P1), CommitteeId),
    ?assertEqual(quod_simplex:history_validator_routes(P2), RefreshedRoutes),
    E3 = #entry{index = 3,
                data = {batch, [tx([
                    {retract,
                     {{peer_admitted, A, "10.0.0.9", 9009, A}, true}}
                ])]}},
    P3 = quod_simplex:history_advance(Ns, E3, P2),
    ?assertEqual(#{B => {"10.0.0.2", 9002}},
                 quod_simplex:history_validator_routes(P3)),
    ?assertEqual(2, length(maps:get(committee_views, P3))).

content_only_catchup_repopulates_verified_validator_routes_test() ->
    [Self, Peer | _] = [P || {P, _} <- committee(3)],
    Ns = <<"routes:content-only-catchup">>,
    PeerEndpoint = {"10.0.0.2", 9002},
    Admission =
        #entry{index = 1,
               data = {batch, [tx([
                   {assert, {{peer_admitted, Self,
                              "10.0.0.1", 9001, Self}, true}},
                   {assert, {{peer_admitted, Peer,
                              element(1, PeerEndpoint),
                              element(2, PeerEndpoint), Peer}, true}}
               ])]}},
    Content =
        #entry{index = 2,
               data = {batch, [tx([
                   {assert, {{ordinary_fact, recovered}, true}}
               ])]}},
    P1 = quod_simplex:history_advance(
           Ns, Admission, quod_simplex:history_projection()),
    P2 = quod_simplex:history_advance(Ns, Content, P1),
    ?assertEqual(quod_simplex:history_committee(P1),
                 quod_simplex:history_committee(P2)),
    Dir = relay_store_dir("content_only_catchup_routes"),
    {ok, Store0} = quod_ledger_store:open(Ns, Dir),
    {ok, Store1} = quod_ledger_store:append(Store0, [Admission]),
    quod_quic:ensure_cache(),
    true = ets:delete(quod_addr_cache, Peer),
    ?assertEqual(error, quod_quic:resolve(Peer)),
    try
        Initial = st(#{ns => Ns, self => Self,
                       validators => quod_simplex:history_committee(P1),
                       store => Store1, slot => 1}),
        {Recovered, ok} =
            quod_simplex:test_apply_catchup_window(
              recovery, [Content], P2, Initial),
        ?assertEqual({ok, PeerEndpoint}, quod_quic:resolve(Peer)),
        {2, DurableStore} = quod_simplex:test_committed_store(Recovered),
        ok = quod_ledger_store:close(DurableStore)
    after
        _ = ets:delete(quod_addr_cache, Peer),
        _ = file:del_dir_r(Dir)
    end.

%% Slice A membership gate (deferred.md §3 a+c): a committee-touching transaction must be EXACTLY ONE
%% well-formed `peer_admitted` op that neither empties the committee nor exceeds the validator cap — the
%% pure shape + bounded floor,
%% enforced before a node proposes or supports (the KB-side `can_join` verdict is the next slice).
membership_gate_test() ->
    [A, B] = pubs(committee(2)),
    %% legal single ops
    ?assert(quod_simplex:membership_change_ok(tx([pa(B)]), [A])),        %% admit one member
    ?assert(quod_simplex:membership_change_ok(tx([rm(B)]), [A, B])),     %% stepwise shrink: N=2 → 1
    ?assert(quod_simplex:membership_change_ok(tx([rm(B)]), [A])),        %% non-member retract: shape-legal
                                                                         %% (the KB verdict rejects it later)
    %% the wedge: a change that would EMPTY the committee is never acceptable
    ?assertNot(quod_simplex:membership_change_ok(tx([rm(A)]), [A])),               %% N=1 → 0
    ?assertNot(quod_simplex:membership_change_ok(tx([rm(A), rm(B)]), [A, B])),     %% mass retract
    %% shape violations: exactly one op, nothing else, well-formed head, Id =:= Pk, binary pubkey
    ?assertNot(quod_simplex:membership_change_ok(tx([pa(A), pa(B)]), [])),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([pa(A), {assert, {{other, x}, true}}]), [])),                  %% mixed content+membership
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([{assert, {{peer_admitted, <<"not-the-pk">>, undefined, undefined, A}, true}}]), [])),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([{assert, {{peer_admitted, na, undefined, undefined, na}, true}}]), [A])),
    ?assertNot(quod_simplex:membership_change_ok(tx([{retract, garbage}]), [A])).  %% catch-all is total

membership_gate_enforces_validator_cap_test() ->
    Current = [<<I:256>> || I <- lists:seq(1, ?MAX_VALIDATORS)],
    Candidate = <<(?MAX_VALIDATORS + 1):256>>,
    ?assert(quod_simplex:membership_change_ok(
              tx([pa(lists:last(Current))]),
              lists:sublist(Current, ?MAX_VALIDATORS - 1))),
    ?assertNot(quod_simplex:membership_change_ok(
                 tx([pa(Candidate)]), Current)),
    %% Reasserting an existing member does not grow the set and remains a
    %% shape-valid no-op for the later KB verdict to classify.
    ?assert(quod_simplex:membership_change_ok(
              tx([pa(hd(Current))]), Current)).

%% A non-PROPER-list diff (an improper list `[Op|junk]`, or a non-list) must be rejected, never crash.
%% `binary_to_term` on the untrusted consensus wire can decode either shape, and a shallow `[Op | _]`
%% match would let it through to crash `committee_delta`'s fold during commit/restart.
membership_gate_improper_list_test() ->
    [A] = pubs(committee(1)),
    Improper = tx([{assert, {{other, x}, true}} | 2]),
    NonList  = tx(not_a_list),
    ?assertNot(quod_simplex:change_acceptable(Improper, [A])),
    ?assertNot(quod_simplex:change_acceptable(NonList, [A])),
    ?assert(quod_simplex:change_acceptable(tx([{assert, {{ok, x}, true}}]), [A])),   %% proper: fine
    ?assertNot(quod_simplex:change_acceptable(noop, [A])).

%% Every field consumed after consensus has a structural gate before an honest node signs.
%% In particular, a proper list containing an invalid op used to pass and crash apply_op/3.
transaction_shape_gate_test() ->
    [A] = pubs(committee(1)),
    Good = tx([{assert, {{ok, x}, true}}]),
    ?assert(quod_simplex:change_acceptable(Good, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{diff = [garbage]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{diff = [{assert, {42, true}}]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{diff = [{assert, {{ok, x}, 42}}]}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{read_check = []}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, -1} => {present, 0}}}, [A])),
    %% the pre-token integer-hash value space is rejected outright
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => 12345}}, [A])),
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => {present, -1}}}, [A])),
    %% the transient same-block `staged` marker is never a wire token: admitting
    %% it would let a crafted read set MATCH a same-block staged write
    ?assertNot(quod_simplex:change_acceptable(
                 Good#transaction{read_check = #{{fact, 1} => staged}}, [A])),
    ?assert(quod_simplex:change_acceptable(
              Good#transaction{read_check = #{{fact, 1} => {absent, 4},
                                              {other, 2} => never_present,
                                              {sys, 3} => static}}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{tx_id = <<>>}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{submitted_at = 1.5}, [A])),
    ?assertNot(quod_simplex:change_acceptable(Good#transaction{sig = unsigned}, [A])).

%% Every `peer_admitted` fact is a voter (no non-voting tier): asserting one grows the set and the quorum.
committee_grows_test() ->
    [A, B] = [P || {P, _} <- committee(2)],
    Members1 = quod_simplex:apply_committee_delta(tx([pa(A)]), []),
    Members2 = quod_simplex:apply_committee_delta(tx([pa(B)]), Members1),
    ?assertEqual([A], Members1),
    ?assertEqual(lists:usort([A, B]), Members2),
    ?assertEqual(1, quod_simplex:quorum(length(Members1))),
    ?assertEqual(2, quod_simplex:quorum(length(Members2))).

%% Pruning a committed slot advances `base` and drops it from every map (the memory-leak fix), and a
%% stale share/cert/block for an already-final slot (`=< base`) is then ignored.
eng_prune_test() ->
    C = committee(4),
    B1 = blk(1), B2 = blk(2),
    {E1, _} = quod_simplex:eng_offer({block, B1}, quod_simplex:eng_new(?DOMAIN, pubs(C), 0)),
    {E2, _} = quod_simplex:eng_offer({block, B2}, E1),
    {E3, _} = feed_shares(supports(B1, C, 3) ++ supports(B2, C, 3), E2),
    {E4, _} = feed_shares(commits(B1, C, 3) ++ commits(B2, C, 3), E3),
    ?assert(maps:is_key(1, quod_simplex:eng_committed(E4))),
    ?assert(maps:is_key(2, quod_simplex:eng_committed(E4))),
    %% prune past slot 1: slot 1 is dropped from tree + committed; slot 2 is retained
    E5 = quod_simplex:eng_prune(1, E4),
    ?assertNot(maps:is_key(1, quod_simplex:eng_tree(E5))),
    ?assertNot(maps:is_key(1, quod_simplex:eng_committed(E5))),
    ?assert(maps:is_key(2, quod_simplex:eng_tree(E5))),
    %% a stale support share for the pruned slot 1 (=< base) is ignored — no event, no state change
    {E6, Ev6} = quod_simplex:eng_offer({share, hd(supports(B1, C, 1))}, E5),
    ?assertEqual([], Ev6),
    ?assertEqual(quod_simplex:eng_committed(E5), quod_simplex:eng_committed(E6)).

%%%===================================================================
%%% helpers
%%%===================================================================

relay_receiver_fixture(TxId) ->
    Ns = <<"t">>,
    Committee = committee(4),
    Validators = pubs(Committee),
    Slot = 4,
    Target = quod_simplex:leader(Slot, Validators),
    {Target, TargetId} = lists:keyfind(Target, 1, Committee),
    {Author, AuthorId} =
        hd([Member || {Pub, _} = Member <- Committee, Pub =/= Target]),
    Tx = signed_tx(
           Ns, TxId, [{assert, {{relay_fixture, TxId}, true}}],
           {Author, AuthorId}),
    {ok, Submission} = quod_transaction:submission(
                         test_binding(Ns, Author), Tx),
    SubmissionId = quod_transaction:submission_id(Submission),
    CommitteeId =
        crypto:hash(sha256, <<"fixture-view:", TxId/binary>>),
    AttemptId =
        quod_transaction:relay_attempt_id(
          Ns, SubmissionId, CommitteeId, Slot, Target),
    Submit =
        {relay_submit, SubmissionId, AttemptId, CommitteeId,
         Slot, Submission, []},
    S = st(#{self => Target, id => TargetId,
             validators => Validators, committee_id => CommitteeId,
             relay_conns => #{Author => {self(), make_ref()}},
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Ns, CommitteeId, Slot, Author, AuthorId, Target, Validators,
     SubmissionId, AttemptId, Submit, S}.

outbound_fixture(TxId) ->
    Ns = <<"t">>,
    Committee = committee(4),
    Validators = pubs(Committee),
    Slot = 4,
    Target = quod_simplex:leader(Slot, Validators),
    NextTarget = quod_simplex:leader(Slot + 1, Validators),
    {Me, MyId} =
        hd([Member || {Pub, _} = Member <- Committee,
                      Pub =/= Target, Pub =/= NextTarget]),
    CommitteeId =
        crypto:hash(sha256, <<"outbound-view:", TxId/binary>>),
    Change = bind_test_id(
               #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                            proof_id = <<0:256>>, plan_digest = <<0:256>>,
                            goal = durable_goal({relay, TxId}),
                            result = durable_result(),
                            author = Me,
                            sig = none, read_check = #{},
                            diff = [{assert,
                                     {{relay_outbound, TxId}, true}}]}),
    From = {self(), make_ref()},
    S = st(#{self => Me, id => MyId, validators => Validators,
             committee_id => CommitteeId,
             relay_conns => #{Target => {self(), make_ref()},
                              NextTarget => {self(), make_ref()}},
             sync => ready, slot => 3, approved => 3,
             eng => quod_simplex:eng_with_certs(3, [])}),
    {Sent, []} = quod_simplex:test_append(From, Change, S),
    Frame = receive_ordered_frame(),
    {relay,
     {relay_submit, SubmissionId, AttemptId, CommitteeId, Slot,
      _Submission, _Carrier}} =
        quod_relay:decode_relay_frame(Frame, Ns),
    {Ns, CommitteeId, Slot, From, Target, Validators,
     SubmissionId, AttemptId, Frame, Sent}.

relay_store_dir(Suffix) ->
    filename:join(
      "/tmp",
      "quod_relay_restart_" ++ Suffix ++ "_"
      ++ integer_to_list(erlang:unique_integer([positive]))).

with_dtx_admission_fixture(Fun) when is_function(Fun, 4) ->
    {ok, _} = application:ensure_all_started(gproc),
    Fixture = quod_ct:signed_dtx_begin_fixture(#{}),
    {Ns, Anchor} = maps:get(target, Fixture),
    Begin = maps:get('begin', Fixture),
    {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
    #{pubkey := Author} = Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    true = quod_reg:reg({quod_prolog, Ns}),
    try
        S0 = st(#{ns => Ns, genesis_hash => Anchor,
                  self => Author, id => Identity,
                  validators => [Author],
                  author_admissions => #{Author => Admission},
                  sync => ready, prolog_ready => true,
                  eng => quod_simplex:eng_with_certs(0, [])}),
        Fun(Fixture, Begin, GroupRef, S0)
    after
        true = gproc:unreg(quod_reg:name({quod_prolog, Ns}))
    end.

dtx_admission_variants(Fixture, Count) ->
    Origin = maps:get(target, Fixture),
    Identity = maps:get(node_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    [begin
         TargetNs = iolist_to_binary(
                      [<<"quod:dtx-admission-target-">>,
                       integer_to_binary(I)]),
         Target = {TargetNs, crypto:hash(sha256, TargetNs)},
         Variant = quod_ct:signed_dtx_begin_fixture(
                     #{target => Origin, participant_target => Target,
                       node_identity => Identity, admission => Admission,
                       proof_id => <<I:256>>, submitted_at => I}),
         Begin = maps:get('begin', Variant),
         {ok, GroupRef} = quod_dtx:begin_group_ref(Begin),
         {Begin, GroupRef}
     end || I <- lists:seq(1, Count)].

committed_dtx_test_entry(Control, Slot) ->
    {ok, Envelope} = quod_dtx:encode_control(Control),
    Payload = {batch, [{dtx, Envelope}]},
    Block = #block{slot = Slot, parent = Slot - 1,
                   payload = Payload, timestamp = 0},
    BlockHash = quod_simplex:block_hash(Block),
    {#entry{index = Slot, data = Payload,
            cert = #cert{kind = commit, slot = Slot,
                         block_hash = BlockHash, sigs = []}},
     Payload}.

certified_dtx_test_entry(Identity, Control, Slot) ->
    {Entry, Payload} = committed_dtx_test_entry(Control, Slot),
    {ok, Ref} = quod_dtx:certified_entry_ref(Identity, Entry, Control),
    {Entry, Payload, Ref}.

start_registered_prolog_sink(Ns) ->
    Parent = self(),
    Pid = spawn(
            fun() ->
                true = quod_reg:reg({quod_prolog, Ns}),
                Parent ! {registered_prolog_sink, self()},
                registered_prolog_sink_loop()
            end),
    receive
        {registered_prolog_sink, Pid} -> Pid
    after 1000 ->
        error(prolog_sink_registration_timeout)
    end.

registered_prolog_sink_loop() ->
    receive
        stop -> ok;
        _Message -> registered_prolog_sink_loop()
    end.

stop_registered_prolog_sink(Pid) ->
    MRef = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> ok
    after 1000 ->
        error(prolog_sink_stop_timeout)
    end.

reply_actions(Actions) ->
    [Action || {reply, _From, _Reply} = Action <- Actions].

assert_no_reply({_Pid, Tag}) ->
    receive
        {Tag, _Reply} -> ?assert(false)
    after 0 ->
        ok
    end.

drain_custody_within(S) ->
    Parent = self(),
    ReplyRef = make_ref(),
    {Pid, MonitorRef} =
        spawn_monitor(
          fun() ->
                  Parent !
                      {ReplyRef,
                       quod_simplex:test_drain_custody(S)}
          end),
    receive
        {ReplyRef, Result} ->
            receive
                {'DOWN', MonitorRef, process, Pid, normal} ->
                    Result;
                {'DOWN', MonitorRef, process, Pid, Reason} ->
                    error({custody_drain_failed, Reason})
            after 1000 ->
                exit(Pid, kill),
                error(custody_drain_did_not_exit)
            end;
        {'DOWN', MonitorRef, process, Pid, Reason} ->
            error({custody_drain_failed, Reason})
    after 1000 ->
        exit(Pid, kill),
        receive
            {'DOWN', MonitorRef, process, Pid, _Reason} -> ok
        after 1000 ->
            ok
        end,
        error(custody_drain_timed_out)
    end.

receive_ordered_frame() ->
    receive
        {send_ordered, Frame} -> Frame
    after 0 ->
        error(missing_ordered_relay_frame)
    end.

assert_no_ordered_frame() ->
    receive
        {send_ordered, Frame} ->
            error({unexpected_ordered_relay_frame, Frame})
    after 0 ->
        ok
    end.

receive_relay_control(Ns) ->
    receive
        {send, Frame} ->
            case quod_relay:decode_relay_frame(Frame, Ns) of
                {relay, Relay} -> Relay;
                error -> error({malformed_relay_control, Frame})
            end
    after 0 ->
        error(missing_relay_control_frame)
    end.

assert_no_relay_control() ->
    receive
        {send, Frame} ->
            error({unexpected_relay_control_frame, Frame})
    after 0 ->
        ok
    end.

running_state({keep_state, S}) -> S;
running_state({keep_state, S, _Actions}) -> S.

flush_unordered_link_frames() ->
    receive
        {send, _Frame} -> flush_unordered_link_frames()
    after 0 ->
        ok
    end.

spawn_close_aware_link() ->
    Owner = self(),
    Token = make_ref(),
    Pid =
        spawn(
          fun Loop() ->
                  receive
                      close ->
                          Owner ! {close_aware_link_closed,
                                   Token, self()};
                      _Other ->
                          Loop()
                  end
          end),
    {Pid, Token}.

%% A superseded link can be slow to observe `close` (for example while its
%% mailbox is occupied). Keep it alive until an explicit release so generation
%% tests cannot pass merely because is_process_alive/1 rejects a dead pid.
spawn_stubborn_link() ->
    Owner = self(),
    Token = make_ref(),
    Pid =
        spawn(
          fun Loop() ->
                  receive
                      close ->
                          Owner !
                              {stubborn_link_close_requested,
                               Token, self()},
                          Loop();
                      {release_stubborn_link, Token} ->
                          ok;
                      _Other ->
                          Loop()
                  end
          end),
    {Pid, Token}.

await_stubborn_close_requested(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} -> ok
    after 1000 ->
        error({stubborn_link_was_not_closed, Pid})
    end.

assert_stubborn_link_not_closed(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} ->
            error({live_stubborn_link_was_closed, Pid})
    after 20 ->
        ?assert(is_process_alive(Pid))
    end.

release_stubborn_link(Pid, Token, Ref) ->
    Pid ! {release_stubborn_link, Token},
    receive
        {'DOWN', Ref, process, Pid, _Reason} = Down -> Down
    after 1000 ->
        error({stubborn_link_did_not_exit, Pid})
    end.

ensure_stubborn_link_closed(Pid, Token) ->
    case is_process_alive(Pid) of
        true ->
            Ref = erlang:monitor(process, Pid),
            Pid ! {release_stubborn_link, Token},
            receive
                {'DOWN', Ref, process, Pid, _Reason} -> ok
            after 1000 ->
                _ = erlang:demonitor(Ref, [flush]),
                exit(Pid, kill)
            end;
        false ->
            ok
    end,
    flush_stubborn_close_requested(Pid, Token),
    flush_down_for(Pid).

flush_stubborn_close_requested(Pid, Token) ->
    receive
        {stubborn_link_close_requested, Token, Pid} ->
            flush_stubborn_close_requested(Pid, Token)
    after 0 ->
        ok
    end.

await_link_closed(Pid, Token) ->
    receive
        {close_aware_link_closed, Token, Pid} -> ok
    after 1000 ->
        error({link_was_not_closed, Pid})
    end.

assert_link_not_closed(Pid, Token) ->
    receive
        {close_aware_link_closed, Token, Pid} ->
            error({live_link_was_closed, Pid})
    after 20 ->
        ?assert(is_process_alive(Pid))
    end.

ensure_close_aware_link_closed(Pid, Token) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! close,
            await_link_closed(Pid, Token);
        false ->
            receive
                {close_aware_link_closed, Token, Pid} -> ok
            after 0 ->
                ok
            end
    end,
    flush_down_for(Pid).

flush_down_for(Pid) ->
    receive
        {'DOWN', _Ref, process, Pid, _Reason} ->
            flush_down_for(Pid)
    after 0 ->
        ok
    end.

take(N, L) -> lists:sublist(L, N).

flip1(<<B, Rest/binary>>) -> <<(B bxor 1), Rest/binary>>.

%% a committee of N validators as [{Pubkey, IdentityMap}]; pubs/1 = just the node_ids
committee(N) -> [id() || _ <- lists:seq(1, N)].
pubs(C)      -> [P || {P, _} <- C].

%% Run each honest node through an ordered list of vote steps against the REAL guards, threading its own
%% {Committed, Complained} latch; returns {AllComplaintShares, AllCommitShares}. A step emits a share only
%% if the guard permits (mirroring apply_event/on_progress_timeout), so the cross-slot exclusion decides
%% which shares exist. Used by fork_certs_cannot_coexist_test.
run_schedule(Committee, Steps) ->
    lists:foldl(
      fun({_Pub, Id}, {CplAcc, CmtAcc}) ->
          {Cpl, Cmt, _Latch} = lists:foldl(fun(Step, A) -> guarded_vote(Step, Id, A) end,
                                           {[], [], {[], []}}, Steps),
          {Cpl ++ CplAcc, Cmt ++ CmtAcc}
      end, {[], []}, Committee).

guarded_vote({complaint, Sl, none}, Id, {Cpl, Cmt, {Committed, Complained}}) ->
    case quod_simplex:may_complain(Sl, Committed) of   %% barred if this node committed Sl or its child Sl+1
        true  -> {[quod_simplex:make_share(?DOMAIN, complaint, Sl, none, Id) | Cpl], Cmt, {Committed, [Sl | Complained]}};
        false -> {Cpl, Cmt, {Committed, Complained}}
    end;
guarded_vote({commit, Sl, BH}, Id, {Cpl, Cmt, {Committed, Complained}}) ->
    case quod_simplex:may_commit(Sl, Complained) of    %% barred if this node complained Sl or its parent Sl-1
        true  -> {Cpl, [quod_simplex:make_share(?DOMAIN, commit, Sl, BH, Id) | Cmt], {[Sl | Committed], Complained}};
        false -> {Cpl, Cmt, {Committed, Complained}}
    end.

%% committee-projection fixtures: a transaction whose diff is a list of peer_admitted asserts/retracts
pa(Pk)  -> {assert,  {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
rm(Pk)  -> {retract, {{peer_admitted, Pk, undefined, undefined, Pk}, true}}.
tx(Ops) -> #transaction{tx_id = <<"t">>, origin = {<<"ns">>, <<0:256>>},
                        proof_id = <<0:256>>, plan_digest = <<0:256>>,
                        goal = durable_goal(test), result = durable_result(),
                        diff = Ops,
                        read_check = #{}, author = <<1:256>>, sig = none}.

signed_tx(Ns, TxId, Ops, {Pub, Identity}) ->
    signed_tx_seq(Ns, TxId, erlang:phash2(TxId) + 1, Ops,
                  {Pub, Identity}).

signed_tx_seq(Ns, Label, Seq, Ops, {Pub, Identity}) ->
    PlanDigest = <<Seq:256>>,
    Unsigned = quod_transaction:bind_id(
                 {Ns, <<0:256>>},
                 #transaction{tx_id = <<>>, origin = {Ns, <<0:256>>},
                              proof_id = <<Seq:256>>,
                              plan_digest = PlanDigest,
                              goal = durable_goal({signed, Label}),
                              result = durable_result(),
                              diff = Ops,
                              read_check = #{}, author = Pub,
                              author_seq = Seq, sig = none}),
    %% The engine fixtures run with the test default genesis anchor <<0:256>>
    %% (`#s.genesis_hash`), so signatures bind the same identity the engine
    %% verifies against.
    {ok, Signed} = quod_transaction:sign(
                     test_binding(Ns, Pub), Unsigned, Identity),
    Signed.

test_binding(Ns, Pub) ->
    {Ns, <<0:256>>, quod_simplex:test_author_admission(Pub)}.

durable_goal(Goal) ->
    {ok, Blob} = quod_durable_term:encode_goal(Goal),
    Blob.

durable_result() ->
    {ok, Blob} = quod_durable_term:encode_result(#{}),
    Blob.

dtx_test_ref({Ns, Anchor}, Slot, Digest) ->
    {ok, Ref} = quod_dtx:certified_ref(
                  Ns, Anchor, Slot, <<(200 + Slot):256>>, Digest, <<"qc">>),
    Ref.

bind_test_id(Transaction) ->
    quod_transaction:bind_id({<<"t">>, <<0:256>>}, Transaction).

decode_submission(Ns, {submit, Author, _Signature, _Canonical} = Submission) ->
    quod_transaction:decode_verified_submission(
      test_binding(Ns, Author), Submission).

%% support/commit shares for block B from the first K committee members
supports(B, C, K) -> [quod_simplex:make_share(?DOMAIN, support, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
commits(B, C, K)  -> [quod_simplex:make_share(?DOMAIN, commit, B#block.slot, quod_simplex:block_hash(B), Id)
                      || {_, Id} <- take(K, C)].
complaint_share(Slot, {_Pub, Id}) ->
    quod_simplex:make_share(?DOMAIN, complaint, Slot, none, Id).

dispatch_shares(Shares, S) ->
    lists:foldl(
      fun(#share{signer = Peer} = Share, Acc) ->
              quod_simplex:dispatch(Peer, {share, Share}, Acc)
      end, S, Shares).

%% offer each share to the engine in turn, accumulating all emitted events
feed_shares(Shares, Eng) ->
    lists:foldl(fun(S, {E, Evs}) ->
                    {E1, Es} = quod_simplex:eng_offer({share, S}, E),
                    {E1, Evs ++ Es}
                end, {Eng, []}, Shares).

unique_gate_namespace(Label) ->
    <<"gate:", Label/binary, ":",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

with_simplex_gate(Ns, Row, Fun) ->
    Name = binary_to_atom(<<"quod_simplex_genesis_", Ns/binary>>, utf8),
    Tab = ets:new(Name, [named_table, protected, set]),
    true = ets:insert(Tab, [{anchor, <<0:256>>}, Row]),
    try Fun(Tab)
    after
        ets:delete(Tab)
    end.

registered_prolog_owner(Ns) ->
    Parent = self(),
    Pid = spawn_link(
            fun() ->
                true = quod_reg:reg({quod_prolog, Ns}),
                Parent ! {registered_prolog_owner, self()},
                receive stop -> ok end
            end),
    receive
        {registered_prolog_owner, Pid} -> Pid
    after 1000 ->
        error(prolog_owner_registration_timeout)
    end.

stop_registered_owner(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        error(prolog_owner_stop_timeout)
    end.

without_network_identity(Fun) when is_function(Fun, 0) ->
    SavedDesired = application:get_env(quod, namespace_desired),
    application:unset_env(quod, namespace_desired),
    try Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

with_network_identity(<<_:256>> = NetworkIdentity, Fun)
  when is_function(Fun, 0) ->
    SavedDesired = application:get_env(quod, namespace_desired),
    Desired0 = application:get_env(quod, namespace_desired, #{}),
    Content0 = maps:get(content, Desired0, #{}),
    RootNs = quod_ontology:root_ns(),
    Root0 = maps:get(RootNs, Content0, #{}),
    application:set_env(
      quod, namespace_desired,
      Desired0#{content =>
                    Content0#{RootNs =>
                                  Root0#{genesis_hash => NetworkIdentity}}}),
    try Fun()
    after
        case SavedDesired of
            {ok, Desired} ->
                application:set_env(quod, namespace_desired, Desired);
            undefined ->
                application:unset_env(quod, namespace_desired)
        end
    end.

validation_owner() ->
    receive stop -> ok end.

registered_dormant_operation(Suffix) ->
    Fixture = quod_ct:signed_effect_operation_submission(),
    {Ns, Anchor} = maps:get(origin, Fixture),
    Identity = #{pubkey := Author} = maps:get(source_identity, Fixture),
    Admission = maps:get(admission, Fixture),
    SignedClaim = maps:get(claim, Fixture),
    UnsignedClaim = SignedClaim#transaction{author_seq = 0, sig = none},
    TxId = SignedClaim#transaction.tx_id,
    Owner = spawn(fun validation_owner/0),
    Dir = relay_store_dir("dormant_operation_" ++ Suffix),
    {ok, Journal} = quod_signing_journal:initialize(Ns, ?DOMAIN, Dir),
    S0 = st(#{ns => Ns, genesis_hash => Anchor,
              self => Author, id => Identity, validators => [Author],
              author_admissions => #{Author => Admission},
              signing_journal => Journal, sync => ready,
              eng => quod_simplex:eng_with_certs(0, [])}),
    {ok, Submission, S1} =
        quod_simplex:test_register_dormant_transaction(
          Admission, UnsignedClaim, Owner, S0),
    ?assertEqual(maps:get(submission, Fixture), Submission),
    {Dir, Fixture, Owner, TxId, S1}.

cancellation_test_starter(Parent) ->
    fun(_Ns, Submission) ->
            Pid = spawn(
                    fun() ->
                            ParentMonitor = erlang:monitor(process, Parent),
                            receive
                                stop -> ok;
                                {'DOWN', ParentMonitor, process, Parent, _} -> ok
                            end
                    end),
            Monitor = erlang:monitor(process, Pid),
            Parent ! {cancellation_started, Submission, Pid, Monitor},
            {ok, Pid, Monitor}
    end.

ensure_process_stopped(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> exit(Pid, kill);
        false -> ok
    end.

test_blocked_process() ->
    receive stop -> ok end.

test_link_probe(Parent) ->
    receive
        {send_ordered, Frame} ->
            Parent ! {dtx_link_sent, self(), Frame},
            test_link_probe(Parent);
        close ->
            Parent ! {dtx_link_closed, self()};
        stop ->
            ok
    end.

with_transport_stub(Fun) when is_function(Fun, 0) ->
    ?assertEqual(undefined, quod_reg:where({transport, node})),
    Parent = self(),
    Stub = spawn(
             fun() ->
                 true = quod_reg:reg({transport, node}),
                 Parent ! {transport_stub_ready, self()},
                 transport_stub_loop(Parent)
             end),
    receive {transport_stub_ready, Stub} -> ok
    after 1000 -> error(transport_stub_registration_timeout)
    end,
    try Fun()
    after
        Ref = monitor(process, Stub),
        Stub ! stop,
        receive {'DOWN', Ref, process, Stub, normal} -> ok
        after 1000 -> error(transport_stub_stop_timeout)
        end
    end.

transport_stub_loop(Parent) ->
    receive
        {'$gen_cast', Message} ->
            Parent ! {transport_cast, Message},
            transport_stub_loop(Parent);
        stop ->
            ok;
        _Other ->
            transport_stub_loop(Parent)
    end.

receive_exact_lease_release(Peer, Endpoint, Channel, Ref) ->
    ?assertEqual(
       {Peer, Endpoint, Channel, Ref},
       receive_any_lease_release()).

receive_any_lease_release() ->
    receive
        {transport_cast,
         {release_link_pinned, Peer, Endpoint, Channel,
          {Caller, Ref}}} when Caller =:= self() ->
            {Peer, Endpoint, Channel, Ref}
    after 1000 ->
        error(missing_exact_lease_release)
    end.

assert_no_transport_cast() ->
    receive
        {transport_cast, Unexpected} ->
            error({unexpected_transport_cast, Unexpected})
    after 0 ->
        ok
    end.

result_state(Result) -> element(2, Result).
