-module(quod_ingress_state).
-moduledoc """
Pure state and routing policy for consensus ingress.

The module owns the bounded parked queue and one canonical snapshot
of the consensus facts that routing is allowed to inspect.  It performs no
signing, decoding, I/O, tracing, replies, or consensus mutation.  Callers
execute the returned routing decision and publish a new view when those effects
change any routing fact. The validation callback supplied to `route/5` must
also be pure.

`put_view/3` deliberately separates the caller's source token from the
canonical route fingerprint.  The source is a complete cache key: when it is unchanged, Facts are
not inspected.  The caller must therefore change it whenever any supplied fact
can change.  A new source with identical canonical facts updates
`view_source/1` without waking either drain.
""".

-include("quod_ledger.hrl").
-include("quod_ingress_limits.hrl").

-export([
    new/0,
    view_source/1,
    put_view/3,
    request/1,
    request_change/1,
    request_membership/1,
    route/5,
    relay_target_open/2,
    fingerprint/1,
    route_fingerprint/1,
    custody_fingerprint/1,
    enqueue/5,
    detach_front/1,
    consume_detached/2,
    restore_detached_front_rev/2,
    take_expired/2,
    take_all/1,
    count/1,
    item/1
]).

-ifdef(TEST).
-export([summary/1, items/1]).
-endif.

-export_type([state/0]).

-define(MAX_INGRESS_TXS, 512).
-define(MAX_INGRESS_BYTES, (2 * ?MAX_BLOCK_BYTES)).
-define(MAX_INGRESS_PER_AUTHOR, 64).

-type pass() :: entry | drain.
-type route_origin() ::
        local
      | custody
      | {relayed, term(), slot()}.
-type park_cause() :: barrier | fifo | awaiting_turn.
-type route_decision() ::
        {reject, bad_change | too_large | stale_seq}
      | redirect
      | {park, park_cause()}
      | {collect, slot()}
      | {relay, node_id(), slot()}.
-type ingress_capability() :: accept | hold | reject.
-type lane() ::
        empty
      | blocked
      | placement_conflict
      | {target, node_id(), slot()}.

-record(view, {
    self :: node_id(),
    capability :: ingress_capability(),
    committee_id :: term(),
    validator_source = [] :: [node_id()],
    validators = {} :: tuple(),
    validator_set = #{} :: map(),
    durable_head :: slot(),
    approved :: slot(),
    proposal_visible :: boolean(),
    proposal_slot :: blocked | {ok, slot()},
    consensus_barrier :: boolean(),
    approved_author_seqs :: inactive | error | {ok, map()},
    collecting :: none | {slot(), non_neg_integer(), non_neg_integer()},
    custody_lane :: empty | {node_id(), slot(), term()},
    custody_ready = 0 :: non_neg_integer(),
    relay_lane :: empty | {node_id(), slot()},
    relay_pending_count :: inactive | non_neg_integer()
}).

-record(request, {
    change :: #transaction{},
    membership = unknown :: unknown | boolean(),
    item_bytes = unknown :: unknown | pos_integer()
}).

-record(item, {
    context :: term(),
    waiter :: term(),
    request :: #request{},
    anchor :: integer()
}).

