-module(quod_explorer_http).
-moduledoc """
REST side of the explorer (`m:quod_explorer`): JSON reads over the durable
ledger and the running consensus/kb processes.

| endpoint | answers |
| -------- | ------- |
| `GET /api/summary` | node identity + per-namespace consensus status (height, committee, finality head, next proposer…) |
| `GET /api/txs?ns=&before=&limit=` | committed ledger records newest-first, paged back through the block log |
| `GET /api/tx/:ns/:id` | one transaction outcome by its target-anchored durable index |
| `GET /api/block/:ns/:slot` | one committed block, with its quorum certificate |

History reads borrow the registered Simplex owner's immutable committed snapshot,
never the writer's handle or a path-based fallback. All three history endpoints
accept `mode=offline` for explicitly selected stopped-ledger inspection; omitted
mode means live, and an unavailable live owner returns HTTP 503. Offline mode
refuses a running owner. Exact outcome classification uses the existing compact
DETS index, then enriches terminal detail from that same owner's snapshot.

`explorer.read_budget_ms` bounds one read operation from handler admission,
including capture, disk reads, rendering and outcome enrichment. It is a terminal
deadline, never a retry clock. Synchronous file I/O cannot be interrupted here:
after it returns, an expired read is refused and its handle closed, so this is
not a hard wall-clock bound on the HTTP process. Unauthenticated traffic never
enters the ontology apply server.
Term rendering is real Prolog text via `erlog_io:writeq1/1`; raw binaries inside
terms (pubkeys) are first rewritten to their printable short form. All JSON goes
through OTP's `m:json`.

This module also exports the shared JSON builders `m:quod_explorer_ws` reuses for
the live stream, so a committed record renders identically live and from history.
""".
-export([init/2]).
%% shared with quod_explorer_ws — one rendering of a transaction, live or historical
-export([summary/0, block_json/2, entry_rows/2, tx_id_text/1, encode/1, prolog_text/1,
         prove_result/1]).
-ifdef(TEST).
%% Pure surfaces driven directly by eunit.
-export([txs_page/3, parse_tx_id/1, outcome_json/1,
         committee_status_json/1,
         transaction_outcome/4, tx_json_full/3, entry_txs/1,
         history_mode/1, with_history_store/5, read_deadline/0]).
-endif.
-include("quod_ledger.hrl").

-define(DEFAULT_PAGE, 25).
-define(MAX_PAGE, 100).
-define(SCAN_SLOTS, 1000).          %% max blocks walked per /api/txs page

%%%===================================================================
%%% cowboy handler
%%%===================================================================

