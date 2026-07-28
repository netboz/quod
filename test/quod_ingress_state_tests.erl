-module(quod_ingress_state_tests).

-include_lib("eunit/include/eunit.hrl").
-include("quod_ledger.hrl").

-define(NS, <<"ingress-state:test">>).
-define(CID, <<"committee-1">>).

view_source_change_with_same_facts_does_not_wake_test() ->
    [A, B] = validators(),
    Facts = facts(B, [A, B]),
    S0 = quod_ingress_state:new(),
    S1 = quod_ingress_state:put_view(source_1, Facts, S0),
    ?assertEqual(source_1, quod_ingress_state:view_source(S1)),
    S2 = quod_ingress_state:put_view(source_2, Facts, S1),
    ?assertEqual(source_2, quod_ingress_state:view_source(S2)),
    ?assertEqual(quod_ingress_state:fingerprint(S1),
                 quod_ingress_state:fingerprint(S2)),
    S3 = quod_ingress_state:put_view(
           source_3, Facts#{proposal_visible => true}, S2),
    ?assertNotEqual(quod_ingress_state:fingerprint(S2),
                    quod_ingress_state:fingerprint(S3)).

validator_order_is_canonicalized_once_per_view_test() ->
    [A, B] = validators(),
    Ordered = with_view(B, [A, B], #{}),
    Reversed = with_view(B, [B, A], #{}),
    ?assertEqual(quod_ingress_state:fingerprint(Ordered),
                 quod_ingress_state:fingerprint(Reversed)),
    Request = request(<<"canonical-leader">>, B, 0, none, false),
    ?assertEqual({collect, 4}, route(entry, local, Request, Ordered)),
    ?assertEqual({collect, 4}, route(entry, local, Request, Reversed)).

capability_gates_remain_lazy_but_relay_validation_is_first_test() ->
    [A, B] = validators(),
    Request = request(<<"lazy">>, B, 0, none, false),
    MustNotRun = fun() -> erlang:error(validation_ran) end,
    Demoted = with_view(B, [A, B], #{capability => reject}),
    Recovering = with_view(B, [A, B], #{capability => hold}),
    ?assertEqual(
       {redirect, Request},
       quod_ingress_state:route(
         entry, local, Request, MustNotRun, Demoted)),
    ?assertEqual(
       {{park, awaiting_turn}, Request},
       quod_ingress_state:route(
         drain, custody, Request,
         MustNotRun, Recovering)),
    ?assertException(
       error, validation_ran,
       quod_ingress_state:route(
         entry, {relayed, ?CID, 4}, Request,
         MustNotRun, Recovering)).

local_route_and_fifo_truth_table_test() ->
    [A, B] = validators(),
    Request = request(<<"local">>, B, 0, none, false),
    S0 = with_view(B, [A, B], #{}),
    ?assertEqual(
       {collect, 4},
       route(entry, local, Request, S0)),
    Prepared = prepared(Request, S0),
    {ok, 1, S1} =
        quod_ingress_state:enqueue(
          local, waiter, Prepared, 10, S0),
    ?assertEqual(
       {park, fifo},
       route(entry, local, Request, S1)),
    ?assertEqual(
       {collect, 4},
       route(drain, local, Request, S1)),
    S2 = with_view(A, [A, B], #{}),
    ?assertEqual(
       {relay, B, 4},
       route(entry, local,
             request(<<"relay">>, A, 0, none, false),
             S2)).

relay_owner_and_recovery_truth_table_test() ->
    [A, B] = validators(),
    Signed = request(<<"signed">>, A, 1, <<0:512>>, false),
    Ready = with_view(B, [A, B], #{}),
    ?assert(quod_ingress_state:relay_target_open(
              {?CID, 4}, Ready)),
    ?assertNot(quod_ingress_state:relay_target_open(
                 {?CID, 5}, Ready)),
    ?assertNot(quod_ingress_state:relay_target_open(
                 {<<"old-committee">>, 4}, Ready)),
    ?assertEqual(
       {collect, 4},
       route(
         entry, {relayed, ?CID, 4}, Signed, Ready)),
    Recovering =
        with_view(
          B, [A, B],
          #{capability => hold}),
    ?assertEqual(
       redirect,
       route(
         entry, local,
         request(<<"unsigned">>, B, 0, none, false),
         Recovering)),
    ?assertEqual(
       {park, awaiting_turn},
       route(
         entry, {relayed, ?CID, 4}, Signed, Recovering)),
    Demoted =
        with_view(
          B, [A, B],
          #{capability => reject}),
    ?assertEqual(
       redirect,
       route(
         entry, {relayed, ?CID, 4}, Signed, Demoted)).

custody_preserves_ambiguity_and_sequence_test() ->
    [A, B] = validators(),
    Invalid =
        request(<<"invalid-custody">>, A, 8, <<0:512>>, false),
    Demoted =
        with_view(
          B, [A, B],
          #{capability => reject,
            approved_author_seqs => {ok, #{A => 7}}}),
    ?assertEqual(
       {park, awaiting_turn},
       element(
         1,
         quod_ingress_state:route(
           drain, custody,
           Invalid, fun() -> invalid end, Demoted))),
    Stale =
        with_view(
          B, [A, B],
          #{approved_author_seqs => {ok, #{A => 8}}}),
    Valid =
        request(<<"stale-custody">>, A, 8, <<0:512>>, false),
    ?assertEqual(
       {reject, stale_seq},
       route(
         drain, custody, Valid, Stale)),
    Unknown =
        with_view(
          B, [A, B],
          #{approved_author_seqs => error}),
    ?assertEqual(
       {park, awaiting_turn},
       route(
         drain, custody, Valid, Unknown)).

barrier_future_slot_and_capacity_truth_table_test() ->
    [A, B] = validators(),
    Local = request(<<"local">>, B, 0, none, false),
    Barrier =
        with_view(B, [A, B], #{membership_barrier => true}),
    ?assertEqual(
       {park, barrier},
       route(entry, local, Local, Barrier)),
    Future =
        with_view(
          B, [A, B],
          #{proposal_slot => blocked,
            approved => 3,
            proposal_visible => false}),
    Signed = request(<<"future">>, A, 1, <<0:512>>, false),
    ?assertEqual(
       {park, awaiting_turn},
       route(
         entry, {relayed, ?CID, 6}, Signed, Future)),
    FullBatch =
        with_view(
          B, [A, B],
          #{collecting => {4, 256, 100}}),
    ?assertEqual(
       {park, awaiting_turn},
       route(entry, local, Local, FullBatch)),
    Membership =
        request(<<"membership">>, B, 0, none, true),
    NonEmptyBatch =
        with_view(
          B, [A, B],
          #{collecting => {4, 1, 100}}),
    ?assertEqual(
       {park, awaiting_turn},
       route(
         entry, local, Membership, NonEmptyBatch)),
    OversizedChange =
        (tx(<<"oversized">>, B, 0, none))#transaction{
          goal = binary:copy(<<0>>, 262144)},
    Oversized = quod_ingress_state:request(OversizedChange),
    ?assertEqual(
       {reject, too_large},
       route(
         entry, local, Oversized,
         with_view(B, [A, B], #{}))).

request_size_is_cached_in_queue_accounting_test() ->
    [_A, B] = validators(),
    Change = tx(<<"sized">>, B, 0, none),
    Request = quod_ingress_state:request(Change),
    State = with_view(B, validators(), #{}),
    Prepared = prepared(Request, State),
    {ok, 1, Queued} =
        quod_ingress_state:enqueue(
          local, waiter, Prepared, 10, State),
    Expected =
        byte_size(term_to_binary(Change, [deterministic])) + 96 + 6,
    ?assertEqual(
       #{count => 1, bytes => Expected, authors => #{B => 1}},
       quod_ingress_state:summary(Queued)).

queue_order_restore_expiry_and_reset_test() ->
    [A, B] = validators(),
    R1 = request(<<"one">>, A, 0, none, false),
    R2 = request(<<"two">>, B, 0, none, false),
    S0 = with_view(B, [A, B], #{}),
    P1 = prepared(R1, S0),
    P2 = prepared(R2, S0),
    {ok, 1, S1} =
        quod_ingress_state:enqueue(
          local, waiter_1, P1, 10, S0),
    {ok, 2, S2} =
        quod_ingress_state:enqueue(
          {relayed, ?CID, 4}, waiter_2, P2, 20, S1),
    {First, S3} = quod_ingress_state:detach_front(S2),
    ?assertMatch(
       {local, waiter_1, _, 10},
       quod_ingress_state:item(First)),
    %% A temporary pop does not churn byte/author accounting. Only consuming
    %% the item releases its bounded-queue capacity.
    ?assertEqual(quod_ingress_state:summary(S2),
                 quod_ingress_state:summary(S3)),
    Restored =
        quod_ingress_state:restore_detached_front_rev(
          [First], S3),
    {[Expired], Remaining} =
        quod_ingress_state:take_expired(15, Restored),
    ?assertMatch(
       {local, waiter_1, _, 10},
       quod_ingress_state:item(Expired)),
    [Second] = quod_ingress_state:items(Remaining),
    ?assertMatch(
       {{relayed, ?CID, 4}, waiter_2, _, 20},
       quod_ingress_state:item(Second)),
    ?assertEqual(1, quod_ingress_state:count(Remaining)),
    Source = quod_ingress_state:view_source(Remaining),
    {[Second], Reset} =
        quod_ingress_state:take_all(Remaining),
    ?assertEqual(0, quod_ingress_state:count(Reset)),
    ?assertEqual(Source, quod_ingress_state:view_source(Reset)).

queue_per_author_bound_test() ->
    [A, B] = validators(),
    Request = request(<<"bounded">>, A, 0, none, false),
    S0 = with_view(B, [A, B], #{}),
    Prepared = prepared(Request, S0),
    S64 = enqueue_n(64, Prepared, S0),
    ?assertEqual(
       full,
       quod_ingress_state:enqueue(
         local, overflow, Prepared, 65, S64)),
    Other = request(<<"other">>, B, 0, none, false),
    OtherPrepared = prepared(Other, S64),
    {ok, 65, S65} =
        quod_ingress_state:enqueue(
          local, other, OtherPrepared, 66, S64),
    ?assertEqual(#{A => 64, B => 1},
                 maps:get(authors,
                          quod_ingress_state:summary(S65))).

fingerprints_separate_queue_and_custody_wakes_test() ->
    [A, B] = validators(),
    S0 = with_view(B, [A, B], #{}),
    Ingress0 = quod_ingress_state:fingerprint(S0),
    Custody0 = quod_ingress_state:custody_fingerprint(S0),
    Request = request(<<"queued">>, A, 0, none, false),
    Prepared = prepared(Request, S0),
    {ok, 1, S1} =
        quod_ingress_state:enqueue(
          local, waiter, Prepared, 10, S0),
    ?assertNotEqual(Ingress0,
                    quod_ingress_state:fingerprint(S1)),
    {ok, 2, S1SameAuthor} =
        quod_ingress_state:enqueue(
          local, second_waiter, Prepared, 11, S1),
    ?assertEqual(quod_ingress_state:fingerprint(S1),
                 quod_ingress_state:fingerprint(S1SameAuthor)),
    OtherRequest = request(<<"other-author">>, B, 0, none, false),
    OtherPrepared = prepared(OtherRequest, S1SameAuthor),
    {ok, 3, S1OtherAuthor} =
        quod_ingress_state:enqueue(
          local, other_waiter, OtherPrepared, 12, S1SameAuthor),
    ?assertNotEqual(
       quod_ingress_state:fingerprint(S1SameAuthor),
       quod_ingress_state:fingerprint(S1OtherAuthor)),
    ?assertEqual(Custody0,
                 quod_ingress_state:custody_fingerprint(
                   S1OtherAuthor)),
    Facts = facts(B, [A, B]),
    S2 = quod_ingress_state:put_view(
           changed, Facts#{custody_ready => 1}, S1OtherAuthor),
    ?assertNotEqual(
       quod_ingress_state:custody_fingerprint(S1OtherAuthor),
       quod_ingress_state:custody_fingerprint(S2)),
    S3 =
        quod_ingress_state:put_view(
          one_relay,
          Facts#{custody_ready => 1,
                 relay_lane => {A, 4},
                 relay_pending_count => 1},
          S2),
    S4 =
        quod_ingress_state:put_view(
          two_relays,
          Facts#{custody_ready => 1,
                 relay_lane => {A, 4},
                 relay_pending_count => 2},
          S3),
    ?assertEqual(quod_ingress_state:fingerprint(S3),
                 quod_ingress_state:fingerprint(S4)),
    ?assertNotEqual(
       quod_ingress_state:custody_fingerprint(S3),
       quod_ingress_state:custody_fingerprint(S4)).

enqueue_n(0, _Request, State) ->
    State;
enqueue_n(N, Request, State) ->
    {ok, _Depth, State1} =
        quod_ingress_state:enqueue(
          local, {waiter, N}, Request, N, State),
    enqueue_n(N - 1, Request, State1).

with_view(Self, Validators, Overrides) ->
    quod_ingress_state:put_view(
      test_source,
      maps:merge(facts(Self, Validators), Overrides),
      quod_ingress_state:new()).

facts(Self, Validators) ->
    #{self => Self,
      capability => accept,
      committee_id => ?CID,
      validators => Validators,
      durable_head => 3,
      approved => 3,
      proposal_visible => false,
      proposal_slot => {ok, 4},
      membership_barrier => false,
      approved_author_seqs => {ok, #{}},
      collecting => none,
      custody_lane => empty,
      custody_ready => 0,
      relay_lane => empty,
      relay_pending_count => inactive}.

request(Id, Author, Seq, Sig, Membership) ->
    Change0 = tx(Id, Author, Seq, Sig),
    Change =
        case Membership of
            true ->
                Change0#transaction{
                  diff =
                      [{assert,
                        {{peer_admitted, Author, "host", 1, Author},
                         true}}]};
            false ->
                Change0
        end,
    quod_ingress_state:request(Change).

route(Pass, Origin, Request, State) ->
    {Decision, _Prepared} =
        quod_ingress_state:route(
          Pass, Origin, Request,
          fun() ->
                  {valid, request_is_membership(Request)}
          end,
          State),
    Decision.

prepared(Request, State) ->
    {_Decision, Prepared} =
        quod_ingress_state:route(
          entry, local, Request,
          fun() ->
                  {valid, request_is_membership(Request)}
          end,
          State),
    Prepared.

request_is_membership(Request) ->
    #transaction{diff = Diff} =
        quod_ingress_state:request_change(Request),
    lists:any(
      fun({assert, {{peer_admitted, _, _, _, _}, _}}) -> true;
         ({retract, {{peer_admitted, _, _, _, _}, _}}) -> true;
         (_) -> false
      end, Diff).

tx(Id, Author, Seq, Sig) ->
    #transaction{
       tx_id = Id,
       caller_ns = ?NS,
       goal = undefined,
       result = undefined,
       diff = [{assert, {{ingress_test, Id}, true}}],
       read_check = #{},
       author = Author,
       author_seq = Seq,
       submitted_at = 0,
       sig = Sig}.

validators() ->
    [<<1:256>>, <<2:256>>].
