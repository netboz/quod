-module(quod_dtx_owner).
-moduledoc """
Retained transaction lifecycle, executed by the existing Simplex owner.

The opaque registry is the only volatile custody of signed DTX controls.
This module has no process, timer, mailbox, transport or consensus state.
Simplex retains signing/ledger custody and executes the returned transitions.
""".
-include("quod_dtx_owner.hrl").
-export([new/0, rows/1, count/1, bytes/1, waiter_count/1, ready_count/1, blocked_count/1,
         put_new/2, take/2, replace/2, attach_waiter/3,
         detach_waiter/2, waiter_tags/1, ready_rows/1,
         classify/2, admission/3, placement/2, binding/6, desired/3, signature_actions/5,
         reconcile_journal/4, retire_begin/5]).
-export_type([state/0]).
-ifdef(TEST).
-export([stats/1]).
-endif.

%% One bundled invariant for retained signed controls. All fields are mutated
%% together by this Simplex process; this is not another runtime owner.
-record(retained_dtx, {
    rows = #{} :: #{<<_:256>> => #dtx_submission{}},
    ready = gb_sets:empty() :: gb_sets:set({term(), <<_:256>>}),
    blocked = gb_sets:empty() :: gb_sets:set({term(), <<_:256>>}),
    waiter_index = #{} :: #{pid() => <<_:256>>},
    bytes = 0 :: non_neg_integer(),
    fingerprint = undefined :: undefined | term()
}).

-opaque state() :: #retained_dtx{}.
-type digest() :: <<_:256>>.
-type binding_result() ::
        {ok, {binary(), digest(), digest(), digest()}} |
        {error, not_in_charge | {ontology_unavailable, binary()}}.
-type disposition() :: ready | {blocked, active_group | apply} |
                       {refused, conflict} | stale.

-spec new() -> state().
new() -> #retained_dtx{}.

-spec rows(state()) -> #{digest() => #dtx_submission{}}.
rows(#retained_dtx{rows = Rows}) -> Rows.

-spec count(state()) -> non_neg_integer().
count(#retained_dtx{rows = Rows}) -> map_size(Rows).

-spec bytes(state()) -> non_neg_integer().
bytes(#retained_dtx{bytes = Bytes}) -> Bytes.

-spec waiter_count(state()) -> non_neg_integer().
waiter_count(#retained_dtx{waiter_index = Waiters}) ->
    map_size(Waiters).

-spec ready_count(state()) -> non_neg_integer().
ready_count(#retained_dtx{ready = Ready}) -> gb_sets:size(Ready).

-spec blocked_count(state()) -> non_neg_integer().
blocked_count(#retained_dtx{blocked = Blocked}) ->
    gb_sets:size(Blocked).

order_key(#dtx_submission{control = Control, digest = Digest}) ->
    {quod_dtx:control_order_key(Control), Digest}.

-spec put_new(#dtx_submission{}, state()) -> state().
put_new(Row = #dtx_submission{digest = Digest, bytes = Bytes,
                              waiters = Waiters, placement = Placement},
        Registry = #retained_dtx{rows = Rows, waiter_index = WaiterIndex,
                                  bytes = Total}) ->
    false = maps:is_key(Digest, Rows),
    true = is_integer(Bytes) andalso Bytes >= 0,
    true = maps:fold(
             fun(Pid, true, Unique) ->
                     Unique andalso not maps:is_key(Pid, WaiterIndex)
             end, true, Waiters),
    Registry1 = add_order_key(Row, Placement, Registry),
    Registry1#retained_dtx{
      rows = Rows#{Digest => Row},
      waiter_index = maps:fold(
                       fun(Pid, true, Acc) -> Acc#{Pid => Digest} end,
                       WaiterIndex, Waiters),
      bytes = Total + Bytes}.

add_order_key(Row, ready, Registry = #retained_dtx{ready = Ready}) ->
    Registry#retained_dtx{ready = gb_sets:add(
                                  order_key(Row), Ready)};
add_order_key(Row, blocked, Registry = #retained_dtx{blocked = Blocked}) ->
    Registry#retained_dtx{blocked = gb_sets:add(
                                    order_key(Row), Blocked)}.

delete_order_key(Row, ready, Registry = #retained_dtx{ready = Ready}) ->
    Registry#retained_dtx{ready = gb_sets:delete_any(
                                  order_key(Row), Ready)};
delete_order_key(Row, blocked, Registry = #retained_dtx{blocked = Blocked}) ->
    Registry#retained_dtx{blocked = gb_sets:delete_any(
                                    order_key(Row), Blocked)}.

-spec take(digest(), state()) -> {#dtx_submission{}, state()} | error.
take(Digest, Registry = #retained_dtx{rows = Rows, waiter_index = WaiterIndex,
                                     bytes = Total}) ->
    case maps:take(Digest, Rows) of
        {Row = #dtx_submission{bytes = Bytes, waiters = Waiters,
                               placement = Placement}, Rest} ->
            Registry1 = delete_order_key(Row, Placement, Registry),
            {Row,
             Registry1#retained_dtx{
               rows = Rest,
               waiter_index = maps:fold(
                                fun(Pid, true, Acc) -> maps:remove(Pid, Acc) end,
                                WaiterIndex, Waiters),
               bytes = Total - Bytes}};
        error ->
            error
    end.