init(Req0, health) ->
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, <<"ok\n">>, Req0), health};
init(Req0, Op) ->
    Deadline = read_deadline(),
    Req = try handle(Op, Req0, Deadline)
          catch Class:Reason:Stack ->
                    logger:warning("quod explorer: ~p failed ~p:~p ~p", [Op, Class, Reason, Stack]),
                    json_reply(500, #{error => internal}, Req0)
          end,
    {ok, Req, Op}.

handle(summary, Req, _Deadline) ->
    json_reply(200, summary(), Req);
handle(Op, Req, Deadline) ->
    Qs = maps:from_list(cowboy_req:parse_qs(Req)),
    case history_mode(Qs) of
        {ok, Mode} -> handle_history(Op, Req, Qs, Mode, Deadline);
        {error, bad_mode} -> json_reply(400, #{error => bad_mode}, Req)
    end.

handle_history(txs, Req, Qs, Mode, Deadline) ->
    %% A valueless query key (`?ns`, `?limit`) parses to the atom `true`; treat any non-binary value as
    %% absent so a bare `?ns` is a clean `missing_ns` and a bare `?limit`/`?before` falls to its default
    %% (rather than reaching int_param as `true` and function_clause-crashing to a 500).
    case bin_param(maps:get(<<"ns">>, Qs, undefined)) of
        undefined -> json_reply(400, #{error => missing_ns}, Req);
        Ns ->
            Before = int_param(maps:get(<<"before">>, Qs, undefined), undefined),
            Limit  = min(?MAX_PAGE, int_param(maps:get(<<"limit">>, Qs, undefined), ?DEFAULT_PAGE)),
            Result = with_history_store(
                       Ns, Mode, Deadline, fun(Store) -> txs_page(Store, Before, Limit) end,
                       #{txs => [], height => 0, next_before => null}),
            history_reply(Result, Req, Deadline)
    end;
handle_history(tx, Req, _Qs, Mode, Deadline) ->
    Ns = cowboy_req:binding(ns, Req),
    case transaction_outcome(Ns, cowboy_req:binding(id, Req), Mode, Deadline) of
        {ok, pending, Outcome} ->
            history_json_reply(202, #{outcome => Outcome}, Req, Deadline);
        {ok, terminal, Found} ->
            history_json_reply(200, Found, Req, Deadline);
        {error, bad_tx_id} ->
            json_reply(400, #{error => bad_tx_id}, Req);
        {error, not_found} ->
            json_reply(404, #{error => not_found}, Req);
        {error, Reason} ->
            json_reply(503, #{error => text(Reason)}, Req)
    end;
handle_history(block, Req, _Qs, Mode, Deadline) ->
    Ns = cowboy_req:binding(ns, Req),
    case int_param(cowboy_req:binding(slot, Req), undefined) of
        undefined -> json_reply(400, #{error => bad_slot}, Req);
        Slot ->
            R = with_history_store(Ns, Mode, Deadline, fun(Store) ->
                    case quod_ledger_store:read_at(Store, Slot) of
                        {ok, E}   -> block_json(Store, Ns, E);
                        not_found -> not_found
                    end
                end, not_found),
            case R of
                not_found -> json_reply(404, #{error => not_found}, Req);
                Block     -> history_reply(Block, Req, Deadline)
            end
    end.

history_reply({error, Reason}, Req, _Deadline) ->
    json_reply(503, #{error => text(Reason)}, Req);
history_reply(Result, Req, Deadline) ->
    history_json_reply(200, Result, Req, Deadline).

history_json_reply(Status, Result, Req, Deadline) ->
    Body = encode(Result),
    case Deadline > quod_time:mono_ms() of
        true -> cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Body, Req);
        false -> json_reply(503, #{error => ontology_unreachable}, Req)
    end.

prove_result(
  {ok, Bindings, {transaction, Ns, Anchor, TxId}})
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(TxId), byte_size(TxId) =:= 32 ->
    {200, maps:merge(
            #{result => ok,
              bindings => [bindings_json(B) || B <- Bindings]},
            outcome_ref_json(Ns, Anchor, TxId))};
prove_result(
  {ok, Bindings,
   #{ref := {group, Ns, Anchor, Coordinator, Admission, GroupId} = Ref,
     height := Height, participant_slots := Slots}})
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(Coordinator), byte_size(Coordinator) =:= 32,
       is_binary(Admission), byte_size(Admission) =:= 32,
       is_binary(GroupId), byte_size(GroupId) =:= 32,
       is_integer(Height), Height > 0, is_list(Slots) ->
    case participant_slots_json(Slots, []) of
        {ok, PublicSlots} ->
            {200, maps:merge(
                    #{result => ok, height => Height,
                      bindings => [bindings_json(B) || B <- Bindings],
                      participant_slots => PublicSlots},
                    group_ref_json(Ref))};
        error ->
            {503, #{error => invalid_group_outcome}}
    end;
prove_result({ok, Bindings, Height}) when is_integer(Height), Height >= 0 ->
    {200, #{result => ok, height => Height, bindings => [bindings_json(B) || B <- Bindings]}};
prove_result(fail) ->
    {200, #{result => fail}};
prove_result({fail, Reasons}) when is_list(Reasons) ->
    {200, #{result => fail,
            reasons => [prolog_text(Reason) || Reason <- Reasons]}};
prove_result({error, {not_leader, Hint}}) ->
    Leader = case Hint of none -> null; _ -> id_json(Hint) end,
    {409, #{error => not_leader, leader => Leader}};
prove_result(
  {error, {outcome_unknown,
           {transaction, Ns, Anchor, TxId}}})
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(TxId), byte_size(TxId) =:= 32 ->
    {202, (outcome_ref_json(Ns, Anchor, TxId))#{result => pending}};
prove_result(
  {error, {outcome_unknown,
           {group, Ns, Anchor, Coordinator, Admission, GroupId} = Ref}})
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_binary(Coordinator), byte_size(Coordinator) =:= 32,
       is_binary(Admission), byte_size(Admission) =:= 32,
       is_binary(GroupId), byte_size(GroupId) =:= 32 ->
    {202, (group_ref_json(Ref))#{result => pending}};
%% A malformed declared lifecycle term is a caller error, not a service outage.
prove_result({error, invalid_action}) ->
    {400, #{error => invalid_action}};
prove_result({error, Reason}) ->
    {503, #{error => text(Reason)}}.

outcome_ref_json(Ns, Anchor, TxId) ->
    #{ns => Ns,
      anchor => binary:encode_hex(Anchor, lowercase),
      tx_id => tx_id_text(TxId)}.

group_ref_json(
  {group, Ns, Anchor, Coordinator, Admission, GroupId}) ->
    #{ns => Ns,
      anchor => binary:encode_hex(Anchor, lowercase),
      coordinator => binary:encode_hex(Coordinator, lowercase),
      coordinator_admission => binary:encode_hex(Admission, lowercase),
      group_id => binary:encode_hex(GroupId, lowercase)}.

participant_slots_json([], Acc) ->
    {ok, lists:reverse(Acc)};
participant_slots_json(
  [{{Ns, Anchor}, Slot, Generation} | Rest], Acc)
  when is_binary(Ns), is_binary(Anchor), byte_size(Anchor) =:= 32,
       is_integer(Slot), Slot > 0,
       is_integer(Generation), Generation >= 0 ->
    participant_slots_json(
      Rest,
      [#{ns => Ns, anchor => binary:encode_hex(Anchor, lowercase),
         height => Slot, generation => Generation} | Acc]);
participant_slots_json(_Bad, _Acc) ->
    error.

bindings_json(B) when is_map(B) ->
    maps:fold(fun(V, T, Acc) -> Acc#{atom_to_binary(V, utf8) => prolog_text(T)} end, #{}, B).

%%%===================================================================
%%% summary
%%%===================================================================

-doc "Node identity + per-namespace consensus status. Shared with the WS `hello` frame.".
summary() ->
    Node = case application:get_env(quod, node_pubkey) of
               {ok, P} when is_binary(P) -> id_json(P);
               _ -> null
           end,
    #{node => Node,
      namespaces => [ns_summary(Ns) || Ns <- lists:sort(quod_simplex:namespaces())]}.

ns_summary(Ns) ->
    St = quod_simplex:status(Ns),
    Committee = quod_simplex:committee(Ns),
    Slot = maps:get(slot, St, 0),
    Approved = maps:get(approved, St, Slot),
    FinalitySlot = maps:get(finality_slot, St, Slot + 1),
    ProposalSlot = maps:get(proposal_slot, St, Approved + 1),
    maps:merge(
      #{ns        => Ns,
        height    => maps:get(committed, St, 0),
        applied   => quod_prolog:applied(Ns),
        role      => maps:get(role, St, observer),
        syncing   => maps:get(syncing, St, false),
        committee => [id_json(M) || M <- Committee],
        approved  => Approved,
        finality_slot => FinalitySlot,
        finality_leader => leader_json(FinalitySlot, Committee),
        proposal_slot => ProposalSlot,
        next_proposer => leader_json(ProposalSlot, Committee),
        proposal_open => maps:get(proposal_open, St, false),
        progress_phase => maps:get(progress_phase, St, idle),
        progress_quorum_ready => maps:get(progress_quorum_ready, St, false),
        genesis   => case quod_simplex:genesis_hash(Ns) of
                         H when is_binary(H) -> binary:encode_hex(H, lowercase);
                         _ -> null
                     end},
      committee_status_json(St)).

%% Invalid/missing committee identity is exposed as `null`, so a fleet
%% preflight fails closed instead of benchmarking divergent committee views.
committee_status_json(St) ->
    #{committee_id =>
          case maps:get(committee_id, St, undefined) of
              Id when is_binary(Id), byte_size(Id) =:= 32 ->
                  binary:encode_hex(Id, lowercase);
              _ ->
                  null
          end}.

leader_json(Slot, Committee) when is_integer(Slot), Slot >= 1 ->
    case quod_simplex:leader(Slot, Committee) of
        L when is_binary(L); is_tuple(L) -> id_json(L);
        _ -> null
    end;
leader_json(_Slot, _Committee) ->
    null.

%%%===================================================================
%%% history — read-only ledger views (quod_catchup's pattern)
%%%===================================================================

%% Both selectors belong to the existing history endpoints. Missing mode is
%% live; stopped-ledger inspection is never selected by a failed owner call.
history_mode(Qs) ->
    case maps:get(<<"mode">>, Qs, <<"live">>) of
        <<"live">> -> {ok, live};
        <<"offline">> -> {ok, offline};
        _ -> {error, bad_mode}
    end.

read_deadline() ->
    Started = quod_time:mono_ms(),
    Budget = case application:get_env(quod, explorer_read_budget_ms) of
                 {ok, Milliseconds} -> Milliseconds;
                 undefined ->
                     %% Configuration-free embedding uses the same schema default.
                     #{default := Milliseconds} =
                         proplists:get_value(read_budget_ms, quod_schema:fields(explorer)),
                     Milliseconds
             end,
    true = is_integer(Budget) andalso Budget > 0,
    Started + Budget.

with_history_store(Ns, live, Deadline, Fun, _Empty) ->
    case quod_simplex:history_view(Ns, committed, Deadline) of
        {ok, #{snapshot := Snapshot} = View} ->
            case quod_ledger_store:open_ro_snapshot(Snapshot) of
                {ok, Store} ->
                    try
                        case history_read_live(View, Deadline) of
                            true ->
                                Result = Fun(Store),
                                case history_read_live(View, Deadline) of
                                    true -> Result;
                                    false -> {error, ontology_unreachable}
                                end;
                            false -> {error, ontology_unreachable}
                        end
                    after quod_ledger_store:close(Store)
                    end;
                {error, _} -> {error, ontology_unreachable}
            end;
        {error, _} -> {error, ontology_unreachable}
    end;
with_history_store(Ns, offline, Deadline, Fun, Empty) ->
    case Deadline > quod_time:mono_ms() of
        true ->
            Result = with_offline_store(Ns, Fun, Empty),
            case Deadline > quod_time:mono_ms() of
                true -> Result;
                false -> {error, ontology_unreachable}
            end;
        false -> {error, ontology_unreachable}
    end.

history_read_live(View, Deadline) ->
    Deadline > quod_time:mono_ms() andalso quod_simplex:history_view_live(View).

%% This is the sole explicitly selected stopped-ledger index reconstruction.
%% Refuse a running/restarted owner, including one appearing during the read.
with_offline_store(Ns, Fun, Empty) ->
    case quod_reg:where({quod_simplex, Ns}) of
        undefined ->
            case quod_ledger_store:open_ro(Ns, content_ledger_dir(Ns)) of
                {ok, Store} ->
                    try
                        Result = Fun(Store),
                        case quod_reg:where({quod_simplex, Ns}) of
                            undefined -> Result;
                            _ -> {error, ontology_unreachable}
                        end
                    after quod_ledger_store:close(Store)
                    end;
                {error, _} -> Empty
            end;
        _ -> {error, ontology_unreachable}
    end.

content_storage(Ns) ->
    Default = quod_ledger_store:default_data_dir(),
    Storage = application:get_env(quod, content_storage_dirs, #{}),
    maps:get(Ns, Storage, #{data => Default, ledger => Default}).

content_ledger_dir(Ns) -> maps:get(ledger, content_storage(Ns)).

txs_page(Store, Before, Limit) ->
    Last = quod_ledger_store:last(Store),
    From = case Before of undefined -> Last; B -> min(B - 1, Last) end,
    {TxsRev, NextBefore} = collect_txs(Store, From, Limit, ?SCAN_SLOTS, []),
    #{txs => lists:reverse(TxsRev), height => Last,
      next_before => NextBefore}.

%% Walk slots downward until `Need` transaction rows are collected or the scan budget is
%% spent; newest first. `NextBefore` is the `before` for the next page (`null` = at genesis).
collect_txs(_Store, Slot, _Need, _Scan, Acc) when Slot < 1 ->
    {Acc, null};
collect_txs(_Store, Slot, Need, Scan, Acc) when Need =< 0; Scan =< 0 ->
    {Acc, Slot + 1};
collect_txs(Store, Slot, Need, Scan, Acc) ->
    case quod_ledger_store:read_at(Store, Slot) of
        {ok, E} ->
            Ns = quod_ledger_store:namespace(Store),
            Rows = entry_rows(Store, Ns, E),
            collect_txs(
              Store, Slot - 1, Need - length(Rows), Scan - 1,
              lists:reverse(Rows, Acc));
        not_found ->
            collect_txs(Store, Slot - 1, Need, Scan - 1, Acc)
    end.

%% The outcome index gives the exact terminal height in O(1). The detail view
%% then reads that one block for its certificate and signed transaction fields;
%% it never scans history or re-proves the goal.
transaction_outcome(Ns, IdText, Mode, Deadline) ->
    case parse_tx_id(IdText) of
        {ok, TxId} ->
            Owner = quod_reg:where({quod_simplex, Ns}),
            case outcome_owner_live(Ns, Mode, Owner, Deadline) of
                false -> {error, ontology_unreachable};
                true ->
                    Result = quod_outcome:lookup_live(Ns, content_ledger_dir(Ns), TxId),
                    case outcome_owner_live(Ns, Mode, Owner, Deadline) of
                        true -> transaction_detail(Ns, TxId, Result, Mode, Owner, Deadline);
                        false -> {error, ontology_unreachable}
                    end
            end;
        {error, bad_tx_id} ->
            {error, bad_tx_id}
    end.

outcome_owner_live(Ns, Mode, Owner, Deadline) ->
    Deadline > quod_time:mono_ms() andalso
    quod_reg:where({quod_simplex, Ns}) =:= Owner andalso
    case Mode of
        live -> is_pid(Owner) andalso is_process_alive(Owner);
        offline -> Owner =:= undefined
    end.

transaction_detail(Ns, TxId, {ok, #{status := pending,
                                  ref := {transaction, Ns, Anchor, TxId}} = Outcome},
                   live, Owner, Deadline) ->
    case quod_simplex:history_view({Owner, {Ns, Anchor}}, committed, Deadline) of
        {ok, _View} -> {ok, pending, outcome_json(Outcome)};
        {error, _} -> {error, ontology_unreachable}
    end;
transaction_detail(_Ns, _TxId, {ok, #{status := pending} = Outcome}, offline, _Owner, _Deadline) ->
    {ok, pending, outcome_json(Outcome)};
transaction_detail(Ns, TxId, {ok, #{height := Height,
                                   ref := {transaction, Ns, Anchor, TxId}} = Outcome},
                   Mode, Owner, Deadline) ->
    %% Read the outcome first: an append may publish a newer terminal index row
    %% while an earlier snapshot is being captured. Pin the original owner and
    %% outcome anchor, then borrow a prefix that can contain that terminal slot.
    Source = case Mode of live -> {Owner, {Ns, Anchor}}; offline -> Ns end,
    with_history_store(Source, Mode, Deadline,
      fun(Store) -> terminal_transaction(Ns, TxId, Height, Outcome, Store) end,
      {error, ontology_unreachable});
transaction_detail(_Ns, _TxId, {error, _} = Error, _Mode, _Owner, _Deadline) ->
    Error.

terminal_transaction(Ns, TxId, Height, Outcome, Store) ->
    case quod_ledger_store:read_at(Store, Height) of
        {ok, E} ->
            case [T || T <- entry_txs(E), T#transaction.tx_id =:= TxId] of
                [T] ->
                    case durable_submission_json(T) of
                        {ok, GoalJson, ResultJson} ->
                            {ok, terminal,
                             #{tx => tx_json_full_decoded(Ns, T, E, GoalJson, ResultJson),
                               block => block_meta(E),
                               outcome => terminal_outcome_json(Outcome, GoalJson, ResultJson)}};
                        {error, _} = Error -> Error
                    end;
                _ -> {error, outcome_index_mismatch}
            end;
        not_found -> {error, outcome_index_mismatch}
    end.

parse_tx_id(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    try binary:decode_hex(Id) of
        <<_:256>> = TxId -> {ok, TxId};
        _ -> {error, bad_tx_id}
    catch
        error:badarg -> {error, bad_tx_id}
    end;
parse_tx_id(_Id) ->
    {error, bad_tx_id}.

outcome_json(#{status := Status,
               ref := {transaction, Ns, Anchor, TxId}} = Outcome) ->
    maps:merge(
      (outcome_ref_json(Ns, Anchor, TxId))#{status => Status},
      maps:with([height, reason], Outcome)).

durable_submission_json(
  #transaction{role = {remote_complete, _, _, _}}) ->
    {ok, null, null};
durable_submission_json(
  #transaction{goal = GoalBlob, result = ResultBlob}) ->
    case {quod_durable_term:decode_goal(GoalBlob),
          quod_durable_term:decode_result(ResultBlob)} of
        {{ok, Goal}, {ok, Bindings}} ->
            {ok, goal_text(Goal), result_json(Bindings)};
        _ -> {error, outcome_index_mismatch}
    end.

terminal_outcome_json(Outcome, GoalJson, ResultJson) ->
    (outcome_json(Outcome))#{goal => GoalJson, bindings => ResultJson}.

entry_txs(Entry) ->
    #entry{data = Data} = quod_ledger:entry_view(Entry),
    case quod_ledger:classify(Data) of
        {content, Txs} -> Txs;
        {controls, _Controls} -> [];
        noop -> [];
        invalid -> []
    end.

%% A ledger slot has either ordinary committed transactions or one canonical
%% same-phase DTX-control batch. Keeping this projection beside block_json/2
%% makes paged history and the live WebSocket describe the same committed
%% ledger; every control gets its own row while sharing the committed slot.
entry_rows(Ns, E) ->
    entry_rows(none, Ns, E).

entry_rows(Store, Ns, E) ->
    #entry{data = Data} = quod_ledger:entry_view(E),
    case quod_ledger:classify(Data) of
        {content, Txs} -> [tx_json(Ns, T, E) || T <- Txs];
        {controls, Controls} ->
            [control_row(Store, Ns, Phase, Control, E)
             || {Phase, Control} <- Controls];
        noop -> [];
        invalid -> []
    end.

%%%===================================================================
%%% JSON builders (shared with quod_explorer_ws)
%%%===================================================================

-doc "The list-row rendering of one transaction inside its committed entry.".
tx_json(Ns, #transaction{tx_id = Id,
                     role = Role,
                     goal = G, author = A,
                     author_seq = AuthorSeq, submitted_at = Sub,
                     diff = Diff, effects = Effects},
        Entry) ->
    #entry{index = Slot, timestamp = Ts} = quod_ledger:entry_view(Entry),
    (tx_json_decoded(
      Ns, Id, durable_goal_text(G), A, AuthorSeq, Sub,
      Diff, Effects, Slot, Ts))#{role => role_name(Role),
                                 role_details => role_details(Role)}.

tx_json_decoded(Ns, Id, GoalJson, Author, AuthorSeq, SubmittedAt,
                Diff, Effects, Slot, Timestamp) ->
    TxId = tx_id_text(Id),
    #{row_type => transaction, row_id => TxId,
      tx_id => TxId, ns => Ns, height => Slot, time => Timestamp,
      goal => GoalJson, author => id_json(Author), author_seq => AuthorSeq,
      submitted_at => SubmittedAt,
      ops => length(Diff), fact_ops => fact_op_count(Diff),
      effect_count => length(Effects),
      effect_operations => [effect_operation(Effect) || Effect <- Effects]}.

-doc "The detail rendering: the row plus result bindings, authentication, the diff, and OCC extent.".
tx_json_full(Ns, #transaction{result = Res} = T, E) ->
    tx_json_full_decoded(
      Ns, T, E, durable_goal_text(T#transaction.goal),
      durable_result_json(Res)).

tx_json_full_decoded(
  Ns,
  #transaction{tx_id = Id, origin = Origin, proof_id = ProofId,
               plan_digest = PlanDigest, author = Author, author_seq = AuthorSeq,
               submitted_at = SubmittedAt, diff = Diff,
               read_check = RC, effects = Effects, sig = Sig,
               request_auth = RequestAuth} = T,
  E,
  GoalJson, ResultJson) ->
    #entry{index = Slot, timestamp = Timestamp} = quod_ledger:entry_view(E),
    (tx_json_decoded(
       Ns, Id, GoalJson, Author, AuthorSeq, SubmittedAt,
       Diff, Effects, Slot, Timestamp))#{
                     role => role_name(T#transaction.role),
                     role_details => role_details(T#transaction.role),
                     evidence_ref => evidence_ref_json(
                                       quod_transaction:evidence(T)),
                     result => ResultJson,
                     diff => [op_json(Op) || Op <- Diff],
                     root_facts_changed => fact_op_count(Diff) > 0,
                     effects => [effect_json(Effect) || Effect <- Effects],
                     read_predicates => map_size(RC),
                     origin => origin_json(Origin),
                     proof_id => digest_json(ProofId),
                     plan_digest => digest_json(PlanDigest),
                     request => request_json(
                                  RequestAuth,
                                  quod_transaction:request_claim(T),
                                  transaction_ref(Origin, Id)),
                     signature => signature_json(Sig),
                     signature_status => signature_status(T, E)}.

role_name(application) -> application;
role_name({remote_claim, _, _, _}) -> remote_claim;
role_name({remote_application, _, _, _}) -> remote_application;
role_name({remote_complete, _, _, _}) -> remote_complete.

role_details(application) -> null;
role_details(
  {remote_claim, _Manifest, Bundles, Refs}) ->
    #{targets => [#{target => origin_json(Target), plan_digest => digest_json(Digest)}
                  || {Target, Digest, _Blob, _Attestation} <- Bundles],
      target_transactions => [anchored_outcome_ref_json(R) || R <- Refs]};
role_details(
  {remote_application, ClaimRef, OperationRef, RequestDigest}) ->
    #{source_claim => anchored_outcome_ref_json(ClaimRef),
      operation_ref => operation_ref_json(OperationRef),
      request_digest => digest_json(RequestDigest)};
role_details(
  {remote_complete, OperationRef, RequestDigest, Receipt}) ->
    #{operation_ref => operation_ref_json(OperationRef),
      request_digest => digest_json(RequestDigest),
      targets => [operation_receipt_row_json(Row) || Row <- Receipt]}.

operation_receipt_row_json({Target, {included, Ref}}) ->
    #{target => origin_json(Target), kind => included,
      application_ref => anchored_outcome_ref_json(Ref)};
operation_receipt_row_json({Target, {certified, Ref, Certificate}}) ->
    {ok, #{result := Result, slot := Slot, committee_id := Committee}} =
        quod_applied_certificate:operation_certificate_binding(Certificate),
    #{target => origin_json(Target), kind => certified,
      application_ref => anchored_outcome_ref_json(Ref),
      result => case Result of applied -> applied; {rejected, _} -> rejected end,
      reason => case Result of applied -> null; {rejected, Reason} -> Reason end,
      height => Slot, committee_id => digest_json(Committee)}.

evidence_ref_json(none) -> null;
evidence_ref_json({applications, Pairs}) ->
    [evidence_ref_json(Pair) || Pair <- Pairs];
evidence_ref_json({CertifiedRef, _Transaction}) ->
    case quod_dtx:certified_ref_binding(CertifiedRef) of
        {ok, {Ns, Anchor}, Slot, TxId} ->
            (anchored_outcome_ref_json(
               {transaction, Ns, Anchor, TxId}))#{height => Slot};
        error -> null
    end.

transaction_ref({Ns, <<_:256>> = Anchor}, <<_:256>> = TxId)
  when is_binary(Ns) ->
    {transaction, Ns, Anchor, TxId};
transaction_ref(_Origin, _TxId) ->
    none.

effect_json(Effect) ->
    case quod_effect:validate(Effect) of
        true ->
            EffectId = quod_effect:effect_id(Effect),
            Base =
                #{effect_id => digest_json(EffectId),
                  operation => quod_effect:operation(Effect),
                  executor => id_json(quod_effect:executor(Effect)),
                  actor => actor_json(quod_effect:actor(Effect)),
                  actor_authority => actor_authority(quod_effect:actor(Effect)),
                  target => origin_json(quod_effect:target(Effect)),
                  request_digest =>
                      digest_json(quod_effect:request_digest(Effect)),
                  prepared_digest =>
                      digest_json(quod_effect:prepared_digest(Effect))},
            maps:merge(
              Base,
              local_effect_status(EffectId,
                                  quod_effect:executor(Effect)));
        false ->
            invalid_effect_json()
    end.

effect_operation(Effect) ->
    case quod_effect:validate(Effect) of
        true -> quod_effect:operation(Effect);
        false -> invalid
    end.

invalid_effect_json() ->
    InvalidPeer = #{id => <<"invalid">>, pubkey => null},
    #{effect_id => <<"invalid">>, operation => invalid,
      executor => InvalidPeer,
      actor => #{kind => node, identity => InvalidPeer},
      actor_authority => author_node_claimed,
      target => #{ns => <<"invalid">>, anchor => <<"invalid">>},
      request_digest => <<"invalid">>, prepared_digest => <<"invalid">>,
      local_execution => unavailable,
      local_execution_result => <<"invalid descriptor">>}.

actor_json({node, Key}) -> #{kind => node, identity => id_json(Key)};
actor_json({agent, Blob}) ->
    case quod_agent_ref:decode(Blob) of
        {ok, #{identity := Identity, reference := Reference}} ->
            #{kind => agent, identity => origin_json(Identity),
              reference => prolog_text(Reference),
              reference_wire => base64:encode(Blob, #{mode => urlsafe,
                                                       padding => false})};
        {error, _} -> #{kind => agent, identity => null,
                        reference => <<"invalid">>, reference_wire => null}
    end.

actor_authority({agent, _}) -> signed_agent_request;
actor_authority({node, _}) -> author_node_claimed.

local_effect_status(EffectId, Executor) ->
    case application:get_env(quod, node_pubkey) of
        {ok, Executor} ->
            case quod_effect_journal:status(EffectId) of
                {ok, #{state := State} = Status} ->
                    #{local_execution => local_effect_state(State),
                      local_custody_state => State,
                      local_execution_height => maps:get(height, Status, 0),
                      local_execution_result =>
                          local_effect_result(maps:get(result, Status, none))};
                _ -> #{local_execution => unavailable}
            end;
        _ -> #{local_execution => not_this_node}
    end.

local_effect_state(transaction_bound) -> pending;
local_effect_state(transaction_ready) -> pending;
local_effect_state(transaction_submitted) -> pending;
local_effect_state(operation_pending) -> pending;
local_effect_state(group_pending) -> pending;
local_effect_state(released) -> pending;
local_effect_state(State) -> State.

local_effect_result(none) -> null;
local_effect_result(ok) -> ok;
local_effect_result(Result) -> prolog_text(Result).

signature_json(Sig) when is_binary(Sig) -> binary:encode_hex(Sig, lowercase);
signature_json(none) -> null.

signature_status(#transaction{sig = none}, Entry) ->
    case quod_ledger:entry_view(Entry) of
        #entry{index = 1} -> genesis;
        _ -> unsigned
    end;
signature_status(#transaction{sig = Sig}, _Entry)
  when is_binary(Sig), byte_size(Sig) =:= 64 ->
    verified;
signature_status(_Transaction, _Entry) ->
    invalid.

block_json(Ns, E) ->
    %% The live stream has no store handle.  Open the same read-only ledger
    %% view used by history so a just-committed Finalize can show the exact
    %% referenced Prepare plan too. The event has one read deadline; an
    %% unavailable owner leaves only that optional display field absent, never
    %% reopens a path or postpones the event for a timed retry.
    Deadline = read_deadline(),
    case with_history_store(Ns, live, Deadline,
           fun(Store) -> block_json(Store, Ns, E) end, unavailable) of
        {error, ontology_unreachable} -> block_json(none, Ns, E);
        Block -> Block
    end.

block_json(Store, Ns, E) ->
    #entry{data = Data} = quod_ledger:entry_view(E),
    case quod_ledger:classify(Data) of
        {content, Txs} ->
            (block_meta(content, E))#{
              txs => [tx_json_full(Ns, T, E) || T <- Txs]};
        {controls, Controls} -> dtx_block_meta(Store, Controls, E);
        noop -> (block_meta(noop, E))#{txs => []};
        invalid -> (block_meta(invalid, E))#{txs => []}
    end.

dtx_block_meta(Store, Controls, E) ->
    (block_meta(dtx_batch, E))#{
      txs => [],
      controls => [control_json(Store, Control)
                   || {_Phase, Control} <- Controls]}.

control_row(Store, Ns, Phase, Control, Entry) ->
    #entry{index = Slot, timestamp = Timestamp} = quod_ledger:entry_view(Entry),
    ControlJson = control_json(Store, Control),
    Digest = maps:get(record_digest, ControlJson),
    #{row_type => control,
      row_id => <<"dtx:", Digest/binary>>,
      ns => Ns,
      height => Slot,
      time => Timestamp,
      phase => Phase,
      control => ControlJson}.

%% The explorer exposes stable, already-validated control metadata and the
%% prepared facts/events from each decoded participant plan.  It deliberately
%% omits the raw plan bytes, certificates embedded in references, and
%% signing-journal bytes: those remain ledger implementation details, not a
%% second API or an alternate source of truth.
control_json(Store, Control) ->
    #{kind := Kind, target := Target, author := Author,
      author_admission := Admission, sequence := Sequence,
      submitted_at := SubmittedAt} = quod_dtx:control_metadata(Control),
    maps:merge(
      #{kind => Kind,
        group_id => digest_json(quod_dtx:group_id(Control)),
        record_digest => digest_json(quod_dtx:record_digest(Control)),
        target => origin_json(Target),
        author => id_json(Author),
        author_admission => digest_json(Admission),
        sequence => Sequence,
        submitted_at => SubmittedAt},
      control_body_json(Kind, quod_dtx:control_body(Control), Target, Store)).

control_body_json(
  'begin',
  {quod_dtx_begin, _, Manifest, _RequestAuth, Bundles} = Begin,
  _Target, _Store) ->
    OutcomeRef = case quod_dtx:begin_group_ref(Begin) of
                     {ok, Ref} -> Ref;
                     error -> none
                 end,
    #{participant_count => length(Bundles),
      participants => [participant_plan_json(Manifest, Bundle)
                       || Bundle <- Bundles],
      request => request_json(
                   quod_dtx:request_auth(Begin),
                   quod_dtx:request_claim(Begin), OutcomeRef)};
control_body_json(
  prepare,
  {quod_dtx_prepare, _, _, _BeginRef, Manifest, PlanDigest, PlanBlob},
  Target, _Store) ->
    Plan = participant_plan_json(
             Manifest, {Target, PlanDigest, PlanBlob, none}),
    #{plan_digest => digest_json(PlanDigest), plan => Plan};
control_body_json(
  decision,
  {quod_dtx_decision, _, _, _BeginRef, Verdict, PrepareRefs, _} = Record,
  _Target, _Store) ->
    #{verdict => Verdict,
      prepare_count => length(PrepareRefs),
      reasons => decision_reasons_json(Record)};