-record(state, {
    source = undefined :: term(),
    view = undefined :: undefined | #view{},
    ingress_key = undefined :: term(),
    custody_key = undefined :: term(),
    queue = queue:new() :: queue:queue(#item{}),
    count = 0 :: non_neg_integer(),
    bytes = 0 :: non_neg_integer(),
    authors = #{} :: #{node_id() => pos_integer()},
    wake_revision = 0 :: non_neg_integer()
}).

-opaque state() :: #state{}.
-type request() :: #request{}.
-type item() :: #item{}.

-spec new() -> state().
new() ->
    #state{}.

-spec view_source(state()) -> term().
view_source(#state{source = Source}) ->
    Source.

-spec put_view(term(), map(), state()) -> state().
put_view(Source, _Facts,
         State = #state{source = Source, view = View})
  when is_record(View, view) ->
    State;
put_view(Source, Facts, State = #state{view = Previous})
  when is_map(Facts) ->
    View = view_from_facts(Facts, Previous),
    case View =:= Previous of
        true ->
            State#state{source = Source};
        false ->
            IngressKey = ingress_projection(View),
            CustodyKey = custody_projection(View, IngressKey),
            State#state{
              source = Source,
              view = View,
              ingress_key = IngressKey,
              custody_key = CustodyKey}
    end;
put_view(_Source, _Facts, _State) ->
    erlang:error(badarg).

-spec request(#transaction{}) -> request().
request(Change = #transaction{}) ->
    #request{change = Change};
request(_Change) ->
    erlang:error(badarg).

prepare_request(
  Request = #request{
               change = Change = #transaction{},
               membership = unknown,
               item_bytes = unknown},
  Membership) when is_boolean(Membership) ->
    SignedBytes =
        case quod_transaction:encoded_ledger_transaction_size(Change) of
            {ok, Size} -> Size;
            {error, _} -> ?MAX_BLOCK_BYTES + 1
        end,
    Request#request{
      membership = Membership,
      item_bytes = ?BATCH_ENVELOPE_BYTES + SignedBytes};
prepare_request(Request = #request{
                            membership = Membership,
                            item_bytes = ItemBytes},
                Membership)
  when is_boolean(Membership),
       is_integer(ItemBytes), ItemBytes > 0 ->
    Request.

-spec request_change(request()) -> #transaction{}.
request_change(#request{change = Change}) ->
    Change.

-spec request_membership(request()) -> unknown | boolean().
request_membership(#request{membership = Membership}) ->
    Membership.

-spec route(
        pass(), route_origin(), request(),
        fun(() -> invalid | {valid, boolean()}), state()) ->
          {route_decision(), request()}.
route(Pass, Origin, Request = #request{}, Validate,
      #state{view = View, count = QueueCount})
  when (Pass =:= entry orelse Pass =:= drain),
       is_function(Validate, 0), is_record(View, view) ->
    route_request(Pass, Origin, Request, Validate, View, QueueCount);
route(_Pass, _Origin, _Request, _Validate, _State) ->
    erlang:error(badarg).

-spec relay_target_open({term(), slot()}, state()) -> boolean().
relay_target_open(
  {CommitteeId, TargetSlot}, #state{view = View}) ->
    relay_target_open_view(CommitteeId, TargetSlot, View);
relay_target_open(_Target, _State) ->
    false.

-spec fingerprint(state()) -> {term(), non_neg_integer()}.
fingerprint(
  #state{ingress_key = Key, wake_revision = Revision}) ->
    {Key, Revision}.

-spec route_fingerprint(state()) -> term().
route_fingerprint(#state{ingress_key = Key}) ->
    Key.

-spec custody_fingerprint(state()) -> {term(), non_neg_integer()}.
custody_fingerprint(
  #state{custody_key = Key, view = View}) ->
    Ready =
        case View of
            #view{custody_ready = Count} -> Count;
            undefined -> 0
        end,
    {Key, Ready}.

-spec enqueue(term(), term(), request(), integer(), state()) ->
          {ok, pos_integer(), state()} | full.
enqueue(Context, Waiter,
        Request = #request{
                    change = #transaction{author = Author},
                    membership = Membership,
                    item_bytes = ItemBytes},
        Anchor,
        State = #state{queue = Queue, count = Count, bytes = Bytes,
                       authors = Authors,
                       wake_revision = WakeRevision})
  when is_boolean(Membership), is_integer(ItemBytes), ItemBytes > 0,
       is_integer(Anchor) ->
    PerAuthor = maps:get(Author, Authors, 0),
    case Count >= ?MAX_INGRESS_TXS
         orelse Bytes + ItemBytes > ?MAX_INGRESS_BYTES
         orelse PerAuthor >= ?MAX_INGRESS_PER_AUTHOR of
        true ->
            full;
        false ->
            Item = #item{
                      context = Context,
                      waiter = Waiter,
                      request = Request,
                      anchor = Anchor},
            Depth = Count + 1,
            {ok, Depth,
             State#state{
               queue = queue:in(Item, Queue),
               count = Depth,
               bytes = Bytes + ItemBytes,
               authors = Authors#{Author => PerAuthor + 1},
               wake_revision =
                   case PerAuthor of
                       0 -> WakeRevision + 1;
                       _ -> WakeRevision
                   end}}
    end;
enqueue(_Context, _Waiter, _Request, _Anchor, _State) ->
    erlang:error(badarg).

-spec detach_front(state()) -> empty | {item(), state()}.
detach_front(State = #state{queue = Queue}) ->
    case queue:out(Queue) of
        {empty, _} ->
            empty;
        {{value, Item}, Queue1} ->
            {Item, State#state{queue = Queue1}}
    end.

-spec consume_detached(item(), state()) -> state().
consume_detached(Item = #item{}, State = #state{}) ->
    remove_item(Item, State).

-spec restore_detached_front_rev([item()], state()) -> state().
restore_detached_front_rev([], State = #state{}) ->
    State;
restore_detached_front_rev(ItemsRev, State = #state{queue = Queue})
  when is_list(ItemsRev) ->
    %% Items are opaque values returned by detach_front/1 from this same
    %% bounded queue, in reverse encounter order. Detaching leaves their
    %% accounting in place; in_r reconnects them in original FIFO order
    %% without a reverse plus temporary queue.
    State#state{
      queue =
          lists:foldl(
            fun queue:in_r/2, Queue, ItemsRev)};
restore_detached_front_rev(_Items, _State) ->
    erlang:error(badarg).

-spec take_expired(integer(), state()) -> {[item()], state()}.
take_expired(Cutoff, State = #state{}) when is_integer(Cutoff) ->
    take_expired(Cutoff, State, []);
take_expired(_Cutoff, _State) ->
    erlang:error(badarg).

-spec take_all(state()) -> {[item()], state()}.
take_all(State = #state{queue = Queue, count = Count,
                        wake_revision = WakeRevision}) ->
    {queue:to_list(Queue),
     State#state{
       queue = queue:new(),
       count = 0,
       bytes = 0,
       authors = #{},
       wake_revision =
           case Count of
               0 -> WakeRevision;
               _ -> WakeRevision + 1
           end}}.

-spec count(state()) -> non_neg_integer().
count(#state{count = Count}) ->
    Count.

-ifdef(TEST).
-spec summary(state()) -> map().
summary(#state{count = Count, bytes = Bytes, authors = Authors}) ->
    #{count => Count, bytes => Bytes, authors => Authors}.

-spec items(state()) -> [item()].
items(#state{queue = Queue}) ->
    queue:to_list(Queue).
-endif.

-spec item(item()) -> {term(), term(), request(), integer()}.
item(#item{context = Context, waiter = Waiter,
           request = Request, anchor = Anchor}) ->
    {Context, Waiter, Request, Anchor}.

%% ------------------------------------------------------------------
%% Route planner
%% ------------------------------------------------------------------

route_request(Pass, local, Request, Validate, View, QueueCount) ->
    case ingress_capability(Pass, local, View) of
        reject ->
            {redirect, Request};
        hold ->
            {{park, awaiting_turn}, Request};
        accept ->
            case Validate() of
                invalid ->
                    {{reject, bad_change}, Request};
                {valid, Membership} ->
                    case prepare_for_route(Request, Membership) of
                        {too_large, Prepared} ->
                            {{reject, too_large}, Prepared};
                        {ok, Prepared} ->
                            {place(Pass, local, Prepared,
                                   View, QueueCount),
                             Prepared}
                    end
            end
    end;
route_request(Pass, custody,
              Request, Validate, View, QueueCount) ->
    %% Once signed custody exists, neither demotion nor a transient view can
    %% prove exclusion.  Those states hold the exact bytes to their deadline.
    case ingress_capability(Pass, custody, View) of
        reject ->
            {{park, awaiting_turn}, Request};
        hold ->
            {{park, awaiting_turn}, Request};
        accept ->
            case Validate() of
                invalid ->
                    {{park, awaiting_turn}, Request};
                {valid, Membership} ->
                    case custody_sequence_status(Request, View) of
                        stale ->
                            {{reject, stale_seq}, Request};
                        hold ->
                            {{park, awaiting_turn}, Request};
                        current ->
                            case prepare_for_route(
                                   Request, Membership) of
                                {too_large, Prepared} ->
                                    {{reject, too_large}, Prepared};
                                {ok, Prepared} ->
                                    {place(Pass, custody, Prepared,
                                           View, QueueCount),
                                     Prepared}
                            end
                    end
            end
    end;
route_request(Pass, Origin = {relayed, CommitteeId, TargetSlot},
              Request, Validate, View, QueueCount) ->
    case Validate() of
        invalid ->
            {{reject, bad_change}, Request};
        {valid, Membership} ->
            case prepare_for_route(Request, Membership) of
                {too_large, Prepared} ->
                    {{reject, too_large}, Prepared};
                {ok, Prepared} ->
                    case relay_target_open_view(
                           CommitteeId, TargetSlot, View) of
                        false ->
                            {redirect, Prepared};
                        true ->
                            case ingress_capability(Pass, Origin, View) of
                                reject -> {redirect, Prepared};
                                hold ->
                                    {{park, awaiting_turn}, Prepared};
                                accept ->
                                    {place(Pass, Origin, Prepared,
                                           View, QueueCount),
                                     Prepared}
                            end
                    end
            end
    end.

prepare_for_route(Request, Membership) ->
    Prepared = prepare_request(Request, Membership),
    case oversized(Prepared) of
        true -> {too_large, Prepared};
        false -> {ok, Prepared}
    end.

-spec ingress_capability(pass(), route_origin(), #view{}) ->
          ingress_capability().
ingress_capability(entry, local, #view{capability = accept}) ->
    accept;
ingress_capability(entry, local, #view{}) ->
    reject;
ingress_capability(_Pass, _Origin, #view{capability = Capability}) ->
    Capability.

place(_Pass, _Origin, _Request,
      #view{consensus_barrier = true}, _QueueCount) ->
    {park, barrier};
place(Pass, Origin, Request, View, QueueCount) ->
    Floor = View#view.approved + 1,
    case Origin of
        local ->
            place_local(Pass, Origin, Request, Floor,
                        View, QueueCount);
        custody ->
            place_local(Pass, Origin, Request, Floor,
                        View, QueueCount);
        {relayed, _CommitteeId, TargetSlot} ->
            place_relayed(Pass, TargetSlot, Request, Floor,
                          View, QueueCount)
    end.

place_local(entry, _Origin, _Request, _Floor, _View, QueueCount)
  when QueueCount > 0 ->
    {park, fifo};
place_local(Pass, Origin, Request, Floor, View, QueueCount) ->
    case origin_lane(Floor, Origin, View) of
        {target, Target, TargetSlot} ->
            case Target =:= View#view.self of
                true ->
                    collect_or_park(
                      Pass, TargetSlot, Floor, Request, View, QueueCount);
                false ->
                    {relay, Target, TargetSlot}
            end;
        blocked ->
            {park, fifo};
        placement_conflict ->
            {park, awaiting_turn};
        empty ->
            Seat =
                case View#view.proposal_visible of
                    true -> Floor + 1;
                    false -> Floor
                end,
            case leader(Seat, View) of
                Self when Self =:= View#view.self ->
                    collect_or_park(
                      Pass, Seat, Floor, Request, View, QueueCount);
                none ->
                    redirect;
                Leader ->
                    {relay, Leader, Seat}
            end
    end.

place_relayed(Pass, TargetSlot, Request, Floor, View, QueueCount) ->
    case TargetSlot =:= Floor of
        true ->
            collect_or_park(
              Pass, TargetSlot, Floor, Request, View, QueueCount);
        false ->
            {park, awaiting_turn}
    end.

collect_or_park(Pass, TargetSlot, Floor, Request, View, QueueCount) ->
    case TargetSlot =:= Floor
         andalso View#view.proposal_slot =:= {ok, Floor}
         andalso admissible_for(
                   Pass, Request, View, QueueCount) of
        true -> {collect, Floor};
        false -> {park, awaiting_turn}
    end.

-spec origin_lane(slot(), local | custody, #view{}) -> lane().
origin_lane(_Floor, local, #view{custody_ready = Ready})
  when Ready > 0 ->
    blocked;
origin_lane(Floor, _Origin,
            View = #view{custody_lane = empty}) ->
    relay_lane(Floor, View);
origin_lane(Floor, _Origin,
            View = #view{custody_lane =
                              {Target, TargetSlot,
                               PlacementCommitteeId}}) ->
    case PlacementCommitteeId =:= View#view.committee_id of
        false ->
            placement_conflict;
        true ->
            lane_status(Floor, Target, TargetSlot, View)
    end.

relay_lane(_Floor, #view{relay_lane = empty}) ->
    empty;
relay_lane(Floor, View = #view{relay_lane = {Target, TargetSlot}}) ->
    lane_status(Floor, Target, TargetSlot, View).

lane_status(Floor, Target, TargetSlot,
            View = #view{validator_set = Validators}) ->
    case maps:is_key(Target, Validators) of
        false ->
            blocked;
        true when TargetSlot < Floor ->
            blocked;
        true when TargetSlot =:= Floor ->
            case View#view.proposal_visible of
                true -> blocked;
                false -> {target, Target, TargetSlot}
            end;
        true ->
            {target, Target, TargetSlot}
    end.

admissible_for(entry, Request, View, QueueCount) ->
    QueueCount =:= 0
        andalso admissible_without_queue(Request, View);
admissible_for(drain, Request, View, _QueueCount) ->
    admissible_without_queue(Request, View).

admissible_without_queue(
  #request{membership = Membership, item_bytes = ItemBytes},
  #view{approved = Approved, durable_head = Durable,
        collecting = Collecting}) ->
    SignedBytes = ItemBytes - ?BATCH_ENVELOPE_BYTES,
    (not Membership orelse Approved =:= Durable)
        andalso
          case Collecting of
              none ->
                  true;
              {_Slot, _Count, Bytes} ->
                  not Membership
                      andalso
                        Bytes + SignedBytes =< ?MAX_BLOCK_BYTES
          end.

oversized(#request{item_bytes = Bytes}) ->
    Bytes > ?MAX_BLOCK_BYTES.

custody_sequence_status(
  #request{change = #transaction{author = Author, author_seq = Seq}},
  #view{approved_author_seqs = {ok, Floor}})
  when is_integer(Seq), Seq > 0 ->
    case Seq > maps:get(Author, Floor, 0) of
        true -> current;
        false -> stale
    end;
custody_sequence_status(
  #request{}, #view{approved_author_seqs = error}) ->
    hold;
custody_sequence_status(
  #request{}, #view{approved_author_seqs = inactive}) ->
    hold;
custody_sequence_status(#request{}, #view{}) ->
    stale.

relay_target_open_view(
  CommitteeId, TargetSlot,
  View = #view{committee_id = CommitteeId})
  when is_integer(TargetSlot), TargetSlot > 0 ->
    Floor = View#view.approved + 1,
    leader(TargetSlot, View) =:= View#view.self
        andalso
          (TargetSlot > Floor
           orelse
             (TargetSlot =:= Floor
              andalso not View#view.proposal_visible));
relay_target_open_view(_CommitteeId, _TargetSlot, _View) ->
    false.

leader(_Slot, #view{validators = Validators})
  when tuple_size(Validators) =:= 0 ->
    none;
leader(Slot, #view{validators = Validators})
  when is_integer(Slot), Slot > 0 ->
    N = tuple_size(Validators),
    element(((Slot - 1) rem N) + 1, Validators);
leader(_Slot, _View) ->
    none.

%% ------------------------------------------------------------------
%% Queue bookkeeping
%% ------------------------------------------------------------------

remove_item(
  #item{request =
            #request{
              change = #transaction{author = Author},
              item_bytes = ItemBytes}},
  State = #state{count = Count, bytes = Bytes, authors = Authors,
                 wake_revision = WakeRevision}) ->
    Authors1 =
        case maps:get(Author, Authors) of
            1 -> maps:remove(Author, Authors);
            N -> Authors#{Author => N - 1}
        end,
    State#state{
      count = Count - 1,
      bytes = Bytes - ItemBytes,
      authors = Authors1,
      wake_revision = WakeRevision + 1}.

take_expired(Cutoff, State = #state{queue = Queue}, Acc) ->
    case queue:peek(Queue) of
        {value, #item{anchor = Anchor}} when Anchor =< Cutoff ->
            {Item, State1} = detach_front(State),
            take_expired(
              Cutoff, consume_detached(Item, State1), [Item | Acc]);
        _ ->
            {lists:reverse(Acc), State}
    end.

%% ------------------------------------------------------------------
%% View construction and fingerprints
%% ------------------------------------------------------------------

ingress_projection(
  #view{self = Self, capability = Capability,
        committee_id = CommitteeId,
        validators = Validators, durable_head = Durable,
        approved = Approved, proposal_visible = ProposalVisible,
        proposal_slot = ProposalSlot,
        consensus_barrier = ConsensusBarrier,
        collecting = Collecting, custody_lane = CustodyLane,
        custody_ready = CustodyReady, relay_lane = RelayLane}) ->
    {Self, Capability, CommitteeId, Validators,
     Durable, Approved, ProposalVisible, ProposalSlot,
     ConsensusBarrier, Collecting, CustodyLane,
     CustodyReady > 0, RelayLane}.

custody_projection(
  #view{approved_author_seqs = ApprovedAuthorSeqs,
        relay_pending_count = RelayPendingCount},
  IngressKey) ->
    {IngressKey, ApprovedAuthorSeqs, RelayPendingCount}.

view_from_facts(Facts, Previous) ->
    %% Preserve the ordering-layer contract: proposer rotation is over the
    %% sorted validator set. Reuse the tuple/set when only another route fact
    %% changed; collecting count/bytes changes on every accepted transaction.
    ValidatorSource = maps:get(validators, Facts),
    {Validators, ValidatorSet} =
        canonical_validators(ValidatorSource, Previous),
    #view{
       self = maps:get(self, Facts),
       capability = maps:get(capability, Facts),
       committee_id = maps:get(committee_id, Facts),
       validator_source = ValidatorSource,
       validators = Validators,
       validator_set = ValidatorSet,
       durable_head = maps:get(durable_head, Facts),
       approved = maps:get(approved, Facts),
       proposal_visible = maps:get(proposal_visible, Facts),
       proposal_slot = maps:get(proposal_slot, Facts),
       consensus_barrier = maps:get(consensus_barrier, Facts),
       approved_author_seqs = maps:get(approved_author_seqs, Facts),
       collecting = maps:get(collecting, Facts),
       custody_lane = maps:get(custody_lane, Facts),
       custody_ready = maps:get(custody_ready, Facts),
       relay_lane = maps:get(relay_lane, Facts),
       relay_pending_count =
           maps:get(relay_pending_count, Facts)}.

canonical_validators(
  ValidatorSource,
  #view{validator_source = ValidatorSource,
        validators = Validators,
        validator_set = ValidatorSet}) ->
    {Validators, ValidatorSet};
canonical_validators(ValidatorSource, _Previous) ->
    Sorted = lists:sort(ValidatorSource),
    {list_to_tuple(Sorted), maps:from_keys(Sorted, true)}.