-spec replace(#dtx_submission{}, state()) -> state().
replace(Row = #dtx_submission{digest = Digest}, Registry) ->
    case take(Digest, Registry) of
        {_Old, Registry1} -> put_new(Row, Registry1);
        error -> error({missing_retained_dtx, Digest})
    end.

-spec attach_waiter(digest(), none | {dtx_endpoint, pid()}, state()) ->
          {ok, state()} | {error, waiter_already_owned | missing_retained_dtx}.
attach_waiter(_Digest, none, Registry) ->
    {ok, Registry};
attach_waiter(
  Digest, {dtx_endpoint, Pid},
  Registry = #retained_dtx{rows = Rows, waiter_index = WaiterIndex})
  when is_pid(Pid) ->
    case {maps:get(Digest, Rows, undefined),
          maps:get(Pid, WaiterIndex, undefined)} of
        {#dtx_submission{}, Digest} ->
            {ok, Registry};
        {#dtx_submission{waiters = Waiters} = Row, undefined} ->
            Row1 = Row#dtx_submission{waiters = Waiters#{Pid => true}},
            {ok, Registry#retained_dtx{
                   rows = Rows#{Digest => Row1},
                   waiter_index = WaiterIndex#{Pid => Digest}}};
        {#dtx_submission{}, _OtherDigest} ->
            {error, waiter_already_owned};
        {undefined, _} ->
            {error, missing_retained_dtx}
    end.

-spec detach_waiter(pid(), state()) -> {boolean(), state()}.
detach_waiter(
  Pid, Registry = #retained_dtx{rows = Rows, waiter_index = WaiterIndex}) ->
    case maps:take(Pid, WaiterIndex) of
        {Digest, RestIndex} ->
            Row = #dtx_submission{waiters = Waiters} = maps:get(Digest, Rows),
            Row1 = Row#dtx_submission{waiters = maps:remove(Pid, Waiters)},
            {true, Registry#retained_dtx{
                     rows = Rows#{Digest => Row1},
                     waiter_index = RestIndex}};
        error ->
            {false, Registry}
    end.

-spec waiter_tags(#dtx_submission{}) -> [{dtx_endpoint, pid()}].
waiter_tags(#dtx_submission{waiters = Waiters}) ->
    [{dtx_endpoint, Pid} || Pid <- maps:keys(Waiters)].
-spec ready_rows(state()) -> [{digest(), #dtx_submission{}}].
ready_rows(#retained_dtx{rows = Rows, ready = Ready}) ->
    [{Digest, maps:get(Digest, Rows)} || {_Key, Digest} <- gb_sets:to_list(Ready)].

-ifdef(TEST).
-spec stats(state()) -> map().
stats(R = #retained_dtx{}) ->
    #{retained => count(R), ready => ready_count(R), blocked => blocked_count(R),
      waiters => waiter_count(R), bytes => R#retained_dtx.bytes,
      ready_order => gb_sets:to_list(R#retained_dtx.ready),
      blocked_order => gb_sets:to_list(R#retained_dtx.blocked),
      waiter_index => R#retained_dtx.waiter_index,
      fingerprint => R#retained_dtx.fingerprint}.
-endif.

%% Ownership is anchored membership, not execution readiness. No caller may
%% turn a temporary sync/KB pause into an admission loss.
-spec binding(binary(), undefined | digest(), digest(),
              #{digest() => digest()}, boolean(), undefined | quod_dtx:projection()) ->
          binding_result().
binding(Ns, <<_:256>> = Anchor, Self, Admissions, true, Projection)
  when is_map(Projection) ->
    case maps:get(Self, Admissions, undefined) of
        <<_:256>> = Admission -> {ok, {Ns, Anchor, Self, Admission}};
        _ -> {error, not_in_charge}
    end;
binding(_Ns, <<_:256>>, _Self, _Admissions, false, Projection)
  when is_map(Projection) -> {error, not_in_charge};
binding(Ns, _Anchor, _Self, _Admissions, _Participant, _Projection) ->
    {error, {ontology_unavailable, Ns}}.

%% The certified projection and the retained pre-commit body are successive
%% sources of one obligation, never two independently maintained inventories.
-spec desired(binding_result(), undefined | quod_dtx:projection(), state()) -> map().
desired({ok, Binding}, Projection, Registry) ->
    Committed = maps:from_list(
      [{Group, {reference, Group, Ref}}
       || {Group, Ref} <- quod_dtx:origin_recoveries(Projection)]),
    Pending = maps:from_list(
      [{Group, {record, Group, Begin, Ref}}
       || #dtx_submission{record = {quod_dtx_begin, 3, _, _, _} = Begin,
                           group_id = Group} <- maps:values(rows(Registry)),
          {ok, Ref = {group, Ns, Anchor, Author, Admission, BoundGroup}} <-
              [quod_dtx:begin_group_ref(Begin)],
          BoundGroup =:= Group,
          {Ns, Anchor, Author, Admission} =:= Binding]),
    maps:merge(Committed, Pending);
desired({error, _}, _Projection, _Registry) -> #{}.

%% Certified inclusion dominates the active projection, including after the
%% active group has retired. Return only the exact requested semantic digest;
%% another record for the same phase is not an acceptance of this request.
%% A reference is evidence to verify, not permission to re-run its old plan.
-spec admission(quod_dtx:control_record(), quod_dtx:group_history(),
                undefined | quod_dtx:projection()) ->
          {included, quod_dtx:certified_ref()} | disposition().
admission(Record, History, #{target := Target} = Projection) ->
    case quod_dtx:history_phase(quod_dtx:record_kind(Record), History) of
        {ok, Ref} ->
            Digest = quod_dtx:record_digest(Record),
            case quod_dtx:certified_ref_binding(Ref) of
                {ok, Target, _Slot, Digest} -> {included, Ref};
                {ok, Target, _Slot, _OtherDigest} -> stale;
                _ -> error(phase_index_corrupt)
            end;
        not_found -> placement(Record, Projection)
    end;
admission(_Record, _History, _Projection) -> stale.

%% Admission, retained reclassification and the same-turn installation
%% assertion all use this one active-projection rule. Installation does not
%% repeat the history lookup already performed at admission.
-spec placement(quod_dtx:control_record(), undefined | quod_dtx:projection()) ->
          disposition().
placement(Record, Projection) when is_map(Projection) ->
    quod_dtx:proposal_readiness(Record, Projection);
placement(_Record, _Projection) -> stale.

%% Classify the entire current registry before any signature effect. Returned
%% retirements carry the removed rows so effects cannot reread an old map.
-spec classify(undefined | quod_dtx:projection(), state()) ->
          {state(), [{#dtx_submission{}, stale | {refused, conflict}}]}.
classify(Projection, Registry = #retained_dtx{fingerprint = Projection}) ->
    {Registry, []};
classify(Projection, Registry = #retained_dtx{rows = Rows}) ->
    {Next, Retired} = maps:fold(
      fun(Digest, Row = #dtx_submission{record = Record, placement = Old}, {Acc, Out}) ->
          case placement(Record, Projection) of
              Reason when Reason =:= stale; Reason =:= {refused, conflict} ->
                  {Row, Rest} = take(Digest, Acc),
                  {Rest, [{Row, Reason} | Out]};
              Disposition ->
                  Placement = case Disposition of ready -> ready; {blocked, _} -> blocked end,
                  case Placement =:= Old of
                      true -> {Acc, Out};
                      false -> {replace(Row#dtx_submission{placement = Placement}, Acc), Out}
                  end
          end
      end, {Registry, []}, Rows),
    {Next#retained_dtx{fingerprint = Projection}, lists:reverse(Retired)}.

%% Execution is a capability, not a lifetime. In particular a consumed local
%% sequence waits for readiness before renewal; its exact body/waiters remain.
-spec signature_actions(binding_result(), boolean(), #{digest() => digest()},
                        #{quod_signing_journal:lane() => non_neg_integer()}, state()) ->
          [{#dtx_submission{}, renew | retire}].
signature_actions(Binding, Ready, Admissions, Floors, Registry) ->
    [{Row, Action} || Row <- maps:values(rows(Registry)),
                     Action <- [signature_action(Row, Binding, Ready, Admissions, Floors)],
                     Action =/= keep].

signature_action(_Row, {error, _}, _Ready, _Admissions, _Floors) -> retire;
signature_action(#dtx_submission{control = Control},
                 {ok, {Ns, Anchor, Self, Admission}}, Ready, Admissions, Floors) ->
    #{author := Author, author_admission := SignedAdmission, sequence := Sequence} =
        quod_dtx:control_metadata(Control),
    Lane = {SignedAdmission, Author},
    Floor = maps:get(Lane, Floors, 0),
    case Lane =:= {Admission, Self} of
        true when Sequence =< Floor, Ready -> renew;
        true -> keep;
        false ->
            case maps:get(Author, Admissions, undefined) =:= SignedAdmission
                 andalso Sequence > Floor
                 andalso quod_dtx:verify_control({Ns, Anchor}, Control) of
                true -> keep;
                false -> retire
            end
    end.

%% Pending Begin custody belongs only to the signing journal. A committed
%% history capture contains no local pending list and cannot overwrite newer
%% admissions. The retained phase index proves inclusion even after Complete
%% has evicted the active group. Reads are bounded by pending groups, not the
%% ledger prefix. Index errors stay loud at this owner boundary.
-spec reconcile_journal(non_neg_integer(), quod_dtx:projection(),
                        quod_dtx_phase_index:index(), quod_signing_journal:handle()) ->
          {ok, quod_signing_journal:handle()}.
reconcile_journal(Slot, Projection, Index, Journal) ->
    reconcile_pending(Slot, Projection, Index,
                      quod_signing_journal:pending_begins(Journal), Journal).

%% Deterministic rejection removes exactly this journal obligation. Other
%% rows are retired only by the same indexed inclusion/admission rules.
-spec retire_begin(digest(), non_neg_integer(), quod_dtx:projection(),
                   quod_dtx_phase_index:index(), quod_signing_journal:handle()) ->
          {ok, quod_signing_journal:handle()}.
retire_begin(Group, Slot, Projection, Index, Journal) ->
    reconcile_pending(Slot, Projection, Index,
                      maps:remove(Group, quod_signing_journal:pending_begins(Journal)), Journal).

reconcile_pending(Slot, Projection, Index, Rows, Journal) ->
    Admissions = maps:get(admissions, Projection),
    Pending = maps:fold(
      fun(Group, #{lane := {Admission, Author} = Lane}, Acc) ->
          case maps:get(Author, Admissions, undefined) =:= Admission of
              false -> Acc;
              true ->
                  {ok, History} = quod_dtx_phase_index:history(Index, Group),
                  case quod_dtx:history_phase('begin', History) of
                      not_found -> Acc#{Group => Lane};
                      {ok, _Ref} -> Acc
                  end
          end
      end, #{}, Rows),
    reconcile(Slot, Projection, Pending, Journal).

reconcile(Slot, Projection, Pending, Journal) ->
    quod_signing_journal:reconcile(Journal,
      #{committed_slot => Slot,
        live_dtx_lanes => maps:get(dtx_lanes, Projection),
        current_admissions => maps:get(admissions, Projection),
        pending_begins => Pending}).