control_body_json(finalize,
                  {quod_dtx_finalize, _, _, _DecisionRef, Verdict, PrepareRef,
                   AppliedGeneration}, Target, Store) ->
    Base = #{verdict => Verdict, prepared => PrepareRef =/= none,
             applied_generation => AppliedGeneration},
    case {Verdict, finalized_prepare_plan(Store, Target, PrepareRef)} of
        {commit, {ok, Plan}} -> Base#{applied_plan => Plan};
        _ -> Base
    end;
control_body_json(complete,
                  {quod_dtx_complete, _, _, _DecisionRef, FinalizeRows},
                  _Target, _Store) ->
    #{finalize_count => length(FinalizeRows)}.

%% A Finalize deliberately stores only a certified reference to its Prepare;
%% the referenced plan remains the one ledger record that owns the exact diff.
%% Explorer follows that reference in the current read-only ledger view and
%% verifies target, slot, phase, and record digest before rendering it.
finalized_prepare_plan(none, _Target, _PrepareRef) ->
    error;
finalized_prepare_plan(_Store, _Target, none) ->
    error;
finalized_prepare_plan(Store, Target, PrepareRef) ->
    case quod_dtx:certified_ref_binding(PrepareRef) of
        {ok, Target, Slot, Digest} ->
            case quod_ledger_store:read_at(Store, Slot) of
                {ok, Entry} ->
                    #entry{data = Data} = quod_ledger:entry_view(Entry),
                    case quod_ledger:classify(Data) of
                        {controls, Controls} ->
                            case [PrepareControl
                                  || {prepare, PrepareControl} <- Controls,
                                     quod_dtx:record_digest(PrepareControl) =:=
                                         Digest] of
                                [PrepareControl] ->
                                    prepare_plan_json(PrepareControl, Target);
                                _ -> error
                            end;
                        _ -> error
                    end;
                not_found -> error
            end;
        _ ->
            error
    end.

prepare_plan_json(PrepareControl, Target) ->
    case quod_dtx:control_body(PrepareControl) of
        {quod_dtx_prepare, _, _, _BeginRef, Manifest, PlanDigest, PlanBlob} ->
            {ok, participant_plan_json(
                   Manifest, {Target, PlanDigest, PlanBlob, none})};
        _ ->
            error
    end.

participant_plan_json(
  Manifest, {Target, PlanDigest, PlanBlob, Attestation}) ->
    Base = #{target => origin_json(Target),
             plan_digest => digest_json(PlanDigest)},
    case quod_dtx:decode(PlanBlob) of
        {ok, Plan} ->
            BindingValid =
                quod_dtx:target(Plan) =:= Target andalso
                quod_dtx:digest(Plan) =:= PlanDigest andalso
                (Attestation =:= none orelse
                 quod_dtx:verify_plan_attestation(
                   Target, Plan, Manifest, Attestation)),
            case BindingValid of
                true ->
                    Effects = quod_dtx:effects(Plan),
                    Diff = quod_dtx:diff(Plan),
                    Base#{status => bound,
                          signer => id_json(quod_dtx:signer(Plan)),
                          diff_ops => quod_dtx:diff_ops(Plan),
                          diff => [op_json(Op) || Op <- Diff],
                          effect_count => quod_dtx:effects_count(Plan),
                          effects => [effect_json(Effect)
                                      || Effect <- Effects]};
                false -> invalid_participant_plan_json(Base)
            end;
        {error, _} ->
            invalid_participant_plan_json(Base)
    end;
participant_plan_json(_Manifest, _Malformed) ->
    invalid_participant_plan_json(
      #{target => null, plan_digest => <<"invalid">>}).

invalid_participant_plan_json(Base) ->
    Base#{status => invalid, signer => null,
          diff_ops => null, diff => null,
          effect_count => null, effects => []}.

request_json(none, none, _OutcomeRef) ->
    null;
request_json(
  {agent_goal_v1, <<_:256>> = Digest, RequestBytes,
   <<_:512>> = AgentSignature},
  {ok, #{key := {AgentRef, OperationId}, digest := Digest,
         target := {TargetNs, <<_:256>> = TargetAnchor},
         deadline := Deadline, principal := {agent, AgentRef},
         operation_ref := OperationRef}},
  OutcomeRef)
  when is_binary(RequestBytes), is_binary(TargetNs) ->
    case quod_client_goal:verify(RequestBytes, AgentSignature) of
        {ok, #{request := #{mode := Mode, parser_version := ParserVersion}}} ->
            #{status => verified,
              request_digest => digest_json(Digest),
              agent => actor_json({agent, AgentRef}),
              operation_id => digest_json(OperationId),
              operation_ref => operation_ref_json(OperationRef),
              target => origin_json({TargetNs, TargetAnchor}),
              mode => Mode,
              parser_version => ParserVersion,
              not_after_ms => Deadline,
              signature => signature_json(AgentSignature),
              first_outcome => anchored_outcome_ref_json(OutcomeRef)};
        {error, _} ->
            invalid_request_json()
    end;
request_json(_RequestAuth, _Claim, _OutcomeRef) ->
    invalid_request_json().

invalid_request_json() ->
    #{status => invalid, request_digest => null, agent => null,
      operation_id => null, operation_ref => null, target => null,
      mode => null, parser_version => null, not_after_ms => null,
      signature => null, first_outcome => null}.

operation_ref_json(
  {operation, Ns, <<_:256>> = Anchor, AgentRef,
   <<_:256>> = OperationId})
  when is_binary(Ns), is_binary(AgentRef) ->
    #{kind => operation, ns => Ns, anchor => digest_json(Anchor),
      agent => actor_json({agent, AgentRef}),
      operation_id => digest_json(OperationId)};
operation_ref_json(_) ->
    null.

anchored_outcome_ref_json({applications, Refs}) ->
    #{kind => applications, targets => [anchored_outcome_ref_json(R) || R <- Refs]};
anchored_outcome_ref_json(
  {transaction, Ns, <<_:256>> = Anchor, <<_:256>> = TxId})
  when is_binary(Ns) ->
    #{kind => transaction, ns => Ns, anchor => digest_json(Anchor),
      tx_id => tx_id_text(TxId)};
anchored_outcome_ref_json(
  {group, Ns, <<_:256>> = Anchor, <<_:256>> = Coordinator,
   <<_:256>> = Admission, <<_:256>> = GroupId})
  when is_binary(Ns) ->
    #{kind => group, ns => Ns, anchor => digest_json(Anchor),
      coordinator => id_json(Coordinator),
      coordinator_admission => digest_json(Admission),
      group_id => digest_json(GroupId)};
anchored_outcome_ref_json(_) ->
    null.

decision_reasons_json(Record) ->
    case quod_dtx:decision_failure_reasons(Record) of
        none -> null;
        {ok, Reasons} -> [prolog_text(Reason) || Reason <- Reasons]
    end.

block_meta(E) ->
    block_meta(entry_kind(E), E).

block_meta(Kind, Entry) ->
    #entry{index = Slot, timestamp = Ts, cert = Cert} = quod_ledger:entry_view(Entry),
    #{slot => Slot, time => Ts, kind => Kind, cert => cert_json(Cert)}.

entry_kind(Entry) ->
    #entry{data = Data} = quod_ledger:entry_view(Entry),
    case quod_ledger:classify(Data) of
        {content, _Txs} -> content;
        {controls, _Controls} -> dtx_batch;
        noop -> noop;
        invalid -> invalid
    end.

cert_json(none) -> null;
cert_json(#cert{kind = K, sigs = Sigs}) ->
    #{kind => K, signers => [id_json(P) || {P, _Sig} <- Sigs]};
cert_json(#implicit_cert{child = Child, commit = Commit}) ->
    %% committed implicitly by its child (depth-1 pipelining) — show the child's commit quorum
    #{kind => implicit, child_slot => Child#block.slot,
      signers => [id_json(P) || {P, _Sig} <- Commit#cert.sigs]}.

%% Durable goal/result blobs decode through the same atom-safe canonical
%% persistence codec on every node; only the unsigned genesis has none.
durable_result_json(undefined) -> null;
durable_result_json(Blob) when is_binary(Blob) ->
    case quod_durable_term:decode_result(Blob) of
        {ok, Durable} -> result_json(Durable);
        {error, _} -> invalid
    end.

result_json(Durable) ->
    maps:from_list(
      [{Name, prolog_text(Value)}
       || {Name, Value} <- Durable]).

op_json({assert, Clause})  -> #{op => assert,  clause => clause_text(Clause)};
op_json({retract, Clause}) -> #{op => retract, clause => clause_text(Clause)};
op_json({event, Term})     -> #{op => event, term => prolog_text(Term)}.

fact_op_count(Diff) ->
    length([ok || {Kind, {_Head, _Body}} <- Diff,
                  Kind =:= assert orelse Kind =:= retract]).

%% A stored clause body is erlog's COMPILED `{Goals, HasCut}` form (`well_form_body`): a plain
%% fact compiles to `{[], _}` and renders as its head alone; a rule's goal list renders as the
%% familiar comma body.
clause_text({Head, true}) -> prolog_text(Head);
clause_text({Head, {[], _HasCut}}) -> prolog_text(Head);
clause_text({Head, {Goals, _HasCut}}) when is_list(Goals) ->
    unicode:characters_to_binary(
      [prolog_text(Head), " :- ", lists:join(", ", [prolog_text(G) || G <- Goals])]);
clause_text({Head, Body}) -> <<(prolog_text(Head))/binary, " :- ", (prolog_text(Body))/binary>>.

goal_text(undefined) -> null;
goal_text(G)         -> prolog_text(G).

durable_goal_text(undefined) -> null;
durable_goal_text(Blob) when is_binary(Blob) ->
    case quod_durable_term:decode_goal(Blob) of
        {ok, Goal} -> goal_text(Goal);
        {error, _} -> invalid
    end.

%% Canonical semantic ids are always 32 bytes and always render as the exact
%% 64-hex form accepted by `/api/tx`. The genesis id is a separate readable
%% non-outcome identifier.
tx_id_text(<<_:256>> = Id) ->
    binary:encode_hex(Id, lowercase);
tx_id_text({group, <<_:256>> = GroupId}) ->
    <<"group:", (binary:encode_hex(GroupId, lowercase))/binary>>;
tx_id_text(Id) when is_binary(Id) ->
    case printable(Id) of
        true  -> Id;
        false -> binary:encode_hex(Id, lowercase)
    end.

digest_json(<<_:256>> = Digest) -> binary:encode_hex(Digest, lowercase);
digest_json(_) -> null.

origin_json({Ns, <<_:256>> = Anchor}) when is_binary(Ns) ->
    #{ns => Ns, anchor => digest_json(Anchor)};
origin_json(_) -> null.

id_json(Pk) when is_binary(Pk) ->
    #{id => quod_identity:short(Pk), pubkey => binary:encode_hex(Pk, lowercase)};
id_json({Pk, _Host, _Port}) when is_binary(Pk) ->
    id_json(Pk);
id_json({Host, Port}) ->      %% configuration-free test node id
    #{id => iolist_to_binary([text(Host), ":", integer_to_binary(Port)]), pubkey => null};
id_json(undefined) ->
    null.

-doc """
Render an erlog term as *display* Prolog text. `erlog_io:writeq1/1` on its own prints strings and
binaries as byte lists (`"10.0.0.1"` → `[49,48,…]`), unreadable in a UI. erlog has no callback for
per-leaf rendering and no string type, so `pt/2` reproduces `erlog_io:write_term1/3`'s operator
precedence/paren layout (reusing `m:erlog_parse`'s op tables) around leaf kinds erlog can't show:
printable charlists as escaped `"strings"`, 32-byte binaries as their `kp_…` short id (the house
convention — content 32-byte binaries are Ed25519 pubkeys, e.g. `peer_admitted` args), and other
binaries as escaped `<<"text">>` / truncated `<<0xhex…>>`. Display-only — never parsed back, never
mints atoms.
""".
prolog_text(T) ->
    unicode:characters_to_binary(pt(T, 1200)).

pt(A, _) when is_atom(A) -> erlog_io:writeq1(A);
pt(N, _) when is_number(N) -> io_lib:write(N);
pt(B, _) when is_binary(B), byte_size(B) =:= 32 ->
    binary_to_list(quod_identity:short(B));            %% an Ed25519 pubkey, by convention
pt(B, _) when is_binary(B) ->
    case printable(B) of
        true  -> [<<"<<\"">>, [escape(C) || C <- unicode:characters_to_list(B)], <<"\">>">>];
        false -> [<<"<<0x">>, binary:encode_hex(binary:part(B, 0, min(16, byte_size(B))), lowercase),
                  case byte_size(B) > 16 of true -> <<"…>>">>; false -> <<">>">> end]
    end;
pt({'$quod_symbol', Name} = Symbol, _) when is_binary(Name) ->
    %% Signed goals deliberately keep data-position symbols opaque so merely
    %% mentioning a value cannot allocate a VM atom.  That internal marker is
    %% not part of the user's result: render the original Prolog symbol text.
    case unicode:characters_to_list(Name, utf8) of
        Characters when is_list(Characters) -> opaque_symbol(Characters);
        _ -> io_lib:write(Symbol)
    end;
pt({V}, _) when is_integer(V) -> [$_ | integer_to_list(V)];   %% erlog variable
pt({V}, _) when is_atom(V) -> atom_to_list(V);
pt([], _) -> "[]";
pt(L, _) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true  -> [$", [escape(C) || C <- L], $"];      %% a Prolog string IS a charlist
        false -> [$[, lists:join(", ", [pt(E, 999) || E <- proper(L)]), $]]
    end;
pt({F, A}, Prec) when is_atom(F) ->
    case erlog_parse:prefix_op(F) of
        {yes, OpP, ArgP} -> parens([erlog_io:writeq1(F), $\s, pt(A, ArgP)], OpP, Prec);
        no -> [erlog_io:writeq1(F), $(, pt(A, 999), $)]
    end;
pt({',', A, B}, Prec) ->
    parens([pt(A, 999), ", ", pt(B, 1000)], 1000, Prec);
pt({F, A, B}, Prec) when is_atom(F) ->
    case erlog_parse:infix_op(F) of
        {yes, Lp, OpP, Rp} -> parens([pt(A, Lp), op_pad(F), pt(B, Rp)], OpP, Prec);
        no -> [erlog_io:writeq1(F), $(, pt(A, 999), $,, $\s, pt(B, 999), $)]
    end;
pt(T, _) when is_tuple(T), tuple_size(T) > 1, is_atom(element(1, T)) ->
    [F | Args] = tuple_to_list(T),
    [erlog_io:writeq1(F), $(, lists:join(", ", [pt(A, 999) || A <- Args]), $)];
pt(T, _) ->
    io_lib:write(T).

%% `:`/`::` names read as one token (`quod:animal`); every other operator breathes.
op_pad(F) when F =:= ':'; F =:= '::' -> atom_to_list(F);
op_pad(F) -> [$\s, atom_to_list(F), $\s].

parens(Out, OpP, Prec) when OpP > Prec -> [$(, Out, $)];
parens(Out, _OpP, _Prec) -> Out.

escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape(C) -> C.

opaque_symbol([First | Rest] = Name)
  when First >= $a, First =< $z ->
    case lists:all(fun plain_symbol_char/1, Rest) of
        true -> Name;
        false -> quoted_symbol(Name)
    end;
opaque_symbol(Name) ->
    quoted_symbol(Name).

plain_symbol_char(C) when C >= $a, C =< $z -> true;
plain_symbol_char(C) when C >= $A, C =< $Z -> true;
plain_symbol_char(C) when C >= $0, C =< $9 -> true;
plain_symbol_char($_) -> true;
plain_symbol_char(_) -> false.

quoted_symbol(Name) ->
    [$', [quoted_symbol_char(C) || C <- Name], $'].

quoted_symbol_char($') -> "\\'";
quoted_symbol_char($\\) -> "\\\\";
quoted_symbol_char($\n) -> "\\n";
quoted_symbol_char($\r) -> "\\r";
quoted_symbol_char($\t) -> "\\t";
quoted_symbol_char($\v) -> "\\v";
quoted_symbol_char($\b) -> "\\b";
quoted_symbol_char($\f) -> "\\f";
quoted_symbol_char(27) -> "\\e";
quoted_symbol_char(C) when C < 32; C =:= 127 ->
    io_lib:format("\\x~.16B\\", [C]);
quoted_symbol_char(C) -> C.

%% An improper tail still renders rather than crashing the page.
proper([H | T]) when is_list(T) -> [H | proper(T)];
proper([H | T]) -> [H, T];
proper([]) -> [].

printable(B) ->
    case unicode:characters_to_list(B) of
        L when is_list(L) -> io_lib:printable_unicode_list(L);
        _ -> false
    end.

%%%===================================================================
%%% plumbing
%%%===================================================================

encode(Json) -> iolist_to_binary(json:encode(Json)).

json_reply(Code, Json, Req) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, encode(Json), Req).

%% A present query value is a binary; a valueless key is the atom `true`. Normalise anything non-binary
%% to `undefined` so callers see "absent".
bin_param(B) when is_binary(B) -> B;
bin_param(_)                   -> undefined.

int_param(Bin, Default) when is_binary(Bin) ->
    case string:to_integer(binary_to_list(Bin)) of
        {I, ""} when I >= 0 -> I;
        _ -> Default
    end;
int_param(_NotBinary, Default) -> Default.

text(T) when is_binary(T) -> T;
text(T) when is_atom(T) -> atom_to_binary(T, utf8);
text(T) when is_list(T) ->
    case unicode:characters_to_binary(T) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~0p", [T]))
    end;
text(T) -> iolist_to_binary(io_lib:format("~0p", [T])).
