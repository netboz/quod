-module(quod_foreign_log).
-moduledoc """
Node-wide verifier/cache for foreign certified DTX references.

The owner is intentionally separate from every hosted namespace.  It selects
from certified directory/history routes, caller-supplied historical routes,
and authenticated contacts learned from peers. Callers may also name one
explicit authenticated route. The owner admits an exact certified reference,
then a monitored worker pulls the existing catch-up page format over an identity-pinned
connection.  The worker folds the history from the caller-pinned
`{Namespace, GenesisAnchor}` through `quod_catchup`; no route, peer response,
cache checkpoint, or reference field is trusted by itself.
Success additionally requires that `PeerKey` belongs to the committee in the
verified post-reference-slot projection; a directory `validator` label is only
a candidate hint.  A non-member is a retryable route failure, never proof that
the certified reference itself is invalid.

The same owner also derives a certificate-verified current committee view for
an anchored identity. `quod_dtx_current_view` uses that frozen view to select
distinct current validator keys and to bind outcome/application probes to one
committee id and minimum slot. Routes remain transport hints and never become
committee evidence.

`verify/5`, `verify_reference/3`, and the current-view APIs are synchronous only from the caller's
perspective. The gen_server never waits for network, disk replay, certificate
verification, or crypto; DTX validation callers invoke them from their existing
asynchronous verdict/recovery worker boundary.

Long-lived ontology follows are another consumer of this same owner and cache.
They add no verifier or history path: a short monitored verification worker
advances at most one certified page, and one unregistered materializer folds
only the already-persisted cache through `quod_committed_projection`. Normal
progress is message-driven: the initial attachment, exact directory-route
events, local finalized commits, authenticated feed block/digest frames, Root
replay readiness, and explicit consumer refresh wake one coalesced job. Commit
and feed messages are freshness hints only; the ordinary certified follow
remains the sole authority.
For each certified current target validator, the owner maintains one volatile,
identity-bound feed registration. Height-only wakes acknowledge freshness and
release the existing certified follower; they carry no facts or authority and
never alter either ontology's Brahms view. There is no per-follow poll or
retry-backoff ladder.

Exact and current routed verification uses this same owner and its one
per-identity queue. A row with no usable route stays parked under its original
caller deadline. Exact directory/feed progress and a newly verified resident
cache release it; a later row with a request-scoped contact may run past it.
No endpoint becomes authority or retained configuration, and no retry timer is
used to discover that progress.

There is no numeric limit on foreign identities, follows, encoded cache, or
materialized projections. An inactive identity retains its bounded current
projection only after this running owner has verified it. Ledger handles,
phase indexes, workers, and catch-up channels remain active only for proof or
follow work. A current-view row, once watched, keeps its existing committee
feed registrations open so unchanged requests can reuse that verified
projection; any missing or newer height returns to the ordinary verifier.
After an owner restart, the first use replays and verifies the disk cache
before that projection can be reused in memory.
""".

-behaviour(gen_server).

-include("quod_ledger.hrl").
-include("quod_proof_limits.hrl").
-include("quod_directory_limits.hrl").
-include("quod_transport_limits.hrl").

-export([start_link/0, start_link/1,
         verify/5, verify_reference/3, verify_local/4,
         verify_reference/4, verify_reference/5,
         verify_current/3,
         current/3, current/4,
         observe_candidate/2, route_hints/2, valid_route_candidates/1,
         follow/1, refresh/1, ack/2, unfollow/1,
         required_references/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([cache_namespace/1, valid_projection/2, test_coalesce_notice/2,
         test_resident_projection/5,
         test_install_feed_registration/5,
         test_install_feed_opening/5,
         test_install_feed_projection/3,
         test_corrupt_resident_height/3]).
-endif.

-define(KEY, {foreign_log, node}).
-define(DEFAULT_PAGE_TIMEOUT_MS, 8000).
-define(MANIFEST, "identity.term").
-define(CHECKPOINT, "checkpoint.term").
-define(LOG, "log.0001").
-define(CACHE_VERSION, 2).
-define(MAX_UINT64, 16#FFFFFFFFFFFFFFFF).
-define(MAX_TIMER_MS, 16#FFFFFFFF).
-define(MANIFEST_RESERVE_BYTES, 4096).
-define(MAX_CURRENT_ROUTE_HINTS, (2 * ?MAX_VALIDATORS)).
-define(MAX_CHANGED_HEADS, ?QUOD_MAX_PLAN_DIFF_OPS).

-record(consumer, {
          pid :: pid(),
          mref :: reference(),
          outstanding = none :: none | {reference(), term()},
          pending = none :: none | term()
         }).

-record(materializer, {
          pid :: pid(),
          mref :: reference(),
          generation :: reference(),
          height = 0 :: non_neg_integer(),
          projection_id = none :: none | <<_:256>>,
          memory_bytes = 0 :: non_neg_integer()
         }).

-record(queued_request, {
          ref :: reference(),
          from = none :: none |
                  {follow, {binary(), <<_:256>>}, reference()},
          callers = #{} :: #{gen_server:from() => reference()},
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          work :: term(),
          fetch_fun :: undefined | function(),
          work_timeout_ms :: pos_integer(),
          parked = false :: boolean(),
          enqueued_native :: integer()
         }).

%% A routed request keeps only the caller's bounded, untrusted hints and the
%% semantic verification it asked for.  Routes are selected again by this
%% owner when work becomes runnable; a parked row therefore cannot fossilise
%% an endpoint or create a second route registry.
-record(routed_work, {
          supplied = [] :: [{<<_:256>>, term()}],
          contact = none :: none | {<<_:256>>, term()},
          kind :: term()
         }).

-record(history, {
          identity :: {binary(), <<_:256>>},
          cache_ns :: binary(),
          height = 0 :: non_neg_integer(),
          bytes = 0 :: non_neg_integer(),
          projection = undefined :: undefined | map(),
          resident_verified = false :: boolean(),
          phase_session = none :: none | term(),
          cache_session = none :: none | quod_ledger_store:session(),
          channel_open = false :: boolean(),
          waiting = {[], []} :: term(),
          last_used = 0 :: integer(),
          active = none :: none | reference(),
          consumers = #{} :: #{reference() => #consumer{}},
          follow_token = none :: none | reference(),
          follow_inflight = false :: boolean(),
          follow_dirty = false :: boolean(),
          progress_signals_open = false :: boolean(),
          current_watch = none :: none | remote,
          current_reference = none :: none | quod_dtx:certified_ref(),
          materializer = none :: none | #materializer{},
          last_probe_ms = 0 :: integer(),
          last_advance_ms = 0 :: integer(),
          hinted_height = unknown :: unknown | non_neg_integer(),
          current_view = unconfirmed :: confirmed | unconfirmed,
          projection_state = building :: building | ready,
          projection_wait = none :: none | network_identity,
          reachability = unknown :: reachable | unknown | {unreachable, term()},
          bootstrap_hints = [] :: [{<<_:256>>, term()}]
         }).

-record(request, {
          from = none :: none |
                  {follow, {binary(), <<_:256>>}, reference()},
          callers = #{} :: #{gen_server:from() => reference()},
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          work :: term(),
          worker :: pid(),
          mref :: reference(),
          timer = none :: none | reference()
         }).

-record(pull, {
          from :: gen_server:from(),
          request_ref :: reference(),
          peer :: <<_:256>>,
          timer :: reference()
         }).

%% One source-owned registration on the target ontology's existing feed
%% channel.  It carries only volatile reachability and a correlated height
%% wake; certified history remains owned by this module's ordinary follower.
%% `remaining` is the already-certified endpoint fallback list for the one
%% current opening attempt.  Exhaustion parks the row until a real route or
%% certified-history event asks reconciliation to try the then-current view.
-record(feed_registration, {
          identity :: {binary(), <<_:256>>},
          peer :: <<_:256>>,
          registration_id :: <<_:128>>,
          current_endpoint = none :: none | term(),
          remaining = [] :: [term()],
          open_ref = none :: none | reference(),
          link = none :: none | pid(),
          mref = none :: none | reference(),
          registered = false :: boolean(),
          height = unknown :: unknown | non_neg_integer()
         }).

-record(s, {
          root :: file:filename_all(),
          fetch_fun = undefined :: undefined | function(),
          page_timeout_ms = ?DEFAULT_PAGE_TIMEOUT_MS :: pos_integer(),
          pending = #{} :: #{reference() => #request{}},
          pulls = #{} :: #{reference() => #pull{}},
          histories = #{} :: #{{binary(), binary()} => #history{}},
          follows = #{} :: #{reference() => {binary(), <<_:256>>}},
          %% Unverified, TLS-authenticated transport contacts are small P
          %% hints. They survive releasing an inactive decoded history, but
          %% are never durable evidence and never carry a projection.
          bootstrap = #{} :: #{{binary(), binary()} => [{<<_:256>>, term()}]},
          total_bytes = 0 :: non_neg_integer(),
          projection_bytes = 0 :: non_neg_integer(),
          follow_wakes = 0 :: non_neg_integer(),
          follow_pages = 0 :: non_neg_integer(),
          follow_entries = 0 :: non_neg_integer(),
          follow_bytes = 0 :: non_neg_integer(),
          follow_coalesced = 0 :: non_neg_integer(),
          follow_resnapshots = 0 :: non_neg_integer(),
          projection_rebuilds = 0 :: non_neg_integer(),
          max_follow_lag = 0 :: non_neg_integer(),
          bootstrap_accepted = 0 :: non_neg_integer(),
          bootstrap_rejected = 0 :: non_neg_integer(),
          bootstrap_evicted = 0 :: non_neg_integer(),
          channels = #{} :: #{binary() => {binary(), pos_integer()}},
          progress_channels = #{} ::
              #{binary() => {binary(), pos_integer()}},
          feed_registrations = #{} ::
              #{{{binary(), <<_:256>>}, <<_:256>>} =>
                    #feed_registration{}},
          feed_registration_openings = #{} ::
              #{reference() => {{binary(), <<_:256>>}, <<_:256>>}},
          feed_registration_monitors = #{} ::
              #{reference() => {{binary(), <<_:256>>}, <<_:256>>}},
          transport_monitor :: reference()
         }).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(application:get_env(quod, foreign_log, #{})).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Verify one exact foreign DTX reference through one explicit source.

This is the low-level exact-source form used for isolated verification and
adversarial checks. Normal DTX recovery uses `verify_reference/3`, which
selects and rotates sources inside this owner. Both forms use the same cache,
history fold, certificate checks, and resource accounting.
""".
-spec verify(<<_:256>>, term(), quod_dtx:certified_ref(),
             transaction | 'begin' | prepare | decision | finalize | complete,
             pos_integer()) ->
          {ok, map()} | {error, term()}.
verify(PeerKey, Endpoint, Ref, ExpectedPhase, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid, {verify, PeerKey, Endpoint, Ref, ExpectedPhase,
                        TimeoutMs}, TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify(_PeerKey, _Endpoint, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Verify one exact foreign DTX reference through the shared source selector.

Certified directory routes, certified history routes, and bounded authenticated
bootstrap candidates are transport hints only.  The existing history verifier
still proves the exact anchor, phase, certificate chain, and serving committee.
""".
-spec verify_reference(quod_dtx:certified_ref(),
                       transaction | 'begin' | prepare | decision | finalize | complete,
                       pos_integer()) -> {ok, map()} | {error, term()}.
verify_reference(Ref, ExpectedPhase, TimeoutMs) ->
    verify_reference(Ref, ExpectedPhase, none, TimeoutMs).

-doc """
Verify one exact reference with an authenticated request-scoped contact.

The contact is preferred only by this verification job. It is not inserted
into bootstrap state; a caller may retain it separately only after this
verification succeeds.
""".
-spec verify_reference(quod_dtx:certified_ref(),
                       transaction | 'begin' | prepare | decision | finalize | complete,
                       none | {<<_:256>>, term()}, pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_reference(Ref, ExpectedPhase, Contact, TimeoutMs) ->
    verify_reference(Ref, ExpectedPhase, Contact, none, TimeoutMs).

-doc """
Verify one exact reference with optional committed-entry acceleration material.

`EntryHint` is never authority.  A bounded entry is offered to the same
anchored history fold and exact reference checker as a fetched entry.  Bad or
unrelated material is ignored and ordinary certified fetching remains the
correctness path.
""".
-spec verify_reference(quod_dtx:certified_ref(),
                       transaction | 'begin' | prepare | decision | finalize | complete,
                       none | {<<_:256>>, term()}, none | #entry{},
                       pos_integer()) -> {ok, map()} | {error, term()}.
verify_reference(Ref, ExpectedPhase, Contact, EntryHint0, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_request_contact(Contact) of
        true ->
            EntryHint = normalize_entry_hint(EntryHint0),
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid,
                          {verify_reference, Ref, ExpectedPhase, Contact,
                           EntryHint, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        false ->
            {error, bad_foreign_reference}
    end;
verify_reference(_Ref, _ExpectedPhase, _Contact, _EntryHint, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Remember one TLS-authenticated node contact as an untrusted source candidate.

The call is asynchronous so an ingress statem never blocks on cache ownership.
It grants no ontology role and is useful only if later certified history from
that endpoint proves the exact supplied identity.
""".
-spec observe_candidate({binary(), <<_:256>>}, {<<_:256>>, term()}) -> ok.
observe_candidate(Identity, {PeerKey, Endpoint}) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {observe_candidate, Identity,
                                  PeerKey, Endpoint});
        undefined ->
            ok
    end;
observe_candidate(_Identity, _Contact) ->
    ok.

-doc """
Return the route-hint view for one exact ontology identity.

`Supplied` may contain already-certified historical route candidates from a
caller. It uses the same keyed, ordered endpoint-list representation returned
by this function and by current-view evidence. It is merged inside the
foreign-log owner with directory, cached-history, and authenticated bootstrap
hints; no caller should reimplement that merge. Before a committee is
certified, each result row contains one discovery endpoint.
After certification, each row contains at most two ordered endpoints: a
first-party live contact, its certified historical fallback, or—only when no
certified endpoint exists—a supplied discovery fallback.
""".
-spec route_hints({binary(), <<_:256>>}, [{<<_:256>>, [term()]}]) ->
          {ok, [{<<_:256>>, [term()]}]} |
          {error, unavailable | anchor_conflict | invalid_request}.
route_hints(Identity, Supplied) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, {route_hints, Identity, Supplied}, 1000)
            catch exit:_ -> {error, unavailable}
            end;
        undefined ->
            {error, unavailable}
    end.

-doc "Validate the one bounded keyed route-candidate representation.".
-spec valid_route_candidates(term()) -> boolean().
valid_route_candidates(Routes) ->
    case normalize_route_candidates(Routes) of
        {ok, _Normalized} -> true;
        error -> false
    end.

-doc """
Verify one exact reference against a co-hosted namespace's durable ledger.

When the caller supplies an immutable snapshot of its already-open committed
store and its current verified projection, a reference certified by that same
committee is read and checked directly. A reference from an older committee
era falls back to the same lazy cache and forward verifier as `verify/5`; its
pages come from `LedgerRoot` instead of the network and no route-peer membership
claim is needed. Returned committee and committee id are fixed by the referenced
slot. Validator routes are reachability hints from that committee era, never
authority.
""".
-spec verify_local(file:filename_all() |
                   #{ledger_root := file:filename_all(),
                     snapshot := quod_ledger_store:session(),
                     projection := quod_simplex:history_projection()},
                   quod_dtx:certified_ref(),
                   entry | transaction | 'begin' | prepare | decision |
                   finalize | complete,
                   pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_local(
  #{ledger_root := LedgerRoot, snapshot := Snapshot,
    projection := Projection},
  Ref, ExpectedPhase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case ExpectedPhase of
        entry ->
            verify_resident_or_historical_local_entry(
              LedgerRoot, Snapshot, Ref, ExpectedPhase, TimeoutMs, Projection);
        transaction ->
            verify_resident_or_historical_local_entry(
              LedgerRoot, Snapshot, Ref, ExpectedPhase, TimeoutMs, Projection);
        _ControlPhase ->
            %% Control evidence also carries the exact historical DTX
            %% generation. Keep it on the phase-index-backed verifier.
            verify_local(LedgerRoot, Ref, ExpectedPhase, TimeoutMs)
    end;
verify_local(LedgerRoot, Ref, ExpectedPhase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(
                  Pid,
                  {verify_local, LedgerRoot, Ref, ExpectedPhase, TimeoutMs},
                  TimeoutMs + 1000)
            catch exit:_ -> {error, retry}
            end;
        undefined ->
            {error, retry}
    end;
verify_local(_LedgerRoot, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

verify_resident_or_historical_local_entry(
  LedgerRoot, Snapshot, Ref, ExpectedPhase, TimeoutMs, Projection) ->
    case verify_resident_local_entry(
           Snapshot, Ref, ExpectedPhase, Projection) of
        {error, historical_committee} ->
            verify_local(LedgerRoot, Ref, ExpectedPhase, TimeoutMs);
        Result ->
            Result
    end.

%% A local consensus owner has already verified the complete durable prefix.
%% The commit certificate check below establishes that the referenced entry
%% belongs to its current committee era; only that case may reuse the current
%% projection.  Older eras retain the full historical verifier above.
verify_resident_local_entry(Snapshot, Ref, ExpectedPhase, Projection) ->
    case quod_dtx:certified_ref_binding(Ref) of
        {ok, Identity = {Ns, Anchor}, Slot, _Digest} ->
            case valid_projection(Projection, Identity) of
                true ->
                    verify_resident_local_snapshot(
                      Snapshot, Slot, Ns, Anchor, Ref, ExpectedPhase,
                      Projection);
                false ->
                    {error, bad_foreign_reference}
            end;
        error ->
            {error, bad_foreign_reference}
    end.

verify_resident_local_snapshot(
  Snapshot, Slot, Ns, Anchor, Ref, ExpectedPhase, Projection) ->
    case quod_ledger_store:open_ro_snapshot(Snapshot) of
        {ok, Store} ->
            try
                case quod_ledger_store:read_at(Store, Slot) of
                    {ok, #entry{index = Slot} = Entry} ->
                        verify_resident_local_entry_cert(
                          Ns, Anchor, Ref, ExpectedPhase,
                          Entry, Projection);
                    not_found ->
                        {error, retry}
                end
            after
                quod_ledger_store:close(Store)
            end;
        {error, _Unavailable} ->
            {error, retry}
    end.

verify_resident_local_entry_cert(
  _Ns, _Anchor, Ref, ExpectedPhase,
  #entry{index = 1, cert = none} = Entry, Projection) ->
    verify_exact_reference_entry(Ref, ExpectedPhase, Entry, Projection);
verify_resident_local_entry_cert(
  Ns, Anchor, Ref, ExpectedPhase,
  #entry{cert = #cert{} = Cert} = Entry, Projection) ->
    Committee = quod_simplex:history_committee(Projection),
    Domain = quod_simplex:consensus_domain(Ns, Anchor),
    case quod_simplex:verify_cert(Domain, Cert, Committee) of
        true ->
            verify_exact_reference_entry(
              Ref, ExpectedPhase, Entry, Projection);
        false ->
            {error, historical_committee}
    end;
verify_resident_local_entry_cert(
  _Ns, _Anchor, _Ref, _ExpectedPhase, _Entry, _Projection) ->
    {error, historical_committee}.

-doc """
Return one quorum-corroborated certified view at or after `FinalizeRef`.

`Routes` are identity-pinned fetch hints, never committee evidence.  The
worker verifies the exact Finalize, takes one bounded snapshot of the available
next page, folds only the longest certificate-valid prefix observed in that
snapshot, then requires a full quorum of distinct keys in the resulting
committee to report a durable height at least as high.  Content appended after
the snapshot is deliberately not chased; an applied-status committee-id
mismatch makes the caller take another snapshot.

Each key owns one ordered endpoint list. Fallback stays inside that key's
worker and the same request deadline; endpoints never become extra voters.
The returned current-view evidence names these hints `route_candidates`;
exact phase evidence keeps its distinct certified `routes` map.
""".
-spec verify_current([{<<_:256>>, [term()]}], quod_dtx:certified_ref(),
                     pos_integer()) ->
          {ok, map()} | {error, term()}.
verify_current(Routes0, Ref, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case normalize_route_candidates(Routes0) of
        {ok, [_ | _] = Routes} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {verify_current, Routes, Ref, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        error ->
            {error, bad_foreign_reference}
    end;
verify_current(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Return one certificate-verified current committee view for an anchored identity.

Unlike `verify_current/3`, this form has no phase reference to establish first.
It starts from the pinned genesis anchor, advances the shared lazy history
cache through certified entries, then requires a full quorum of the resulting
committee to corroborate the captured durable height.  Supplied routes remain
identity-pinned fetch hints only.

Before genesis is certified, candidates retain discovery order. Afterwards
only certified committee keys remain, with live first-party reachability ahead
of the certified historical endpoint for the same key. The returned view uses
`route_candidates`, distinct from exact phase evidence's certified `routes`.
""".
-spec current([{<<_:256>>, [term()]}], {binary(), <<_:256>>}, pos_integer()) ->
          {ok, map()} | {error, term()}.
current(Routes, Identity, TimeoutMs) ->
    current(Routes, Identity, none, TimeoutMs).

-doc """
Return one certified current view using a request-scoped authenticated contact.

`Contact` is the TLS peer and endpoint carrying the current request. It is
preferred for this verification job but is not stored as a bootstrap hint.
Only successfully verified history becomes reusable state.
""".
-spec current([{<<_:256>>, [term()]}], {binary(), <<_:256>>},
              none | {<<_:256>>, term()}, pos_integer()) ->
          {ok, map()} | {error, term()}.
current(Routes0, Identity, Contact, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case {normalize_route_candidates(Routes0), valid_identity(Identity),
          valid_request_contact(Contact)} of
        {{ok, [_ | _] = Routes}, true, true} ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(
                          Pid, {current, Routes, Identity, Contact, TimeoutMs},
                          TimeoutMs + 1000)
                    catch exit:_ -> {error, retry}
                    end;
                undefined ->
                    {error, retry}
            end;
        _ ->
            {error, bad_foreign_reference}
    end;
current(_Routes, _Identity, _Contact, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc "Start one monitored consumer of the shared certified target projection.".
-spec follow({binary(), <<_:256>>}) ->
          {ok, reference()} |
          {error, invalid_identity | unavailable}.
follow(Identity) ->
    case valid_identity(Identity) of
        true ->
            case quod_reg:where(?KEY) of
                Pid when is_pid(Pid) ->
                    try gen_server:call(Pid, {follow, Identity}, 1000)
                    catch exit:_ -> {error, unavailable}
                    end;
                undefined ->
                    {error, unavailable}
            end;
        false ->
            {error, invalid_identity}
    end.

-doc "Request an immediate certified refresh for one follow owned by this process.".
-spec refresh(reference()) -> ok.
refresh(FollowRef) when is_reference(FollowRef) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {refresh, FollowRef, self()});
        undefined ->
            ok
    end;
refresh(_FollowRef) ->
    ok.

-doc "Acknowledge completion of one exact local follow notice.".
-spec ack(reference(), reference()) -> ok.
ack(FollowRef, NoticeRef)
  when is_reference(FollowRef), is_reference(NoticeRef) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, {ack, FollowRef, NoticeRef, self()});
        undefined -> ok
    end;
ack(_FollowRef, _NoticeRef) ->
    ok.

-doc "Remove one exact follow owned by the calling consumer.".
-spec unfollow(reference()) -> ok.
unfollow(FollowRef) when is_reference(FollowRef) ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, {unfollow, FollowRef}, 1000)
            catch exit:_ -> ok
            end;
        undefined -> ok
    end;
unfollow(_FollowRef) ->
    ok.

-ifdef(TEST).
test_install_feed_registration(Pid, Identity, Peer, Link, RegistrationId)
  when is_pid(Pid), is_pid(Link), is_binary(RegistrationId),
       byte_size(RegistrationId) =:= 16 ->
    gen_server:call(
      Pid,
      {test_install_feed_registration,
       Identity, Peer, Link, RegistrationId}).

test_install_feed_opening(Pid, Identity, Peer, RegistrationId, OpenRef)
  when is_pid(Pid), is_binary(RegistrationId),
       byte_size(RegistrationId) =:= 16, is_reference(OpenRef) ->
    gen_server:call(
      Pid,
      {test_install_feed_opening,
       Identity, Peer, RegistrationId, OpenRef}).

test_install_feed_projection(Pid, Identity, Projection)
  when is_pid(Pid), is_map(Projection) ->
    gen_server:call(
      Pid, {test_install_feed_projection, Identity, Projection}).

test_corrupt_resident_height(Pid, Identity, Height)
  when is_pid(Pid), is_integer(Height), Height >= 0 ->
    gen_server:call(Pid, {test_corrupt_resident_height, Identity, Height}).
-endif.

-doc """
Return every foreign reference carried by one decoded DTX control or record.

This is the exhaustive pure seam used before a validator calls
`quod_dtx:preview_batch/3`/`reduce_batch/3`; a future control kind cannot silently inherit
an empty foreign-check set.  Row order is the control's canonical target order.
""".
-spec required_references(quod_dtx:control() | quod_dtx:control_record()) ->
          {ok, [{'begin' | prepare | decision | finalize,
                 quod_dtx:certified_ref()}]} |
          {error, invalid_control}.
required_references(ControlOrRecord) ->
    try
        case quod_dtx:record_kind(ControlOrRecord) of
            invalid ->
                required_references(
                  quod_dtx:control_kind(ControlOrRecord),
                  quod_dtx:control_body(ControlOrRecord));
            Kind ->
                required_references(Kind, ControlOrRecord)
        end
    catch
        error:function_clause -> {error, invalid_control};
        error:{badmatch, _} -> {error, invalid_control}
    end.

required_references('begin', _Begin) ->
    {ok, []};
required_references(
  prepare,
  {quod_dtx_prepare, 3, _GroupId, BeginRef, _Manifest,
   _PlanDigest, _PlanBlob}) ->
    checked_references([{'begin', BeginRef}]);
required_references(
  decision,
  {quod_dtx_decision, 3, _GroupId, BeginRef, _Verdict, Rows, _Reasons}) ->
    %% A source-fused Begin is also the source participant's Prepare.  The
    %% Decision row names that same BeginRef, but it is one certified entry and
    %% the semantic chain consumes it from the leading Begin evidence.  Keep
    %% the exact foreign-reference set canonical by omitting that duplicate
    %% row here; every other participant still contributes its Prepare ref.
    case reference_rows(Rows, prepare, BeginRef, 0, []) of
        {ok, References} ->
            checked_references([{'begin', BeginRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(
  finalize,
  {quod_dtx_finalize, 3, _GroupId, DecisionRef, _Verdict,
   PrepareRef, _Generation}) ->
    Tail = case PrepareRef of none -> []; _ -> [{prepare, PrepareRef}] end,
    checked_references([{decision, DecisionRef} | Tail]);
required_references(
  complete,
  {quod_dtx_complete, 3, _GroupId, DecisionRef, Rows}) ->
    %% Source fusion has the same shape at completion: the source Decision
    %% applies the source plan, so that DecisionRef is also the source's
    %% Finalize ref.  Keep it once as the leading Decision evidence.
    case finalize_rows(Rows, DecisionRef, 0, []) of
        {ok, References} ->
            checked_references([{decision, DecisionRef} | References]);
        error ->
            {error, invalid_control}
    end;
required_references(_Kind, _Record) ->
    {error, invalid_control}.

reference_rows([], _Phase, _SkipRef, _Count, Acc) ->
    {ok, lists:reverse(Acc)};
reference_rows([{Identity, Ref} | Rest], Phase, SkipRef, Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS ->
    case ref_identity(Ref) of
        Identity when Ref =:= SkipRef ->
            reference_rows(Rest, Phase, SkipRef, Count + 1, Acc);
        Identity ->
            reference_rows(
              Rest, Phase, SkipRef, Count + 1, [{Phase, Ref} | Acc]);
        _ -> error
    end;
reference_rows(_, _Phase, _SkipRef, _Count, _Acc) -> error.

finalize_rows([], _SkipRef, _Count, Acc) -> {ok, lists:reverse(Acc)};
finalize_rows([{Identity, Ref, Generation} | Rest], SkipRef, Count, Acc)
  when Count < ?QUOD_MAX_DTX_PARTICIPANTS,
       is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 ->
    case ref_identity(Ref) of
        Identity when Ref =:= SkipRef ->
            finalize_rows(Rest, SkipRef, Count + 1, Acc);
        Identity ->
            finalize_rows(
              Rest, SkipRef, Count + 1, [{finalize, Ref} | Acc]);
        _ -> error
    end;
finalize_rows(_, _SkipRef, _Count, _Acc) -> error.

checked_references(References) ->
    case lists:all(
           fun({_Phase, Ref}) -> quod_dtx:validate_certified_ref(Ref) end,
           References) of
        true -> {ok, References};
        false -> {error, invalid_control}
    end.

-spec stats() -> map().
stats() ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            try gen_server:call(Pid, stats)
            catch exit:_ -> empty_stats()
            end;
        undefined -> empty_stats()
    end.

empty_stats() ->
    #{pending => 0, queued => 0, pulls => 0, histories => 0, channels => 0,
      feed_registrations => 0,
      resident_verified => 0,
      cache_bytes => 0,
      follow_consumers => 0, followed_histories => 0,
      projection_workers => 0, projection_bytes => 0,
      follow_building => 0, follow_unreachable => 0,
      follow_wakes => 0, follow_pages => 0,
      follow_entries => 0, follow_bytes => 0, follow_coalesced => 0,
      follow_resnapshots => 0,
      projection_rebuilds => 0, max_follow_lag => 0}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Root = maps:get(
             cache_dir, Opts,
             filename:join(
               quod_ledger_store:default_data_dir(), "foreign-log")),
    FetchFun = maps:get(fetch_fun, Opts, undefined),
    PageTimeout = maps:get(page_timeout_ms, Opts, ?DEFAULT_PAGE_TIMEOUT_MS),
    case valid_options(Root, FetchFun, PageTimeout) of
        true ->
            %% Materialized projections are rebuildable P state. A normal
            %% worker shutdown removes its generation directory; clearing the
            %% dedicated parent here also reclaims anything left by an
            %% untrappable kill before this owner restarted.
            cleanup_projection_dirs(Root),
            true = quod_reg:subscribe({runtime, quod_ontology:root_ns()}),
            TransportMonitor = quod_reg:monitor_name({transport, node}, follow),
            S0 = #s{root = Root, fetch_fun = FetchFun,
                    page_timeout_ms = PageTimeout,
                    transport_monitor = TransportMonitor},
            {ok, S0};
        false ->
            {stop, bad_foreign_log_config}
    end.

valid_options(Root, FetchFun, PageTimeout) ->
    (is_list(Root) orelse is_binary(Root)) andalso
        (FetchFun =:= undefined orelse is_function(FetchFun, 5)) andalso
        is_integer(PageTimeout) andalso PageTimeout > 0 andalso
        PageTimeout =< ?MAX_TIMER_MS - 1000.

cleanup_projection_dirs(Root) ->
    _ = file:del_dir_r(filename:join(Root, "projections")),
    ok.

handle_call(stats, _From, S) ->
    Followed = [H || H <- maps:values(S#s.histories),
                     map_size(H#history.consumers) > 0],
    Reply = #{pending => map_size(S#s.pending),
              queued => lists:sum(
                          [queue:len(Q) || #history{waiting = Q} <-
                                               maps:values(S#s.histories)]),
              pulls => map_size(S#s.pulls),
              histories => map_size(S#s.histories),
              channels => map_size(S#s.channels),
              feed_registrations => length(
                                      [ok || #feed_registration{
                                                registered = true} <-
                                                   maps:values(
                                                     S#s.feed_registrations)]),
              resident_verified => length(
                                     [ok || #history{
                                                resident_verified = true} <-
                                                maps:values(S#s.histories)]),
              cache_bytes => S#s.total_bytes,
              follow_consumers => map_size(S#s.follows),
              followed_histories => length(Followed),
              projection_workers => length(
                                      [ok || #history{materializer = M} <- Followed,
                                             M =/= none]),
              projection_bytes => S#s.projection_bytes,
              follow_building => length(
                                   [ok || #history{projection_state = building} <-
                                              Followed]),
              follow_unreachable => length(
                                      [ok || #history{
                                               reachability =
                                                   {unreachable, _}} <- Followed]),
              follow_wakes => S#s.follow_wakes,
              follow_pages => S#s.follow_pages,
              follow_entries => S#s.follow_entries,
              follow_bytes => S#s.follow_bytes,
              follow_coalesced => S#s.follow_coalesced,
              follow_resnapshots => S#s.follow_resnapshots,
              projection_rebuilds => S#s.projection_rebuilds,
              max_follow_lag => S#s.max_follow_lag,
              bootstrap_candidates => bootstrap_candidate_count(S),
              bootstrap_accepted => S#s.bootstrap_accepted,
              bootstrap_rejected => S#s.bootstrap_rejected,
              bootstrap_evicted => S#s.bootstrap_evicted},
    {reply, Reply, S};
handle_call({follow, Identity}, From, S0) ->
    {ConsumerPid, _Tag} = From,
    {FollowRef, S1} = add_follow(Identity, ConsumerPid, S0),
    {reply, {ok, FollowRef}, S1};
handle_call({unfollow, FollowRef}, From, S0) ->
    {ConsumerPid, _Tag} = From,
    {reply, ok, remove_follow(FollowRef, ConsumerPid, S0)};
handle_call(
  {verify, Peer, Endpoint, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_route_request(Peer, Endpoint, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_verification(
              Peer, Endpoint, Ref, Phase, TimeoutMs,
              S0#s.fetch_fun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_reference, Ref, Phase, Contact, EntryHint, TimeoutMs}, From, S0) ->
    case validate_reference_request(Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_current_worker(
              Identity, [], Contact, TimeoutMs,
              {exact_reference, Ref, Phase, EntryHint},
              From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call({route_hints, Identity, Supplied}, _From, S0) ->
    case {valid_identity(Identity), normalize_route_candidates(Supplied)} of
        {true, {ok, Normalized}} ->
            S1 = ensure_history(Identity, S0),
            Reply = case selected_route_sources(
                           Identity, flatten_route_candidates(Normalized), S1) of
                        {ok, Sources} ->
                            case route_candidates(Sources) of
                                [_ | _] = Routes -> {ok, Routes};
                                [] -> {error, unavailable}
                            end;
                        {error, anchor_conflict} ->
                            {error, anchor_conflict}
                    end,
            {reply, Reply, hibernate_history(Identity, S1)};
        _ ->
            {reply, {error, invalid_request}, S0}
    end;
handle_call(
  {verify_local, LedgerRoot, Ref, Phase, TimeoutMs}, From, S0) ->
    case validate_local_request(LedgerRoot, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    quod_catchup:serve_blocks(
                      Ns, LedgerRoot, FromIndex, ToIndex)
                end,
            begin_verification(
              LocalPeer, local, Ref, Phase, TimeoutMs,
              FetchFun, Identity, From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {verify_current, Routes, Ref, TimeoutMs}, From, S0) ->
    case validate_current_request(Routes, Ref, TimeoutMs) of
        {ok, Identity} ->
            begin_current_worker(
              Identity, flatten_route_candidates(Routes), TimeoutMs,
              {current_reference, Ref},
              From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {current, Routes, Identity, Contact, TimeoutMs}, From, S0) ->
    case validate_current_identity_request(
           Routes, Identity, TimeoutMs) of
        ok ->
            begin_current_worker(
              Identity, flatten_route_candidates(Routes), Contact, TimeoutMs,
              {current_identity, Identity},
              From, S0);
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(
  {pull_page, RequestRef, Peer, Endpoint, Ns, FromIndex, ToIndex}, From,
  S = #s{fetch_fun = undefined}) ->
    case maps:get(RequestRef, S#s.pending, undefined) of
        #request{identity = {Ns, _Anchor}} ->
            ReqId = make_ref(),
            Timer = erlang:send_after(
                      S#s.page_timeout_ms, self(), {pull_timeout, ReqId}),
            Chan = quod_catchup:channel(Ns),
            Frame = quod_catchup:encode_frame(
                      Ns, {blocks_req, ReqId, FromIndex, ToIndex}),
            ok = quod_quic:send_pinned(Peer, Endpoint, Chan, Frame),
            Pull = #pull{from = From, request_ref = RequestRef,
                         peer = Peer, timer = Timer},
            {noreply, S#s{pulls = (S#s.pulls)#{ReqId => Pull}}};
        _ ->
            {reply, {error, retry}, S}
    end;
handle_call({reserve_page, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case reserve_page(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, retry}, S1}
    end;
handle_call({set_cache_size, RequestRef, Bytes}, _From, S0)
  when is_integer(Bytes), Bytes >= 0 ->
    case set_cache_size(RequestRef, Bytes, S0) of
        {ok, S1} -> {reply, ok, S1};
        {error, S1} -> {reply, {error, retry}, S1}
    end;
handle_call({reset_cache, RequestRef}, _From, S0) ->
    case reset_cache_accounting(RequestRef, S0) of
        {ok, S1} -> {reply, ok, S1};
        error -> {reply, {error, retry}, S0}
    end;
handle_call(Request, From, S) ->
    handle_private_call(Request, From, S).

-ifdef(TEST).
handle_private_call(
  {test_install_feed_registration,
   Identity, <<_:256>> = Peer, Link, <<_:128>> = RegistrationId},
  _From, S0) when is_pid(Link) ->
    Key = {Identity, Peer},
    S1 = close_feed_registration_key(Key, S0),
    MRef = erlang:monitor(process, Link),
    Registration = #feed_registration{
                      identity = Identity, peer = Peer,
                      registration_id = RegistrationId,
                      link = Link, mref = MRef},
    {reply, ok,
     S1#s{
       feed_registrations =
           (S1#s.feed_registrations)#{Key => Registration},
       feed_registration_monitors =
           (S1#s.feed_registration_monitors)#{MRef => Key}}};
handle_private_call(
  {test_install_feed_opening,
   Identity, <<_:256>> = Peer, <<_:128>> = RegistrationId, OpenRef},
  _From, S0) when is_reference(OpenRef) ->
    Key = {Identity, Peer},
    Registration = #feed_registration{
                      identity = Identity, peer = Peer,
                      registration_id = RegistrationId,
                      open_ref = OpenRef},
    {reply, ok,
     S0#s{
       feed_registrations =
           (S0#s.feed_registrations)#{Key => Registration},
       feed_registration_openings =
           (S0#s.feed_registration_openings)#{OpenRef => Key}}};
handle_private_call(
  {test_install_feed_projection, Identity, Projection}, _From, S0) ->
    case valid_identity(Identity) andalso
         valid_projection(Projection, Identity) of
        true ->
            S1 = ensure_history(Identity, S0),
            H0 = maps:get(Identity, S1#s.histories),
            H1 = H0#history{projection = Projection,
                            resident_verified = true},
            {reply, ok, put_history(Identity, H1, S1)};
        false ->
            {reply, {error, bad_projection}, S0}
    end;
handle_private_call(
  {test_corrupt_resident_height, Identity, Height}, _From, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            {reply, ok,
             put_history(Identity, H0#history{height = Height}, S0)};
        undefined ->
            {reply, {error, not_found}, S0}
    end;
handle_private_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.
-else.
handle_private_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.
-endif.

begin_verification(Peer, Endpoint, Ref, Phase, TimeoutMs, FetchFun,
                   Identity, From, S0) ->
    begin_worker(
      Peer, Identity, TimeoutMs,
      {exact, Peer, Endpoint, Ref, Phase}, FetchFun, From, S0).

begin_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case start_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) of
        {ok, S1} -> {noreply, S1}
    end.

begin_current_worker(Identity, Supplied, TimeoutMs, Kind, From, S0) ->
    begin_current_worker(
      Identity, Supplied, none, TimeoutMs, Kind, From, S0).

begin_current_worker(
  Identity, Supplied, Contact, TimeoutMs, Kind, From, S0) ->
    Work = #routed_work{supplied = Supplied, contact = Contact, kind = Kind},
    case start_routed_worker(Identity, TimeoutMs, Work, From, S0) of
        {ok, S1} -> {noreply, S1}
    end.

start_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case join_identical_request(Identity, Work, From, TimeoutMs, S0) of
        {joined, S1} ->
            {ok, S1};
        no ->
            start_distinct_worker(
              Peer, Identity, TimeoutMs, Work, FetchFun, From, S0)
    end.

start_routed_worker(Identity, TimeoutMs, Work, From, S0) ->
    case join_identical_request(Identity, Work, From, TimeoutMs, S0) of
        {joined, S1} ->
            {ok, S1};
        no ->
            start_distinct_routed_worker(
              Identity, TimeoutMs, Work, From, S0)
    end.

start_distinct_routed_worker(Identity, TimeoutMs, Work, From, S0) ->
    S1 = ensure_history(Identity, S0),
    RequestRef = make_ref(),
    {InternalFrom, Callers} = request_owners(RequestRef, From, TimeoutMs),
    Queued = #queued_request{
                ref = RequestRef, from = InternalFrom, callers = Callers,
                peer = none, identity = Identity, work = Work,
                fetch_fun = S1#s.fetch_fun,
                work_timeout_ms = verification_work_timeout(S1),
                enqueued_native = erlang:monotonic_time()},
    case maps:get(Identity, S1#s.histories) of
        #history{active = none} ->
            {ok, start_or_park_routed(Queued, S1)};
        #history{} = H0 ->
            H1 = H0#history{
                   waiting = queue:in(Queued, H0#history.waiting)},
            {ok, put_history(Identity, H1, S1)}
    end.

start_or_park_routed(
  Queued = #queued_request{identity = Identity,
                           work = #routed_work{} = Routed}, S0) ->
    case resolve_routed_work(Identity, Routed, S0) of
        {ready, Peer, WorkerWork} ->
            launch_request_owned(
              Queued#queued_request.ref, Peer, Identity,
              Queued#queued_request.work_timeout_ms,
              Routed, WorkerWork, Queued#queued_request.fetch_fun,
              Queued#queued_request.from, Queued#queued_request.callers, S0);
        wait ->
            H0 = maps:get(Identity, S0#s.histories),
            Parked = Queued#queued_request{parked = true},
            open_progress_signals(
              Identity,
              put_history(
                Identity,
                H0#history{waiting = queue:in(Parked, H0#history.waiting)},
                S0))
    end.

resolve_routed_work(Identity, #routed_work{supplied = Supplied,
                                            contact = Contact,
                                            kind = Kind}, S0) ->
    case selected_route_sources(Identity, Supplied, S0) of
        {ok, Sources0} ->
            Sources = add_request_contact(Contact, Sources0),
            case route_candidates(Sources) of
                [{Peer, _Endpoints} | _] ->
                    {ready, Peer, routed_worker_work(Kind, Sources)};
                [] ->
                    wait
            end;
        {error, anchor_conflict} ->
            wait
    end.

routed_worker_work(
  {exact_reference, Ref, Phase, EntryHint}, Sources) ->
    {exact_routes,
     flatten_route_candidates(route_candidates(Sources)),
     Ref, Phase, EntryHint};
routed_worker_work({current_reference, Ref}, Sources) ->
    {current, Sources, Ref};
routed_worker_work({current_identity, Identity}, Sources) ->
    {current_identity, Sources, Identity}.

start_distinct_worker(
  Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    S1 = ensure_history(Identity, S0),
    WorkTimeout = verification_work_timeout(S1),
    case maps:get(Identity, S1#s.histories) of
        #history{active = none} ->
            RequestRef = make_ref(),
            {ok, launch_request(
                   RequestRef, Peer, Identity, WorkTimeout,
                   Work, FetchFun, From, TimeoutMs, S1)};
        #history{} = H0 ->
            RequestRef = make_ref(),
            {InternalFrom, Callers} = request_owners(
                                        RequestRef, From, TimeoutMs),
            Queued = #queued_request{
                        ref = RequestRef, from = InternalFrom,
                        callers = Callers, peer = Peer,
                        identity = Identity, work = Work,
                        fetch_fun = FetchFun,
                        work_timeout_ms = WorkTimeout,
                        enqueued_native = erlang:monotonic_time()},
            H1 = H0#history{waiting = queue:in(Queued, H0#history.waiting)},
            {ok, put_history(Identity, H1, S1)}
    end.

launch_request(RequestRef, Peer, Identity, WorkTimeout,
               Work, FetchFun, From, CallerTimeout, S0) ->
    {InternalFrom, Callers} = request_owners(
                                RequestRef, From, CallerTimeout),
    launch_request_owned(
      RequestRef, Peer, Identity, WorkTimeout, Work, FetchFun,
      InternalFrom, Callers, S0).

launch_request_owned(RequestRef, Peer, Identity, WorkTimeout,
                     Work, FetchFun, InternalFrom, Callers, S0) ->
    launch_request_owned(
      RequestRef, Peer, Identity, WorkTimeout, Work, Work, FetchFun,
      InternalFrom, Callers, S0).

launch_request_owned(RequestRef, Peer, Identity, WorkTimeout,
                     RequestWork, WorkerWork, FetchFun,
                     InternalFrom, Callers, S0) ->
    case resident_current_identity(WorkerWork, Identity, S0) of
        {ok, Evidence} ->
            cancel_caller_timers(Callers),
            reply_request_callers(maps:keys(Callers), {ok, Evidence}),
            observe_foreign_stage(
              request_current, ok, erlang:monotonic_time()),
            start_next_request(Identity, touch_history(Identity, S0));
        miss ->
            Owner = self(),
            Root = S0#s.root,
            PageTimeout = S0#s.page_timeout_ms,
            Resident = resident_cache(Identity, S0),
            Worker = spawn_opt(
                       fun() ->
                           verification_worker(
                             Owner, RequestRef, WorkerWork, Root, FetchFun,
                             PageTimeout, WorkTimeout, Resident)
                       end,
                       [{max_heap_size,
                         #{size => foreign_worker_heap_words(),
                           kill => true, error_logger => true}}]),
            MRef = erlang:monitor(process, Worker),
            Timer = request_work_timer(InternalFrom, WorkTimeout, RequestRef),
            Request = #request{from = InternalFrom, callers = Callers,
                               peer = Peer, identity = Identity,
                               worker = Worker, work = RequestWork,
                               mref = MRef, timer = Timer},
            H0 = maps:get(Identity, S0#s.histories),
            %% The worker exclusively owns the suspended phase session until
            %% it returns it in verified metadata. A crash therefore leaves
            %% no stale session eligible for reuse.
            H1 = H0#history{active = RequestRef,
                            resident_verified = false,
                            phase_session = none,
                            last_used = quod_time:mono_ms()},
            S0#s{pending = (S0#s.pending)#{RequestRef => Request},
                 histories = (S0#s.histories)#{Identity => H1}}
    end.

verification_work_timeout(S) ->
    %% Shared current/reference work outlives individual callers, so it uses
    %% the foreign owner's existing follow-work bound rather than whichever
    %% caller happened to start or join it first.
    follow_request_timeout(S).

request_owners(_RequestRef, {follow, _, _} = From, _TimeoutMs) ->
    {From, #{}};
request_owners(RequestRef, From, TimeoutMs) ->
    {none, add_request_caller(RequestRef, From, TimeoutMs, #{})}.

add_request_caller(RequestRef, From, TimeoutMs, Callers) ->
    Timer = erlang:send_after(
              TimeoutMs, self(),
              {verification_caller_timeout, RequestRef, From}),
    Callers#{From => Timer}.

request_work_timer({follow, _, _}, WorkTimeout, RequestRef) ->
    erlang:send_after(
      WorkTimeout, self(), {verification_timeout, RequestRef});
request_work_timer(none, _WorkTimeout, _RequestRef) ->
    none.

resident_cache(Identity, #s{histories = Histories}) ->
    case maps:get(Identity, Histories, undefined) of
        #history{height = Height, projection = Projection,
                 resident_verified = true, phase_session = PhaseSession,
                 cache_session = CacheSession}
          when is_map(Projection), PhaseSession =/= none,
               CacheSession =/= none ->
            {verified_session, Height, Projection,
             PhaseSession, CacheSession};
        _ -> none
    end.

%% A current view already certified by this owner remains current while a
%% quorum of the identity's committee keeps an ordered feed registration at
%% that exact height. The registrations are only freshness witnesses: a
%% missing row or any newer height falls through to the ordinary certified
%% fetch and fold below.
resident_current_identity(
  {current_identity, Sources, Identity}, Identity,
  S) ->
    resident_confirmed_current(Sources, Identity, S);
resident_current_identity(
  {current, Sources, Ref}, Identity,
  S = #s{histories = Histories}) ->
    case maps:get(Identity, Histories, undefined) of
        #history{current_reference = Ref} ->
            resident_confirmed_current(Sources, Identity, S);
        _ ->
            miss
    end;
resident_current_identity(_Work, _Identity, _S) ->
    miss.

resident_confirmed_current(Sources, Identity,
                           S = #s{histories = Histories}) ->
    case maps:get(Identity, Histories, undefined) of
        #history{height = Height, projection = Projection,
                 resident_verified = true, phase_session = PhaseSession,
                 current_watch = remote, progress_signals_open = true,
                 current_view = confirmed}
          when Height > 0, is_map(Projection), PhaseSession =/= none ->
            Committee = quod_simplex:history_committee(Projection),
            case Committee of
                [] ->
                    miss;
                [_ | _] ->
                    Needed = quod_simplex:quorum(length(Committee)),
                    Matching = matching_feed_heights(
                                 Identity, Committee, Height,
                                 S#s.feed_registrations),
                    case Matching >= Needed of
                        true ->
                            {ok, current_view_evidence(
                                   Identity, Height, Projection,
                                   current_route_candidates(
                                     Sources, Projection))};
                        false ->
                            miss
                    end
            end;
        _ ->
            miss
    end.

matching_feed_heights(Identity, Committee, Height, Registrations) ->
    length(
      [ok
       || Peer <- Committee,
          #feed_registration{registered = true, height = RegisteredHeight,
                             link = Link} <-
              [maps:get({Identity, Peer}, Registrations, undefined)],
          RegisteredHeight =:= Height,
          is_pid(Link)]).

touch_history(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            put_history(
              Identity, H0#history{last_used = quod_time:mono_ms()}, S0);
        undefined ->
            S0
    end.

retain_current_watch(
  Identity,
  #routed_work{kind = {current_identity, Identity}},
  {ok, #{slot := Height}}, S0) ->
    retain_current_view(Identity, keep, Height, S0);
retain_current_watch(
  Identity,
  #routed_work{kind = {current_reference, Ref}},
  {ok, #{slot := Height}}, S0) ->
    retain_current_view(Identity, Ref, Height, S0);
retain_current_watch(_Identity, _Work, _Result, S0) ->
    S0.

retain_current_view(Identity, Reference, Height, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{height = Height, resident_verified = true} = H0 ->
            View = retained_current_view(Height, H0),
            H1 = H0#history{
                   current_watch = remote,
                   current_reference = retained_current_reference(
                                         Reference, H0),
                   hinted_height = retained_hint(Height, H0),
                   current_view = View},
            open_progress_signals(Identity, put_history(Identity, H1, S0));
        _ ->
            S0
    end.

retained_current_reference(keep, #history{current_reference = Ref}) -> Ref;
retained_current_reference(Ref, #history{}) -> Ref.

retained_hint(Height, #history{hinted_height = Hint})
  when is_integer(Hint) -> max(Height, Hint);
retained_hint(Height, #history{}) -> Height.

retained_current_view(Height, H0) ->
    case retained_hint(Height, H0) > Height of
        true -> unconfirmed;
        false -> confirmed
    end.

%% The certified-history cache has one writer per identity. Concurrent scope
%% opens commonly ask for the same current identity view; their route lists
%% are transport hints, not part of that view, so they share one certified
%% result. Distinct work waits in the owner's FIFO and starts from completion,
%% never from polling. Every caller keeps its original final deadline.
join_identical_request(Identity, Work, From, TimeoutMs,
                       S = #s{histories = Histories, pending = Pending}) ->
    case {normal_caller(From), maps:get(Identity, Histories, undefined)} of
        {true, #history{active = RequestRef} = History}
          when is_reference(RequestRef) ->
            case join_active_request(
                   RequestRef, Work, From, TimeoutMs, Identity, Pending) of
                {joined, Pending1} ->
                    {joined, S#s{pending = Pending1}};
                no ->
                    join_waiting_request(
                      Work, From, TimeoutMs, Identity, History, S)
            end;
        {true, #history{} = History} ->
            join_waiting_request(
              Work, From, TimeoutMs, Identity, History, S);
        _ ->
            no
    end.

join_active_request(RequestRef, Work, From, TimeoutMs, Identity, Pending) ->
    case maps:get(RequestRef, Pending, undefined) of
        Request = #request{from = none, callers = Callers,
                           work = ActiveWork} ->
            case shareable_work(Work, ActiveWork, Identity) of
                true ->
                    {joined,
                     Pending#{RequestRef => Request#request{
                       callers = add_request_caller(
                                   RequestRef, From, TimeoutMs, Callers)}}};
                false ->
                    no
            end;
        _ ->
            no
    end.

join_waiting_request(Work, From, TimeoutMs, Identity,
                     #history{waiting = Waiting0} = History, S) ->
    case join_waiting_item(
           Work, From, TimeoutMs, Identity, queue:to_list(Waiting0)) of
        {joined, Waiting1} ->
            {joined,
             put_history(
               Identity,
               History#history{waiting = queue:from_list(Waiting1)}, S)};
        no ->
            no
    end.

join_waiting_item(_Work, _From, _TimeoutMs, _Identity, []) ->
    no;
join_waiting_item(
  Work, From, TimeoutMs, Identity,
  [#queued_request{ref = RequestRef, from = none,
                   callers = Callers, work = QueuedWork,
                   parked = Parked} = Queued | Rest]) ->
    case shareable_waiting_work(
           Work, QueuedWork, Parked, Identity) of
        true ->
            {joined,
             [Queued#queued_request{
                callers = add_request_caller(
                            RequestRef, From, TimeoutMs, Callers)} | Rest]};
        false ->
            prepend_join_waiting_item(
              Queued,
              join_waiting_item(
                Work, From, TimeoutMs, Identity, Rest))
    end;
join_waiting_item(Work, From, TimeoutMs, Identity, [Queued | Rest]) ->
    prepend_join_waiting_item(
      Queued,
      join_waiting_item(Work, From, TimeoutMs, Identity, Rest)).

prepend_join_waiting_item(Queued, {joined, Rest}) ->
    {joined, [Queued | Rest]};
prepend_join_waiting_item(_Queued, no) ->
    no.

%% Route lists are not semantic identity for an active certified job, but a
%% parked row has no job yet. A later row with a different supplied/contact
%% hint must be allowed to run instead of donating its only route to the
%% older wait.
shareable_waiting_work(
  #routed_work{} = Work, #routed_work{} = Work, true, _Identity) ->
    true;
shareable_waiting_work(
  #routed_work{}, #routed_work{}, true, _Identity) ->
    false;
shareable_waiting_work(Work, QueuedWork, _Parked, Identity) ->
    shareable_work(Work, QueuedWork, Identity).

normal_caller({Pid, _Tag}) when is_pid(Pid) -> true;
normal_caller(_) -> false.

shareable_work(
  #routed_work{contact = Contact, kind = Kind1},
  #routed_work{contact = Contact, kind = Kind2}, Identity) ->
    shareable_routed_kind(Kind1, Kind2, Identity);
shareable_work(Work, Work, _Identity) -> true;
shareable_work(_Work1, _Work2, _Identity) -> false.

shareable_routed_kind(
  {current_identity, Identity}, {current_identity, Identity}, Identity) ->
    true;
shareable_routed_kind(Kind, Kind, _Identity) ->
    true;
shareable_routed_kind(_Kind1, _Kind2, _Identity) ->
    false.

handle_cast({observe_candidate, Identity, PeerKey, Endpoint}, S0) ->
    {noreply, remember_bootstrap_candidate(
                Identity, PeerKey, Endpoint, S0)};
handle_cast({ack, FollowRef, NoticeRef, ConsumerPid}, S0)
  when is_reference(FollowRef), is_reference(NoticeRef), is_pid(ConsumerPid) ->
    {noreply, acknowledge_follow(
                FollowRef, NoticeRef, ConsumerPid, S0)};
handle_cast({refresh, FollowRef, ConsumerPid}, S0)
  when is_reference(FollowRef), is_pid(ConsumerPid) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{pid = ConsumerPid}, _History} ->
            {noreply, wake_follow(Identity, S0)};
        _ ->
            {noreply, S0}
    end;
handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(
  {quod_message, {PeerIdentity, Link}, Chan, Payload}, S) ->
    case quod_link:peer_key(PeerIdentity) of
        undefined -> {noreply, S};
        Peer ->
            case maps:is_key(Chan, S#s.channels) of
                true ->
                    {noreply, handle_catchup_frame(Peer, Chan, Payload, S)};
                false ->
                    {noreply, handle_feed_signal(Peer, Link, Chan, Payload, S)}
            end
    end;
%% The same live-finality edge that drives the local feed is the reliable wake
%% for a co-hosted followed ontology.  The entry itself is never evidence here:
%% every interested identity still advances through the one certified follower.
handle_info({committed, Ns, Slot, #entry{}}, S) ->
    {noreply, wake_namespace_progress(Ns, Slot, S)};
handle_info({certified_head, Ns, Slot}, S) ->
    {noreply, wake_namespace_progress(Ns, Slot, S)};
%% A materializer can discover its Root dependency immediately before or
%% after Root publishes this edge.  The waiting handler below covers the
%% crossed order; this edge resumes every worker already parked on it.
handle_info({replay_ready, _Id, _Height}, S) ->
    {noreply, resume_network_identity_projections(S)};
handle_info({foreign_worker_done, RequestRef, Result, Meta0}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{identity = Identity, work = Work} ->
            Meta = resident_worker_meta(Result, Meta0),
            S1 = install_worker_meta(
                   RequestRef, Meta,
                   record_follow_progress(RequestRef, Meta, S0)),
            S2 = case maps:get(resident_verified, Meta, false) of
                     true -> release_route_waiters(Identity, S1);
                     false -> S1
                 end,
            S3 = retain_current_watch(Identity, Work, Result, S2),
            case {Result, maps:get(RequestRef, S3#s.pending, undefined)} of
                {{error, retry}, #request{work = #routed_work{}}} ->
                    {noreply, park_failed_routed_request(RequestRef, S3)};
                _ ->
                    {noreply, finish_request(RequestRef, Result, S3)}
            end;
        undefined ->
            {noreply, S0}
    end;
handle_info({verification_caller_timeout, RequestRef, From}, S0) ->
    {noreply, expire_request_caller(RequestRef, From, S0)};
handle_info({verification_timeout, RequestRef}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker} ->
            exit(Worker, kill),
            %% Keep this identity active until the monitor confirms that the
            %% cache worker is dead.  Releasing it here could admit a second
            %% writer against the same ledger/checkpoint between `exit/2` and
            %% the eventual DOWN message.
            {noreply, S0};
        undefined ->
            {noreply, S0}
    end;
handle_info({pull_timeout, ReqId}, S0) ->
    case maps:take(ReqId, S0#s.pulls) of
        {#pull{from = From}, Pulls1} ->
            gen_server:reply(From, {error, retry}),
            {noreply, S0#s{pulls = Pulls1}};
        error ->
            {noreply, S0}
    end;
handle_info({follow_refresh, Identity, Token}, S0) ->
    {noreply, begin_follow_refresh(Identity, Token, S0)};
handle_info({directory_route_available, Identity}, S0) ->
    S1 = reconcile_feed_registrations(Identity, S0),
    S2 = release_route_waiters(Identity, S1),
    {noreply, wake_follow_if_route_needed(Identity, S2)};
handle_info(
  {gproc, unreg, Monitor, _Name},
  S0 = #s{transport_monitor = Monitor}) ->
    %% The transport owns every connection and stream.  Its replacement
    %% invalidates both completed links and openings whose cast may have died
    %% in the old owner's mailbox.  Keep only semantic follow/verification
    %% interest; the exact registered edge below rebuilds from current routes.
    {noreply, close_all_feed_registrations(S0)};
handle_info(
  {gproc, registered, Monitor, _Name},
  S0 = #s{transport_monitor = Monitor}) ->
    {noreply, reconcile_all_feed_registrations(S0)};
handle_info(
  {link_up, OpenRef, <<_:256>> = Peer, Chan, Link}, S0)
  when is_reference(OpenRef), is_binary(Chan), is_pid(Link) ->
    {noreply,
     finish_feed_registration_open(OpenRef, Peer, Chan, Link, S0)};
handle_info(
  {link_error, OpenRef, <<_:256>> = Peer, Chan}, S0)
  when is_reference(OpenRef), is_binary(Chan) ->
    {noreply,
     fail_feed_registration_open(OpenRef, Peer, Chan, S0)};
handle_info(
  {foreign_projection_building, Identity, Generation, Height}, S0) ->
    {noreply, projection_building(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_waiting, Identity, Generation, _Reason, Height}, S0) ->
    {noreply, projection_waiting(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_ready, Identity, Generation, Result}, S0) ->
    {noreply, projection_ready(Identity, Generation, Result, S0)};
handle_info({'DOWN', MRef, process, Pid, Reason}, S0) ->
    case maps:get(MRef, S0#s.feed_registration_monitors, undefined) of
        {_Identity, _Peer} ->
            {noreply, feed_registration_down(MRef, Pid, S0)};
        undefined ->
            case request_by_monitor(MRef, S0#s.pending) of
                {ok, RequestRef} ->
                    {noreply, finish_request(RequestRef, {error, retry}, S0)};
                error ->
                    case consumer_by_monitor(MRef, S0) of
                        {ok, FollowRef} ->
                            {noreply, remove_follow_any(FollowRef, S0)};
                        error ->
                            {noreply, projection_down(MRef, Pid, Reason, S0)}
                    end
            end
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #s{channels = Channels,
                      progress_channels = ProgressChannels,
                      histories = Histories,
                      feed_registrations = FeedRegistrations,
                      transport_monitor = TransportMonitor}) ->
    maps:foreach(
      fun(_Identity, #history{materializer = Materializer,
                              phase_session = PhaseSession}) ->
              stop_materializer(Materializer),
              close_phase_session(PhaseSession)
      end, Histories),
    _ = [catch quod_reg:unsubscribe({channel, Chan})
         || Chan <- maps:keys(Channels)],
    _ = [catch quod_reg:unsubscribe({channel, Chan})
         || Chan <- maps:keys(ProgressChannels)],
    _ = [catch quod_reg:unsubscribe({committed, Ns})
         || {_Chan, {Ns, _Count}} <- maps:to_list(ProgressChannels)],
    _ = [catch quod_reg:unsubscribe({directory_route, Identity})
         || {Identity, #history{progress_signals_open = true}} <-
                maps:to_list(Histories)],
    maps:foreach(
      fun(_Key, Registration) ->
              close_feed_registration(Registration)
      end, FeedRegistrations),
    _ = catch quod_reg:demonitor_name(
                {transport, node}, TransportMonitor),
    ok.

%%%===================================================================
%%% Admission and owner accounting
%%%===================================================================

validate_reference_request(Ref, Phase, TimeoutMs) ->
    case validate_current_ref(Ref, TimeoutMs) of
        {ok, Identity} ->
            case valid_phase(Phase) of
                true -> {ok, Identity};
                false -> {error, bad_foreign_reference}
            end;
        {error, _} = Error ->
            Error
    end.

normalize_entry_hint(#entry{} = Entry) ->
    case quod_catchup:page_stats([Entry]) of
        {ok, 1, _Bytes} -> Entry;
        {error, _} -> none
    end;
normalize_entry_hint(_Hint) ->
    none.

validate_route_request(
  <<_:256>>, Endpoint,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case quod_quic:valid_endpoint(Endpoint) andalso valid_phase(Phase)
         andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_route_request(_Peer, _Endpoint, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_local_request(
  LedgerRoot,
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when (is_list(LedgerRoot) orelse is_binary(LedgerRoot)),
       is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0,
       is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_phase(Phase) andalso quod_dtx:validate_certified_ref(Ref) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_local_request(_LedgerRoot, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_request([_ | _] = Routes, Ref, TimeoutMs) ->
    case normalize_route_candidates(Routes) of
        {ok, Routes} ->
            validate_current_ref(Ref, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_request(_Routes, _Ref, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_identity_request([_ | _] = Routes, Identity, TimeoutMs) ->
    case normalize_route_candidates(Routes) of
        {ok, Routes} ->
            validate_current_identity(Identity, TimeoutMs);
        _ ->
            {error, bad_foreign_reference}
    end;
validate_current_identity_request(_Routes, _Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

validate_current_identity(Identity, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    case valid_identity(Identity) of
        true -> ok;
        false -> {error, bad_foreign_reference}
    end;
validate_current_identity(_Identity, _TimeoutMs) ->
    {error, bad_foreign_reference}.

valid_request_contact(none) ->
    true;
valid_request_contact({<<_:256>>, Endpoint}) ->
    quod_quic:valid_endpoint(Endpoint);
valid_request_contact(_) ->
    false.

valid_identity({Ns, <<_:256>>})
  when is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
    true;
valid_identity(_) ->
    false.

validate_current_ref(Ref, TimeoutMs) ->
    case Ref of
        {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
         <<_:256>>, <<_:256>>, Proof}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
               is_integer(Slot), Slot > 0,
               is_binary(Proof), byte_size(Proof) > 0,
               is_integer(TimeoutMs), TimeoutMs > 0,
               TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
            case quod_dtx:validate_certified_ref(Ref) of
                true -> {ok, {Ns, Anchor}};
                false -> {error, bad_foreign_reference}
            end;
        _ ->
            {error, bad_foreign_reference}
    end.

normalize_route_candidates(Routes) when is_list(Routes) ->
    normalize_route_candidates(Routes, 0, []);
normalize_route_candidates(_) ->
    error.

normalize_route_candidates([], _Count, Acc) ->
    {ok, lists:reverse(Acc)};
normalize_route_candidates(
  [{<<_:256>> = Peer, Endpoints0} | Rest], Count, Acc)
  when is_list(Endpoints0), Count < ?MAX_VALIDATORS ->
    Endpoints = lists:uniq(Endpoints0),
    case Endpoints0 =:= Endpoints andalso Endpoints =/= [] andalso
         length(Endpoints) =< 2 andalso
         lists:all(fun quod_quic:valid_endpoint/1, Endpoints) andalso
         not lists:keymember(Peer, 1, Acc) of
        true ->
            normalize_route_candidates(
              Rest, Count + 1, [{Peer, Endpoints} | Acc]);
        false ->
            error
    end;
normalize_route_candidates(_, _Count, _Acc) ->
    error.

selected_route_sources(Identity = {Ns, Anchor}, Supplied, S) ->
    case directory_route_hints(Ns, Anchor) of
        {error, anchor_conflict} ->
            {error, anchor_conflict};
        {ok, Directory} ->
            {Projection, Bootstrap} =
                case maps:get(Identity, S#s.histories, undefined) of
                    #history{projection = P, bootstrap_hints = B} -> {P, B};
                    undefined -> {undefined, bootstrap_hints(Identity, S)}
                end,
            {ok, #{live => Directory, supplied => Supplied,
                   bootstrap => Bootstrap, projection => Projection}}
    end.

add_request_contact(none, Sources) ->
    Sources;
add_request_contact({Peer, Endpoint}, #{live := Live} = Sources) ->
    %% The TLS-authenticated contact carrying this request is the freshest
    %% first-party endpoint for its key. Keep it only in this work item: failed
    %% ontology authentication must leave no remembered identity or address.
    Sources#{live := [{Peer, Endpoint}
                      | lists:keydelete(Peer, 1, Live)]}.

route_candidates(#{live := Live, supplied := Supplied,
                   bootstrap := Bootstrap, projection := Projection} = Sources) ->
    case is_map(Projection) of
        true -> current_route_candidates(Sources, Projection);
        false -> discovery_route_candidates(Live, Supplied, Bootstrap)
    end.

discovery_route_candidates(Live, Supplied, Bootstrap) ->
    Routes = lists:sublist(
               stable_unique_routes(Live ++ Supplied ++ Bootstrap),
               ?MAX_VALIDATORS),
    [{Peer, [Endpoint]} || {Peer, Endpoint} <- Routes].

directory_route_hints(Ns, Anchor) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, Rows} ->
            {ok,
             [{PeerKey, Endpoint}
              || #{node_key := <<_:256>> = PeerKey,
                   endpoint := Endpoint} <- Rows,
                 quod_quic:valid_endpoint(Endpoint)]};
        {error, anchor_conflict} ->
            {error, anchor_conflict};
        {error, unavailable} ->
            {ok, []}
    end.

remember_bootstrap_candidate(Identity, PeerKey, Endpoint, S0) ->
    case valid_identity(Identity) andalso
         is_binary(PeerKey) andalso byte_size(PeerKey) =:= 32 andalso
         quod_quic:valid_endpoint(Endpoint) of
        false ->
            S0#s{bootstrap_rejected = S0#s.bootstrap_rejected + 1};
        true ->
            S1 = ensure_bootstrap_history(Identity, S0),
            H0 = maps:get(Identity, S1#s.histories),
            {Hints, Evicted} = put_bootstrap_hint(
                                 PeerKey, Endpoint,
                                 H0#history.bootstrap_hints,
                                 H0#history.projection),
            H1 = H0#history{bootstrap_hints = Hints,
                            last_used = quod_time:mono_ms()},
            S2 = put_history(
                   Identity, H1,
                   S1#s{bootstrap_accepted =
                            S1#s.bootstrap_accepted + 1,
                        bootstrap_evicted =
                            S1#s.bootstrap_evicted + Evicted}),
            hibernate_history(
              Identity, wake_follow(Identity, S2))
    end.

%% A transport hint creates only a lazy, dormant history row. It never evicts
%% verified history: there is no global history budget to compete for.
ensure_bootstrap_history(Identity, S = #s{histories = Histories})
  when is_map_key(Identity, Histories) ->
    S;
ensure_bootstrap_history(Identity, S) ->
    ensure_history(Identity, S).

put_bootstrap_hint(PeerKey, Endpoint, Hints0, Projection) ->
    WithoutPeer = [{Peer, Ep} || {Peer, Ep} <- Hints0,
                                  Peer =/= PeerKey],
    Hints1 = [{PeerKey, Endpoint} | WithoutPeer],
    case length(Hints1) =< ?MAX_CURRENT_ROUTE_HINTS of
        true -> {Hints1, 0};
        false ->
            Committee = case is_map(Projection) of
                            true -> quod_simplex:history_committee(Projection);
                            false -> []
                        end,
            {evict_oldest_unprotected(Hints1, Committee), 1}
    end.

evict_oldest_unprotected(Hints, ProtectedKeys) ->
    Reversed = lists:reverse(Hints),
    case drop_first(
           fun({Peer, _Endpoint}) ->
                   not lists:member(Peer, ProtectedKeys)
           end, Reversed) of
        {ok, Kept} -> lists:reverse(Kept);
        %% Defensive only: an overflow list cannot be entirely protected
        %% while committees are bounded below the hint cap. If that invariant
        %% ever changes, refuse the newest contact rather than evicting a
        %% current committee member.
        none -> tl(Hints)
    end.

drop_first(_Predicate, []) ->
    none;
drop_first(Predicate, [Item | Rest]) ->
    case Predicate(Item) of
        true -> {ok, Rest};
        false ->
            case drop_first(Predicate, Rest) of
                {ok, Kept} -> {ok, [Item | Kept]};
                none -> none
            end
    end.

%% `entry` asks this same exact-reference verifier to accept either content or
%% a DTX control. Read certificates bind the last material ledger entry, whose
%% class is intentionally opaque to the certificate collector.
valid_phase('begin') -> true;
valid_phase(entry) -> true;
valid_phase(transaction) -> true;
valid_phase(prepare) -> true;
valid_phase(decision) -> true;
valid_phase(finalize) -> true;
valid_phase(complete) -> true;
valid_phase(_) -> false.

ensure_history(Identity, S = #s{histories = Histories})
  when is_map_key(Identity, Histories) ->
    activate_history_channel(Identity, S);
ensure_history(Identity = {Ns, _Anchor}, S0) ->
    H0 = load_or_new_history(S0#s.root, Identity),
    H = H0#history{bootstrap_hints = bootstrap_hints(Identity, S0),
                   channel_open = true},
    S1 = add_channel(Ns, S0#s{bootstrap = maps:remove(Identity, S0#s.bootstrap)}),
    S1#s{histories = (S1#s.histories)#{Identity => H}}.

activate_history_channel(Identity = {Ns, _Anchor}, S0) ->
    case maps:get(Identity, S0#s.histories) of
        #history{channel_open = true} -> S0;
        #history{} = H0 ->
            S1 = add_channel(Ns, S0),
            put_history(Identity, H0#history{channel_open = true}, S1)
    end.

reserve_page(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H0 = maps:get(Identity, S0#s.histories),
            H1 = H0#history{bytes = H0#history.bytes + Bytes},
            {ok, S0#s{histories = (S0#s.histories)#{Identity => H1},
                      total_bytes = S0#s.total_bytes + Bytes}};
        error -> {error, S0}
    end.

set_cache_size(RequestRef, Bytes, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H0 = maps:get(Identity, S0#s.histories),
            case Bytes =< H0#history.bytes of
                true ->
                    H1 = H0#history{bytes = Bytes},
                    {ok, S0#s{histories =
                                  (S0#s.histories)#{Identity => H1},
                               total_bytes =
                                   S0#s.total_bytes -
                                       (H0#history.bytes - Bytes)}};
                false ->
                    Delta = Bytes - H0#history.bytes,
                    H1 = H0#history{bytes = Bytes},
                    {ok, S0#s{histories =
                                  (S0#s.histories)#{Identity => H1},
                               total_bytes = S0#s.total_bytes + Delta}}
            end;
        error -> {error, S0}
    end.

reset_cache_accounting(RequestRef, S0) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            H00 = maps:get(Identity, S0#s.histories),
            S1 = case H00#history.materializer of
                     none -> S0;
                     #materializer{} = M ->
                         discard_materializer(Identity, H00, M, S0)
                 end,
            H0 = maps:get(Identity, S1#s.histories),
            close_phase_session(H0#history.phase_session),
            H1 = H0#history{height = 0, bytes = 0,
                            projection = undefined,
                            resident_verified = false,
                            phase_session = none},
            {ok, S1#s{histories = (S1#s.histories)#{Identity => H1},
                      total_bytes = max(
                                      0, S1#s.total_bytes - H0#history.bytes)}};
        error -> error
    end.

request_identity(RequestRef, #s{pending = Pending}) ->
    case maps:get(RequestRef, Pending, undefined) of
        #request{identity = Identity} -> {ok, Identity};
        undefined -> error
    end.

request_by_monitor(MRef, Pending) ->
    case [Ref || {Ref, #request{mref = RefM}} <- maps:to_list(Pending),
                 RefM =:= MRef] of
        [Ref] -> {ok, Ref};
        [] -> error
    end.

park_failed_routed_request(RequestRef, S0) ->
    case maps:take(RequestRef, S0#s.pending) of
        {#request{from = From, callers = Callers,
                  identity = Identity, work = #routed_work{} = Work,
                  mref = MRef, timer = Timer}, Pending1} ->
            cancel_optional_timer(Timer),
            _ = erlang:demonitor(MRef, [flush]),
            Histories1 = clear_active_request(
                           Identity, RequestRef, S0#s.histories),
            S1 = cancel_request_pulls(
                   RequestRef,
                   S0#s{pending = Pending1, histories = Histories1}),
            case From =:= none andalso map_size(Callers) =:= 0 of
                true ->
                    start_next_request(
                      Identity, maybe_close_progress_signals(Identity, S1));
                false ->
                    H0 = maps:get(Identity, S1#s.histories),
                    Parked = #queued_request{
                                ref = RequestRef, from = From,
                                callers = Callers, peer = none,
                                identity = Identity, work = Work,
                                fetch_fun = S1#s.fetch_fun,
                                work_timeout_ms = verification_work_timeout(S1),
                                parked = true,
                                enqueued_native = erlang:monotonic_time()},
                    S2 = put_history(
                           Identity,
                           H0#history{
                             waiting = queue:in(
                                         Parked, H0#history.waiting)}, S1),
                    start_next_request(
                      Identity, open_progress_signals(Identity, S2))
            end;
        error ->
            S0
    end.

clear_active_request(Identity, RequestRef, Histories) ->
    case maps:get(Identity, Histories, undefined) of
        #history{active = RequestRef} = H0 ->
            Histories#{Identity => H0#history{
                                     active = none,
                                     last_used = quod_time:mono_ms()}};
        _ ->
            Histories
    end.

finish_request(RequestRef, Reply, S0) ->
    case maps:take(RequestRef, S0#s.pending) of
        {#request{from = From, callers = Callers,
                  identity = Identity,
                  mref = MRef, timer = Timer}, Pending1} ->
            cancel_optional_timer(Timer),
            cancel_caller_timers(Callers),
            _ = erlang:demonitor(MRef, [flush]),
            Histories1 =
                case maps:get(Identity, S0#s.histories, undefined) of
                    #history{} = H ->
                        (S0#s.histories)#{Identity =>
                                             H#history{active = none,
                                                       last_used =
                                                           quod_time:mono_ms()}};
                    undefined -> S0#s.histories
                end,
            S1 = S0#s{pending = Pending1, histories = Histories1},
            S2 = cancel_request_pulls(RequestRef, S1),
            S3 = case From of
                {follow, Identity, Token} ->
                    finish_follow_refresh(Identity, Token, Reply, S2);
                none ->
                    reply_request_callers(maps:keys(Callers), Reply),
                    S2
            end,
            start_next_request(Identity, S3);
        error ->
            S0
    end.

reply_request_callers(Callers, Reply) ->
    lists:foreach(fun(Caller) -> gen_server:reply(Caller, Reply) end, Callers).

cancel_optional_timer(none) -> ok;
cancel_optional_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

cancel_caller_timers(Callers) ->
    maps:foreach(
      fun(_Caller, Timer) ->
              _ = erlang:cancel_timer(Timer),
              ok
      end, Callers).

start_next_request(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{active = none, waiting = Waiting0} = H0 ->
            case take_runnable_request(
                   Identity, queue:to_list(Waiting0), S0) of
                {ready, Queued, Peer, WorkerWork, Rest} ->
                    H1 = H0#history{waiting = queue:from_list(Rest)},
                    S1 = put_history(Identity, H1, S0),
                    observe_foreign_stage(
                      queue_wait, ok,
                      Queued#queued_request.enqueued_native),
                    case Queued#queued_request.work of
                        #routed_work{} = RequestWork ->
                            launch_request_owned(
                              Queued#queued_request.ref, Peer, Identity,
                              Queued#queued_request.work_timeout_ms,
                              RequestWork, WorkerWork,
                              Queued#queued_request.fetch_fun,
                              Queued#queued_request.from,
                              Queued#queued_request.callers, S1);
                        _ ->
                            launch_request_owned(
                              Queued#queued_request.ref, Peer, Identity,
                              Queued#queued_request.work_timeout_ms,
                              WorkerWork, Queued#queued_request.fetch_fun,
                              Queued#queued_request.from,
                              Queued#queued_request.callers, S1)
                    end;
                {waiting, Rest} ->
                    H1 = H0#history{waiting = queue:from_list(Rest)},
                    S1 = put_history(Identity, H1, S0),
                    case has_parked_route_waiter(H1) of
                        true -> open_progress_signals(Identity, S1);
                        false -> hibernate_history(
                                   Identity,
                                   maybe_close_progress_signals(Identity, S1))
                    end
            end;
        _ -> S0
    end.

take_runnable_request(Identity, Waiting, S0) ->
    take_runnable_request(Identity, Waiting, [], S0).

take_runnable_request(_Identity, [], Skipped, _S0) ->
    {waiting, lists:reverse(Skipped)};
take_runnable_request(
  Identity,
  [Queued = #queued_request{work = #routed_work{}, parked = true} | Rest],
  Skipped, S0) ->
    take_runnable_request(Identity, Rest, [Queued | Skipped], S0);
take_runnable_request(
  Identity,
  [Queued = #queued_request{work = #routed_work{} = Work} | Rest],
  Skipped, S0) ->
    case resolve_routed_work(Identity, Work, S0) of
        {ready, Peer, WorkerWork} ->
            {ready, Queued, Peer, WorkerWork,
             lists:reverse(Skipped) ++ Rest};
        wait ->
            take_runnable_request(
              Identity, Rest,
              [Queued#queued_request{parked = true} | Skipped], S0)
    end;
take_runnable_request(
  _Identity, [Queued | Rest], Skipped, _S0) ->
    {ready, Queued, Queued#queued_request.peer,
     Queued#queued_request.work, lists:reverse(Skipped) ++ Rest}.

release_route_waiters(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{waiting = Waiting0} = H0 ->
            Waiting1 = queue:from_list(
                         [release_route_waiter(Queued)
                          || Queued <- queue:to_list(Waiting0)]),
            start_next_request(
              Identity,
              put_history(Identity, H0#history{waiting = Waiting1}, S0));
        undefined ->
            S0
    end.

release_route_waiter(#queued_request{work = #routed_work{}} = Queued) ->
    Queued#queued_request{parked = false};
release_route_waiter(Queued) ->
    Queued.

has_parked_route_waiter(#history{waiting = Waiting}) ->
    lists:any(
      fun(#queued_request{work = #routed_work{}, parked = true}) -> true;
         (_) -> false
      end, queue:to_list(Waiting)).

expire_request_caller(RequestRef, From, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{callers = Callers} = Request ->
            case maps:take(From, Callers) of
                {_Timer, Callers1} ->
                    gen_server:reply(From, {error, retry}),
                    Pending1 = (S0#s.pending)#{
                                 RequestRef =>
                                     Request#request{callers = Callers1}},
                    S0#s{pending = Pending1};
                error ->
                    S0
            end;
        undefined ->
            expire_queued_caller(RequestRef, From, S0)
    end.

expire_queued_caller(RequestRef, From, S0) ->
    expire_queued_caller(
      RequestRef, From, maps:to_list(S0#s.histories), S0).

expire_queued_caller(_RequestRef, _From, [], S0) ->
    S0;
expire_queued_caller(RequestRef, From, [{Identity, H0} | Rest], S0) ->
    Items0 = queue:to_list(H0#history.waiting),
    case update_queued_caller(RequestRef, From, Items0) of
        {updated, Items1} ->
            gen_server:reply(From, {error, retry}),
            S1 = put_history(
                   Identity,
                   H0#history{waiting = queue:from_list(Items1)}, S0),
            start_next_request(
              Identity, maybe_close_progress_signals(Identity, S1));
        found ->
            S0;
        not_found ->
            expire_queued_caller(RequestRef, From, Rest, S0)
    end.

update_queued_caller(_RequestRef, _From, []) ->
    not_found;
update_queued_caller(
  RequestRef, From,
  [#queued_request{ref = RequestRef, callers = Callers,
                   parked = Parked} = Queued | Rest]) ->
    case maps:take(From, Callers) of
        {_Timer, Callers1} ->
            case Parked andalso map_size(Callers1) =:= 0 of
                true -> {updated, Rest};
                false ->
                    {updated,
                     [Queued#queued_request{callers = Callers1} | Rest]}
            end;
        error ->
            found
    end;
update_queued_caller(RequestRef, From, [Queued | Rest]) ->
    case update_queued_caller(RequestRef, From, Rest) of
        {updated, Rest1} -> {updated, [Queued | Rest1]};
        Other -> Other
    end.

%%%===================================================================
%%% Continuous certified follow lifecycle
%%%===================================================================

add_follow(Identity, ConsumerPid, S0)
  when is_pid(ConsumerPid) ->
    S1 = ensure_history(Identity, S0),
    H0 = maps:get(Identity, S1#s.histories),
    WasIdle = map_size(H0#history.consumers) =:= 0,
    FollowRef = make_ref(),
    MRef = erlang:monitor(process, ConsumerPid),
    Consumer = #consumer{pid = ConsumerPid, mref = MRef},
    H1 = H0#history{
           consumers = (H0#history.consumers)#{FollowRef => Consumer},
           projection_state = building,
           last_used = quod_time:mono_ms()},
    S2 = S1#s{
           histories = (S1#s.histories)#{Identity => H1},
           follows = (S1#s.follows)#{FollowRef => Identity}},
    S3 = notify_follow(
           FollowRef,
           {building, materialized_height(H1)}, S2),
    S4 = case WasIdle of
             true -> open_progress_signals(Identity, S3);
             false -> S3
         end,
    {FollowRef,
     case WasIdle of
         true -> wake_follow(Identity, S4);
         false -> S4
     end}.

acknowledge_follow(FollowRef, NoticeRef, ConsumerPid, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{pid = ConsumerPid,
                                outstanding = {NoticeRef, _Notice}} = C0,
         H0} ->
            C1 = C0#consumer{outstanding = none},
            H1 = put_consumer(FollowRef, C1, H0),
            S1 = put_history(Identity, H1, S0),
            case C1#consumer.pending of
                none -> S1;
                Pending ->
                    notify_follow(
                      FollowRef, Pending,
                      put_history(
                        Identity,
                        put_consumer(
                          FollowRef, C1#consumer{pending = none}, H1),
                        S1))
            end;
        _ ->
            S0
    end.

remove_follow(FollowRef, ConsumerPid, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, _Identity, #consumer{pid = ConsumerPid}, _H} ->
            remove_follow_any(FollowRef, S0);
        _ ->
            S0
    end.

remove_follow_any(FollowRef, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{mref = MRef}, H0} ->
            _ = erlang:demonitor(MRef, [flush]),
            Consumers1 = maps:remove(FollowRef, H0#history.consumers),
            H1 = H0#history{consumers = Consumers1,
                            last_used = quod_time:mono_ms()},
            S1 = put_history(
                   Identity, H1,
                   S0#s{follows = maps:remove(FollowRef, S0#s.follows)}),
            case map_size(Consumers1) of
                0 ->
                    case H1#history.current_watch of
                        Watch when Watch =/= none -> hibernate_history(
                                  Identity,
                                  release_follow_materializer(Identity, S1));
                        none -> hibernate_history(
                                   Identity,
                                   stop_follow_target(Identity, S1))
                    end;
                _ -> S1
            end;
        error ->
            S0
    end.

release_follow_materializer(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{materializer = none} ->
            S0;
        #history{materializer = #materializer{} = Materializer} = H0 ->
            discard_materializer(Identity, H0, Materializer, S0);
        undefined ->
            S0
    end.

follow_consumer(FollowRef, S) ->
    case maps:get(FollowRef, S#s.follows, undefined) of
        undefined -> error;
        Identity ->
            case maps:get(Identity, S#s.histories, undefined) of
                #history{} = H ->
                    case maps:get(FollowRef, H#history.consumers, undefined) of
                        #consumer{} = C -> {ok, Identity, C, H};
                        undefined -> error
                    end;
                undefined -> error
            end
    end.

consumer_by_monitor(MRef, S) ->
    Matches =
        [FollowRef
         || {FollowRef, Identity} <- maps:to_list(S#s.follows),
            #history{} = H <- [maps:get(Identity, S#s.histories)],
            #consumer{mref = ConsumerMRef} <-
                [maps:get(FollowRef, H#history.consumers)],
            ConsumerMRef =:= MRef],
    case Matches of
        [FollowRef] -> {ok, FollowRef};
        [] -> error
    end.

put_consumer(FollowRef, Consumer, H) ->
    H#history{consumers = (H#history.consumers)#{FollowRef => Consumer}}.

put_history(Identity, H, S) ->
    S#s{histories = (S#s.histories)#{Identity => H}}.

%% A cache is durable verified data. Once no worker or projection consumer owns
%% it, close its catch-up channel and disk handles, but retain the one bounded
%% projection, immutable ledger-index session, and suspended derived phase
%% session already verified by this owner. A current-view watch keeps the feed
%% freshness registration; the next real delta resumes the same verifier
%% instead of replaying or rescanning history.
%% After a node restart only the cache remains; first use verifies it fully.
hibernate_history(Identity = {Ns, _}, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{active = none, consumers = Consumers, materializer = none,
                 follow_token = none, follow_inflight = false} = H0
          when map_size(Consumers) =:= 0 ->
            case queue:is_empty(H0#history.waiting) of
                true -> hibernate_idle_history(Identity, Ns, H0, S0);
                false -> S0
            end;
        _ ->
            S0
    end.

hibernate_idle_history(
  _Identity, _Ns,
  #history{resident_verified = true, current_watch = Watch}, S0)
  when Watch =/= none ->
    %% A current-view row stays attached to its existing catch-up and feed
    %% subscriptions. Height wakes drive the same certified follower, so the
    %% next request never pays an avoidable detach/re-attach cycle.
    S0;
hibernate_idle_history(
  Identity, Ns,
  H0 = #history{resident_verified = true, channel_open = true}, S0) ->
    S1 = remove_channel(Ns, S0),
    put_history(Identity, H0#history{channel_open = false}, S1);
hibernate_idle_history(_Identity, _Ns,
                       #history{resident_verified = true}, S0) ->
    S0;
hibernate_idle_history(Identity, Ns, H, S0) ->
    close_phase_session(H#history.phase_session),
    Bootstrap = case H#history.bootstrap_hints of
                    [] -> maps:remove(Identity, S0#s.bootstrap);
                    Hints -> (S0#s.bootstrap)#{Identity => Hints}
                end,
    S1 = S0#s{histories = maps:remove(Identity, S0#s.histories),
              bootstrap = Bootstrap,
              total_bytes = max(0, S0#s.total_bytes - H#history.bytes)},
    remove_channel(Ns, S1).

bootstrap_hints(Identity, #s{histories = Histories, bootstrap = Bootstrap}) ->
    case maps:get(Identity, Histories, undefined) of
        #history{bootstrap_hints = Hints} -> Hints;
        undefined -> maps:get(Identity, Bootstrap, [])
    end.

bootstrap_candidate_count(#s{histories = Histories, bootstrap = Bootstrap}) ->
    lists:sum([length(H#history.bootstrap_hints) || H <- maps:values(Histories)]) +
        lists:sum([length(Hints) || Hints <- maps:values(Bootstrap)]).

notify_history(Identity, Notice, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{consumers = Consumers} ->
            lists:foldl(
              fun(FollowRef, Acc) -> notify_follow(FollowRef, Notice, Acc) end,
              S0, maps:keys(Consumers));
        undefined -> S0
    end.

notify_follow(FollowRef, Notice, S0) ->
    case follow_consumer(FollowRef, S0) of
        {ok, Identity, #consumer{outstanding = none, pid = Pid} = C0, H0} ->
            NoticeRef = make_ref(),
            Pid ! {quod_foreign_follow, FollowRef, NoticeRef, Identity, Notice},
            C1 = C0#consumer{outstanding = {NoticeRef, Notice}},
            S1 = count_follow_resnapshot(Notice, S0),
            put_history(Identity, put_consumer(FollowRef, C1, H0), S1);
        {ok, Identity, #consumer{pending = Pending0} = C0, H0} ->
            C1 = C0#consumer{pending = coalesce_notice(Pending0, Notice)},
            put_history(
              Identity, put_consumer(FollowRef, C1, H0),
              S0#s{follow_coalesced = S0#s.follow_coalesced + 1});
        error ->
            S0
    end.

count_follow_resnapshot({resnapshot, _To, _Projection, _Freshness}, S) ->
    S#s{follow_resnapshots = S#s.follow_resnapshots + 1};
count_follow_resnapshot(_Notice, S) ->
    S.

coalesce_notice(none, Notice) -> Notice;
coalesce_notice(
  {advanced, _From0, _To0, _Projection0, _Fresh0, _Heads0, _Publications0},
  {advanced, _From, To, Projection, Freshness, _Heads, _Publications}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {resnapshot, _To0, _Projection0, _Fresh0},
  {advanced, _From, To, Projection, Freshness, _Heads, _Publications}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {advanced, _From0, _To0, _Projection0, _Fresh0, _Heads0, _Publications0},
  {resnapshot, To, Projection, Freshness}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(
  {resnapshot, _To0, _Projection0, _Fresh0},
  {resnapshot, To, Projection, Freshness}) ->
    {resnapshot, To, Projection, Freshness};
coalesce_notice(_Previous, Newest) ->
    Newest.

-ifdef(TEST).
test_coalesce_notice(Previous, Newest) ->
    coalesce_notice(Previous, Newest).
-endif.

%% A live block/digest, a directory change, or an explicit consumer refresh is
%% only a wake signal. It never advances the cache itself. At most one follow
%% job and one coalesced dirty edge exist per subscribed projection identity.
%% A current-view-only wake merely invalidates that view; the next real request
%% advances it through the same verifier. The certified worker remains the sole
%% place which can accept history.
wake_follow(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            case follow_refresh_needed(H0) of
                false ->
                    S0;
                true ->
                    case {H0#history.follow_token,
                          H0#history.follow_inflight} of
                        {none, false} ->
                            Token = make_ref(),
                            self() ! {follow_refresh, Identity, Token},
                            put_history(
                              Identity, H0#history{follow_token = Token},
                              S0#s{follow_wakes = S0#s.follow_wakes + 1});
                        {Token, false} when is_reference(Token) ->
                            %% The queued mailbox turn has not started its
                            %% certified work yet, so every signal already
                            %% belongs to that same job.
                            S0;
                        {_Token, true} ->
                            put_history(
                              Identity, H0#history{follow_dirty = true}, S0)
                    end
            end;
        _ ->
            S0
    end.

follow_refresh_needed(#history{consumers = Consumers})
  when map_size(Consumers) > 0 ->
    true;
follow_refresh_needed(#history{}) ->
    false.

%% Directory renewal is a route/reconnection edge, not a periodic history
%% probe. Parked exact work is released by the caller above, and a live feed
%% registration supplies subsequent certified-progress wakes. A first attempt
%% with no established reachability still needs a dirty edge to close the race
%% where its route snapshot predates this event; an unreachable follower needs
%% an immediate new attempt. A reachable follower needs neither.
wake_follow_if_route_needed(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{reachability = reachable} -> S0;
        #history{} -> wake_follow(Identity, S0);
        undefined -> S0
    end.

begin_follow_refresh(Identity, Token, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{follow_token = Token} = H0 ->
            case follow_refresh_needed(H0) of
                true ->
                    H1 = H0#history{follow_token = none,
                                    follow_inflight = true},
                    S1 = put_history(Identity, H1, S0),
                    Timeout = follow_request_timeout(S1),
                    case selected_route_sources(Identity, [], S1) of
                        {error, anchor_conflict} ->
                            finish_follow_refresh(
                              Identity, Token,
                              {error, {unreachable, anchor_conflict}}, S1);
                        {ok, Sources} ->
                            case start_worker(
                                   {follow, Identity}, Identity, Timeout,
                                   {follow, Identity, Sources}, S1#s.fetch_fun,
                                   {follow, Identity, Token}, S1) of
                                {ok, S2} -> S2
                            end
                    end;
                false ->
                    put_history(
                      Identity, H0#history{follow_token = none}, S0)
            end;
        _ ->
            S0
    end.

follow_request_timeout(S) ->
    min(?MAX_TIMER_MS - 1000, 2 * S#s.page_timeout_ms + 1000).

finish_follow_refresh(Identity, _Token, Reply, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{consumers = Consumers, current_watch = none} = H0
          when map_size(Consumers) =:= 0 ->
            hibernate_history(
              Identity,
              put_history(
                Identity,
                H0#history{follow_inflight = false, follow_dirty = false},
                S0));
        #history{} = H0 ->
            Now = quod_time:mono_ms(),
            {View, Hint, Reason} =
                case Reply of
                    {ok, Evidence} when is_map(Evidence) ->
                        {maps:get(current_view, Evidence, confirmed),
                         maps:get(hinted_height, Evidence,
                                  maps:get(slot, Evidence, unknown)),
                         none};
                    {error, {unreachable, Why}} ->
                        {unconfirmed, H0#history.hinted_height, Why};
                    {error, _} ->
                        {unconfirmed, H0#history.hinted_height, unavailable}
                end,
            H1 = H0#history{last_probe_ms = Now, hinted_height = Hint,
                            current_view = View,
                            follow_inflight = false,
                            reachability =
                                case Reason of
                                    none -> reachable;
                                    _ -> {unreachable, Reason}
                                end},
            S1 = put_history(Identity, H1, S0),
            S2 = ensure_materializer_advanced(Identity, S1),
            S3 = case Reason of
                     none -> S2;
                     _ -> notify_history(
                            Identity,
                            {unreachable, Reason,
                             materialized_height(
                               maps:get(Identity, S2#s.histories))}, S2)
                 end,
            continue_follow_progress(Identity, View, Hint, S3);
        undefined ->
            S0
    end.

%% A certified page which says that a later tip already exists is also an
%% exact progress edge: continue immediately instead of waiting for another
%% feed digest.  It is merged with any signal received while the worker was
%% active, so both conditions still produce only one next job.  No unchanged
%% or failed result can create a loop.
continue_follow_progress(Identity, View, Hint, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{follow_dirty = Dirty, height = Height} = H0 ->
            MoreCertified =
                View =:= unconfirmed andalso
                    is_integer(Hint) andalso Hint > Height,
            case Dirty orelse MoreCertified of
                true ->
                    wake_follow(
                      Identity,
                      put_history(
                        Identity, H0#history{follow_dirty = false}, S0));
                false ->
                    S0
            end;
        _ ->
            S0
    end.

ensure_materializer_advanced(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{height = Height, projection = Projection,
                 materializer = Materializer,
                 consumers = Consumers} = H0
          when Height > 0, is_map(Projection), map_size(Consumers) > 0 ->
            case history_head(Projection) of
                {Height, <<_:256>>} = Head ->
                    case Materializer of
                        none ->
                            {Pid, MRef, Generation} =
                                quod_foreign_projection:start_monitor(
                                  self(), Identity, S0#s.root,
                                  H0#history.cache_ns),
                            M = #materializer{pid = Pid, mref = MRef,
                                              generation = Generation},
                            quod_foreign_projection:advance(
                              Pid, Generation, Height, Head),
                            put_history(
                              Identity,
                              H0#history{materializer = M,
                                         projection_state = building,
                                         projection_wait = none},
                              S0#s{projection_rebuilds =
                                       S0#s.projection_rebuilds + 1});
                        #materializer{pid = Pid, generation = Generation} ->
                            quod_foreign_projection:advance(
                              Pid, Generation, Height, Head),
                            put_history(
                              Identity,
                              H0#history{projection_wait = none}, S0)
                    end;
                _ ->
                    S0
            end;
        _ ->
            S0
    end.

history_head(Projection) when is_map(Projection) ->
    maps:get(history_head, Projection, none).

projection_building(Identity, Generation, Height, S0) ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, H0, _M} ->
            notify_history(
              Identity, {building, Height},
              put_history(
                Identity,
                H0#history{projection_state = building,
                           projection_wait = none}, S0));
        error -> S0
    end.

projection_waiting(Identity, Generation, Height, S0) ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, H0, _M} ->
            S1 = notify_history(
                   Identity, {building, Height},
                   put_history(
                     Identity,
                     H0#history{projection_wait = network_identity}, S0)),
            %% Root may have become ready before this message crossed the
            %% owner's mailbox.  Recheck the dependency at the edge instead
            %% of waiting for an event which has already happened.
            case quod_ontology:network_identity() of
                {ok, <<_:256>>} -> ensure_materializer_advanced(Identity, S1);
                _ -> S1
            end;
        error -> S0
    end.

resume_network_identity_projections(S0) ->
    lists:foldl(
      fun({Identity, #history{projection_wait = network_identity}}, S) ->
              ensure_materializer_advanced(Identity, S);
         ({_Identity, #history{}}, S) ->
              S
      end, S0, maps:to_list(S0#s.histories)).

projection_ready(Identity, Generation,
                 #{from := From, height := Height,
                   projection_id := ProjectionId,
                   changed_heads := Heads0, resnapshot := Resnapshot0,
                   publications := Publications0,
                   memory_bytes := MemoryBytes}, S0)
  when is_integer(From), is_integer(Height), Height >= From,
       is_binary(ProjectionId), byte_size(ProjectionId) =:= 32,
       is_list(Heads0), is_list(Publications0),
       is_integer(MemoryBytes), MemoryBytes >= 0 ->
    case materializer_matches(Identity, Generation, S0) of
        {ok, H0, M0} ->
            Total = max(
                      0, S0#s.projection_bytes -
                             M0#materializer.memory_bytes + MemoryBytes),
            M1 = M0#materializer{
                   height = Height, projection_id = ProjectionId,
                   memory_bytes = MemoryBytes},
            LastAdvance = case Height > M0#materializer.height of
                              true -> quod_time:mono_ms();
                              false -> H0#history.last_advance_ms
                          end,
            H1 = H0#history{materializer = M1,
                            last_advance_ms = LastAdvance,
                            projection_state = ready,
                            projection_wait = none},
            S1 = put_history(
                   Identity, H1,
                   S0#s{projection_bytes = Total,
                        max_follow_lag = max(
                                           S0#s.max_follow_lag,
                                           follow_lag(H1, Height))}),
            Freshness = follow_freshness(H1, Height),
            {Resnapshot, Heads} = bounded_heads(
                                    Resnapshot0 orelse From =:= 0,
                                    Heads0),
            Publications = case Resnapshot of
                               true -> [];
                               false -> Publications0
                           end,
            Notice = case Resnapshot of
                         true -> {resnapshot, Height, ProjectionId,
                                  Freshness};
                         false -> {advanced, From, Height, ProjectionId,
                                   Freshness, Heads, Publications}
                     end,
            notify_history(Identity, Notice, S1);
        error -> S0
    end;
projection_ready(_Identity, _Generation, _Result, S) ->
    S.

bounded_heads(true, _Heads) -> {true, []};
bounded_heads(false, Heads) ->
    case stable_bounded_heads(Heads, ?MAX_CHANGED_HEADS, #{}, []) of
        {ok, Unique} -> {false, Unique};
        overflow -> {true, []}
    end.

stable_bounded_heads([], _Left, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
stable_bounded_heads([Head | Rest], Left, Seen, Acc) ->
    case maps:is_key(Head, Seen) of
        true -> stable_bounded_heads(Rest, Left, Seen, Acc);
        false when Left > 0 ->
            stable_bounded_heads(
              Rest, Left - 1, Seen#{Head => true}, [Head | Acc]);
        false -> overflow
    end.

follow_freshness(H, Height) ->
    Hint = H#history.hinted_height,
    Lag = case Hint of
              N when is_integer(N), N >= Height -> N - Height;
              _ -> unknown
          end,
    #{last_probe_ms => H#history.last_probe_ms,
      last_advance_ms => H#history.last_advance_ms,
      hinted_height => Hint, lag => Lag,
      current_view => H#history.current_view}.

follow_lag(#history{hinted_height = Hint}, Height)
  when is_integer(Hint), Hint >= Height -> Hint - Height;
follow_lag(_H, _Height) -> 0.

materializer_matches(Identity, Generation, S) ->
    case maps:get(Identity, S#s.histories, undefined) of
        #history{materializer =
                     #materializer{generation = Generation} = M} = H ->
            {ok, H, M};
        _ -> error
    end.

projection_down(MRef, _Pid, _Reason, S0) ->
    Matches =
        [{Identity, H, M}
         || {Identity, H = #history{materializer = M}} <-
                maps:to_list(S0#s.histories),
            is_record(M, materializer), M#materializer.mref =:= MRef],
    case Matches of
        [{Identity, H0, M0}] ->
            S1 = discard_materializer(Identity, H0, M0, S0),
            H1 = maps:get(Identity, S1#s.histories),
            notify_history(
              Identity, {building, materialized_height(H0)},
              put_history(
                Identity,
                H1#history{reachability = {unreachable, materializer_down}},
                S1));
        [] -> S0
    end.

discard_materializer(Identity, H0, M0, S0) ->
    stop_materializer(M0),
    put_history(
      Identity,
      H0#history{materializer = none, projection_state = building,
                 projection_wait = none},
      S0#s{projection_bytes = max(
                                  0, S0#s.projection_bytes -
                                         M0#materializer.memory_bytes)}).

materialized_height(#history{materializer = none}) -> 0;
materialized_height(#history{materializer = #materializer{height = Height}}) ->
    Height.

stop_follow_target(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            S1 = case H0#history.materializer of
                     none -> S0;
                     #materializer{} = M ->
                         discard_materializer(Identity, H0, M, S0)
                 end,
            H1 = maps:get(Identity, S1#s.histories),
            H2 = H1#history{follow_token = none,
                            follow_inflight = false,
                            follow_dirty = false,
                            hinted_height = unknown,
                            current_view = unconfirmed,
                            projection_state = building,
                            projection_wait = none,
                            reachability = unknown},
            S2 = put_history(Identity, H2, S1),
            maybe_close_progress_signals(
              Identity, cancel_active_follow(Identity, S2));
        undefined -> S0
    end.

cancel_active_follow(Identity, S0) ->
    Matches =
        [{Ref, Worker}
         || {Ref,
             #request{from = {follow, RequestIdentity, _}, worker = Worker}} <-
                maps:to_list(S0#s.pending),
            RequestIdentity =:= Identity],
    lists:foreach(fun({_Ref, Worker}) -> exit(Worker, kill) end, Matches),
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{waiting = Waiting0} = H0 ->
            Waiting1 =
                queue:from_list(
                  [Queued
                   || Queued <- queue:to_list(Waiting0),
                      not queued_follow(Identity, Queued)]),
            put_history(Identity, H0#history{waiting = Waiting1}, S0);
        undefined ->
            S0
    end.

queued_follow(
  Identity,
  #queued_request{from = {follow, RequestIdentity, _Token}}) ->
    RequestIdentity =:= Identity;
queued_follow(_Identity, _Queued) ->
    false.

stop_materializer(none) -> ok;
stop_materializer(#materializer{pid = Pid, mref = MRef}) ->
    _ = erlang:demonitor(MRef, [flush]),
    quod_foreign_projection:stop(Pid).

cancel_request_pulls(RequestRef, S0) ->
    {Keep, Drop} = maps:fold(
                     fun(ReqId, Pull = #pull{request_ref = Ref}, {K, D}) ->
                             case Ref =:= RequestRef of
                                 true -> {K, [{ReqId, Pull} | D]};
                                 false -> {K#{ReqId => Pull}, D}
                             end
                     end, {#{}, []}, S0#s.pulls),
    _ = [begin
             _ = erlang:cancel_timer(Pull#pull.timer),
             gen_server:reply(Pull#pull.from, {error, retry})
         end || {_ReqId, Pull} <- Drop],
    S0#s{pulls = Keep}.

install_worker_meta(RequestRef, Meta, S0) when is_map(Meta) ->
    case request_identity(RequestRef, S0) of
        {ok, Identity} ->
            case maps:get(Identity, S0#s.histories, undefined) of
                #history{} = H0 ->
                    ActualBytes = maps:get(bytes, Meta, H0#history.bytes),
                    Projection = maps:get(
                                   projection, Meta,
                                   H0#history.projection),
                    Bootstrap = case is_map(Projection) of
                                    true -> [];
                                    false -> H0#history.bootstrap_hints
                                end,
                    ResidentVerified =
                        maps:get(resident_verified, Meta, false),
                    PhaseSession = maps:get(phase_session, Meta, none),
                    CacheSession = maps:get(cache_session, Meta, none),
                    close_replaced_phase_session(
                      H0#history.phase_session, PhaseSession),
                    H1 = H0#history{height = maps:get(height, Meta, H0#history.height),
                                    bytes = ActualBytes,
                                    projection = Projection,
                                    resident_verified = ResidentVerified,
                                    phase_session = PhaseSession,
                                    cache_session = CacheSession,
                                    bootstrap_hints = Bootstrap},
                    Total1 = max(
                               0, S0#s.total_bytes - H0#history.bytes +
                                      ActualBytes),
                    reconcile_feed_registrations(
                      Identity,
                      S0#s{histories =
                               (S0#s.histories)#{Identity => H1},
                           total_bytes = Total1});
                undefined -> S0
            end;
        error -> S0
    end;
install_worker_meta(_RequestRef, _Meta, S) -> S.

close_replaced_phase_session(Session, Session) -> ok;
close_replaced_phase_session(Old, _New) -> close_phase_session(Old).

close_phase_session(none) -> ok;
close_phase_session(Session) ->
    _ = quod_dtx_phase_index:close(Session),
    ok.

resident_worker_meta({ok, _Evidence}, #{phase_session := Session} = Meta)
  when Session =/= none ->
    Meta#{resident_verified => true};
resident_worker_meta(_Result, Meta) ->
    Meta.

is_successful_current_outcome(
  {ok, _Evidence, _Store, _Height, _Projection}) -> true;
is_successful_current_outcome(_) -> false.

finish_phase_session(true, PhaseIndex, {Result, Meta}) ->
    {Result, Meta#{phase_session => suspend_phase_session(PhaseIndex)}};
finish_phase_session(false, PhaseIndex, Result) ->
    close_phase_session(PhaseIndex),
    Result.

suspend_phase_session(PhaseIndex) ->
    case quod_dtx_phase_index:suspend(PhaseIndex) of
        {ok, Session} -> Session;
        {error, _} ->
            close_phase_session(PhaseIndex),
            none
    end.

record_follow_progress(RequestRef, Meta, S0) when is_map(Meta) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{from = {follow, Identity, _Token}} ->
            case maps:get(Identity, S0#s.histories, undefined) of
                #history{height = OldHeight, bytes = OldBytes} ->
                    Height = maps:get(height, Meta, OldHeight),
                    Bytes = maps:get(bytes, Meta, OldBytes),
                    Entries = max(0, Height - OldHeight),
                    Pages = case Entries of
                                0 -> 0;
                                _ -> (Entries + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1)
                                     div ?QUOD_MAX_FOREIGN_PAGE_ENTRIES
                            end,
                    S0#s{follow_pages = S0#s.follow_pages + Pages,
                         follow_entries = S0#s.follow_entries + Entries,
                         follow_bytes = S0#s.follow_bytes + max(0, Bytes - OldBytes)};
                undefined -> S0
            end;
        _ -> S0
    end;
record_follow_progress(_RequestRef, _Meta, S) -> S.

foreign_worker_heap_words() ->
    max(1, ?QUOD_SCOPE_WORKER_MAX_HEAP_BYTES div erlang:system_info(wordsize)).

%%%===================================================================
%%% Catch-up transport
%%%===================================================================

open_progress_signals(Identity = {Ns, _Anchor}, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{progress_signals_open = false} = H0 ->
            true = quod_reg:subscribe({directory_route, Identity}),
            S1 = add_namespace_progress_signals(Ns, S0),
            reconcile_feed_registrations(
              Identity,
              put_history(
                Identity, H0#history{progress_signals_open = true}, S1));
        #history{progress_signals_open = true} ->
            reconcile_feed_registrations(Identity, S0);
        _ ->
            S0
    end.

maybe_close_progress_signals(Identity = {Ns, _Anchor}, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{progress_signals_open = true,
                 consumers = Consumers,
                 current_watch = CurrentWatch,
                 resident_verified = ResidentVerified} = H0 ->
            case map_size(Consumers) =:= 0 andalso
                 not (CurrentWatch =/= none andalso ResidentVerified) andalso
                 not has_parked_route_waiter(H0) of
                true ->
                    _ = catch quod_reg:unsubscribe(
                                {directory_route, Identity}),
                    S1 = remove_namespace_progress_signals(Ns, S0),
                    close_identity_feed_registrations(
                      Identity,
                      put_history(
                        Identity,
                        H0#history{progress_signals_open = false}, S1));
                false ->
                    S0
            end;
        _ ->
            S0
    end.

add_namespace_progress_signals(Ns, S0) ->
    Chan = quod_feed:channel(Ns),
    case maps:get(Chan, S0#s.progress_channels, undefined) of
        undefined ->
            true = quod_reg:subscribe({channel, Chan}),
            true = quod_reg:subscribe({committed, Ns}),
            S0#s{progress_channels =
                     (S0#s.progress_channels)#{Chan => {Ns, 1}}};
        {Ns, Count} ->
            S0#s{progress_channels =
                     (S0#s.progress_channels)#{Chan => {Ns, Count + 1}}}
    end.

remove_namespace_progress_signals(Ns, S0) ->
    Chan = quod_feed:channel(Ns),
    case maps:get(Chan, S0#s.progress_channels, undefined) of
        {Ns, 1} ->
            _ = catch quod_reg:unsubscribe({channel, Chan}),
            _ = catch quod_reg:unsubscribe({committed, Ns}),
            S0#s{progress_channels =
                     maps:remove(Chan, S0#s.progress_channels)};
        {Ns, Count} when Count > 1 ->
            S0#s{progress_channels =
                     (S0#s.progress_channels)#{Chan => {Ns, Count - 1}}};
        _ ->
            S0
    end.

%% The existing certified route view owns recipient selection.  This is not a
%% second directory: the registration map contains only live link ownership,
%% and is reconciled from the current projection whenever that projection or
%% its exact directory routes change.
reconcile_feed_registrations(Identity, S0) ->
    Desired = desired_feed_registration_routes(Identity, S0),
    Existing =
        [Key
         || Key = {RegistrationIdentity, _Peer} <-
                maps:keys(S0#s.feed_registrations),
            RegistrationIdentity =:= Identity],
    S1 = lists:foldl(
           fun(Key = {_RegistrationIdentity, Peer}, Acc) ->
                   case maps:is_key(Peer, Desired) of
                       true -> Acc;
                       false -> close_feed_registration_key(Key, Acc)
                   end
           end, S0, Existing),
    maps:fold(
      fun(Peer, Endpoints, Acc) ->
              ensure_feed_registration(Identity, Peer, Endpoints, Acc)
      end, S1, Desired).

reconcile_all_feed_registrations(S0) ->
    Identities =
        [Identity
         || {Identity, #history{progress_signals_open = true}} <-
                maps:to_list(S0#s.histories)],
    lists:foldl(fun reconcile_feed_registrations/2, S0, Identities).

close_all_feed_registrations(S0) ->
    lists:foldl(
      fun close_feed_registration_key/2,
      S0, maps:keys(S0#s.feed_registrations)).

desired_feed_registration_routes(Identity, S) ->
    case maps:get(Identity, S#s.histories, undefined) of
        #history{progress_signals_open = true,
                 current_watch = Watch, consumers = Consumers,
                 projection = Projection}
          when is_map(Projection),
               (map_size(Consumers) > 0 orelse Watch =:= remote) ->
            case selected_route_sources(Identity, [], S) of
                {ok, Sources} ->
                    maps:from_list(
                      [{Peer, Endpoints}
                       || {<<_:256>> = Peer, [_ | _] = Endpoints} <-
                              current_route_candidates(Sources, Projection)]);
                {error, anchor_conflict} ->
                    #{}
            end;
        _ ->
            #{}
    end.

ensure_feed_registration(Identity, Peer, Endpoints,
                         S = #s{feed_registrations = Registrations}) ->
    Key = {Identity, Peer},
    case maps:get(Key, Registrations, undefined) of
        #feed_registration{link = Link} when is_pid(Link) ->
            S;
        #feed_registration{open_ref = OpenRef,
                           current_endpoint = Endpoint}
          when is_reference(OpenRef) ->
            case lists:member(Endpoint, Endpoints) of
                true -> S;
                false ->
                    start_feed_registration(
                      Identity, Peer, Endpoints,
                      close_feed_registration_key(Key, S))
            end;
        #feed_registration{} ->
            start_feed_registration(
              Identity, Peer, Endpoints,
              close_feed_registration_key(Key, S));
        undefined ->
            start_feed_registration(Identity, Peer, Endpoints, S)
    end.

start_feed_registration(Identity, Peer, [_ | _] = Endpoints, S0) ->
    Registration = #feed_registration{
                      identity = Identity, peer = Peer,
                      registration_id = crypto:strong_rand_bytes(16)},
    open_next_feed_registration(
      Registration#feed_registration{remaining = Endpoints}, S0).

open_next_feed_registration(
  Registration = #feed_registration{
                     identity = {Ns, _Anchor} = Identity,
                     peer = Peer,
                     remaining = [Endpoint | Rest]},
  S0) ->
    OpenRef = quod_quic:open_link_pinned(
                Peer, Endpoint, quod_feed:channel(Ns)),
    Key = {Identity, Peer},
    Registration1 = Registration#feed_registration{
                      current_endpoint = Endpoint, remaining = Rest,
                      open_ref = OpenRef, link = none, mref = none,
                      registered = false},
    S0#s{
      feed_registrations =
          (S0#s.feed_registrations)#{Key => Registration1},
      feed_registration_openings =
          (S0#s.feed_registration_openings)#{OpenRef => Key}};
open_next_feed_registration(
  Registration = #feed_registration{identity = Identity, peer = Peer}, S0) ->
    Key = {Identity, Peer},
    Registration1 = Registration#feed_registration{
                      current_endpoint = none, remaining = [],
                      open_ref = none, link = none, mref = none,
                      registered = false},
    S0#s{feed_registrations =
             (S0#s.feed_registrations)#{Key => Registration1}}.

finish_feed_registration_open(OpenRef, Peer, Chan, Link,
                              S0 = #s{feed_registration_openings = Openings0}) ->
    case maps:get(OpenRef, Openings0, undefined) of
        Key = {{Ns, Anchor}, Peer} ->
            case Chan =:= quod_feed:channel(Ns) of
                true ->
                    Openings1 = maps:remove(OpenRef, Openings0),
                    case maps:get(Key, S0#s.feed_registrations, undefined) of
                        Registration = #feed_registration{
                                           open_ref = OpenRef,
                                           registration_id = RegistrationId} ->
                            MRef = erlang:monitor(process, Link),
                            quod_link:send_ordered(
                              Link,
                              quod_feed:recipient_register_frame(
                                Ns, Anchor, RegistrationId)),
                            Registration1 = Registration#feed_registration{
                                              open_ref = none, link = Link,
                                              mref = MRef, registered = false},
                            S0#s{
                              feed_registrations =
                                  (S0#s.feed_registrations)#{
                                    Key => Registration1},
                              feed_registration_openings = Openings1,
                              feed_registration_monitors =
                                  (S0#s.feed_registration_monitors)#{
                                    MRef => Key}};
                        _Stale ->
                            _ = quod_link:close(Link),
                            S0#s{feed_registration_openings = Openings1}
                    end;
                false ->
                    _ = quod_link:close(Link),
                    S0
            end;
        _CrossedOrStale ->
            _ = quod_link:close(Link),
            S0
    end.

fail_feed_registration_open(OpenRef, Peer, Chan,
                            S0 = #s{feed_registration_openings = Openings0}) ->
    case maps:get(OpenRef, Openings0, undefined) of
        Key = {{Ns, _Anchor}, Peer} ->
            case Chan =:= quod_feed:channel(Ns) of
                true ->
                    S1 = S0#s{
                           feed_registration_openings =
                               maps:remove(OpenRef, Openings0)},
                    case maps:get(Key, S1#s.feed_registrations, undefined) of
                        Registration = #feed_registration{
                                           open_ref = OpenRef} ->
                            open_next_feed_registration(
                              Registration#feed_registration{
                                open_ref = none}, S1);
                        _Stale ->
                            S1
                    end;
                false ->
                    S0
            end;
        _CrossedOrStale ->
            S0
    end.

feed_registration_down(MRef, Link,
                       S0 = #s{feed_registration_monitors = Monitors0}) ->
    case maps:take(MRef, Monitors0) of
        {Key = {Identity, Peer}, Monitors1} ->
            S1 = S0#s{feed_registration_monitors = Monitors1},
            case maps:get(Key, S1#s.feed_registrations, undefined) of
                Registration = #feed_registration{link = Link, mref = MRef} ->
                    Registration1 = Registration#feed_registration{
                                      current_endpoint = none,
                                      remaining = [], open_ref = none,
                                      link = none, mref = none,
                                      registered = false},
                    S2 = S1#s{feed_registrations =
                                  (S1#s.feed_registrations)#{
                                    Key => Registration1}},
                    case maps:get(
                           Peer,
                           desired_feed_registration_routes(Identity, S2),
                           []) of
                        [_ | _] = Endpoints ->
                            start_feed_registration(
                              Identity, Peer, Endpoints,
                              close_feed_registration_key(Key, S2));
                        [] ->
                            S2
                    end;
                _Stale ->
                    S1
            end;
        error ->
            S0
    end.

accept_feed_recipient_signal(Peer, Link, Identity = {Ns, Anchor},
                             RegistrationId, Height, S0)
  when is_integer(Height), Height >= 0 ->
    Key = {Identity, Peer},
    case maps:get(Key, S0#s.feed_registrations, undefined) of
        Registration = #feed_registration{
                           link = Link,
                           registration_id = RegistrationId} ->
            quod_link:send_ordered(
              Link,
              quod_feed:recipient_ack_frame(
                Ns, Anchor, RegistrationId, Height)),
            Registration1 = Registration#feed_registration{
                              registered = true, height = Height},
            S1 = note_feed_height(
                   Identity, Height,
                   S0#s{feed_registrations =
                            (S0#s.feed_registrations)#{
                              Key => Registration1}}),
            wake_follow(
              Identity, release_route_waiters(Identity, S1));
        _CrossedOrStale ->
            S0
    end;
accept_feed_recipient_signal(_Peer, _Link, _Identity,
                             _RegistrationId, _Height, S) ->
    S.

note_feed_height(Identity, Height, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{height = ResidentHeight, hinted_height = OldHint} = H0 ->
            Hint = case OldHint of
                       Known when is_integer(Known) -> max(Known, Height);
                       unknown -> Height
                   end,
            View = case Height > ResidentHeight of
                       true -> unconfirmed;
                       false -> H0#history.current_view
                   end,
            put_history(
              Identity,
              H0#history{hinted_height = Hint, current_view = View}, S0);
        undefined ->
            S0
    end.

close_identity_feed_registrations(Identity, S0) ->
    Keys = [Key
            || Key = {RegistrationIdentity, _Peer} <-
                   maps:keys(S0#s.feed_registrations),
               RegistrationIdentity =:= Identity],
    lists:foldl(fun close_feed_registration_key/2, S0, Keys).

close_feed_registration_key(
  Key, S0 = #s{feed_registrations = Registrations0,
               feed_registration_openings = Openings0,
               feed_registration_monitors = Monitors0}) ->
    case maps:take(Key, Registrations0) of
        {Registration = #feed_registration{open_ref = OpenRef,
                                           mref = MRef}, Registrations1} ->
            Openings1 = case OpenRef of
                            OpeningRef when is_reference(OpeningRef) ->
                                maps:remove(OpeningRef, Openings0);
                            none -> Openings0
                        end,
            Monitors1 = case MRef of
                            MonitorRef when is_reference(MonitorRef) ->
                                _ = erlang:demonitor(MonitorRef, [flush]),
                                maps:remove(MonitorRef, Monitors0);
                            none -> Monitors0
                        end,
            close_feed_registration(Registration),
            S0#s{feed_registrations = Registrations1,
                 feed_registration_openings = Openings1,
                 feed_registration_monitors = Monitors1};
        error ->
            S0
    end.

close_feed_registration(
  #feed_registration{identity = {Ns, Anchor},
                     registration_id = RegistrationId,
                     link = Link}) when is_pid(Link) ->
    quod_link:send_ordered(
      Link,
      quod_feed:recipient_unregister_frame(Ns, Anchor, RegistrationId)),
    _ = quod_link:close(Link),
    ok;
close_feed_registration(#feed_registration{}) ->
    ok.

handle_feed_signal(Peer, Link, Chan, Payload, S0) ->
    case maps:get(Chan, S0#s.progress_channels, undefined) of
        {Ns, _Count} ->
            case quod_feed:decode_recipient(Payload, Ns) of
                {registered, RegistrationId, Anchor, Height} ->
                    accept_feed_recipient_signal(
                      Peer, Link, {Ns, Anchor}, RegistrationId, Height, S0);
                {wake, RegistrationId, Anchor, Height} ->
                    accept_feed_recipient_signal(
                      Peer, Link, {Ns, Anchor}, RegistrationId, Height, S0);
                error ->
                    case quod_feed:progress_signal(Payload, Ns) of
                        true ->
                            wake_namespace_progress_from_peer(
                              Peer, Ns,
                              quod_feed:progress_height(Payload, Ns), S0);
                        false -> S0
                    end;
                %% Target-side controls are consumed by a hosted `quod_feed`.
                %% They must not masquerade as progress for this source owner.
                _TargetControl ->
                    S0
            end;
        undefined ->
            S0
    end.

wake_namespace_progress(Ns, _Height, S0) ->
    Identities =
        [Identity
         || {Identity = {HistoryNs, _Anchor},
             #history{progress_signals_open = true}} <-
                maps:to_list(S0#s.histories),
            HistoryNs =:= Ns],
    lists:foldl(
      fun(Identity, Acc) ->
              wake_follow(
                Identity,
                release_route_waiters(
                  Identity,
                  invalidate_current_view(Identity, Acc)))
      end, S0, Identities).

%% A generic feed block/digest carries no anchor. Correlate its authenticated
%% peer separately for every same-named identity and accept it only when that
%% peer belongs to the identity's latest certified committee. It remains a
%% freshness edge; the ordinary follower still verifies every fetched byte.
wake_namespace_progress_from_peer(Peer, Ns, Progress, S0) ->
    Identities =
        [Identity
         || {Identity = {HistoryNs, _Anchor},
             #history{progress_signals_open = true,
                      projection = Projection}} <-
                maps:to_list(S0#s.histories),
            HistoryNs =:= Ns,
            is_map(Projection),
            lists:member(
              Peer, quod_simplex:history_committee(Projection))],
    lists:foldl(
      fun(Identity, Acc) ->
              Acc1 = release_route_waiters(Identity, Acc),
              case progress_may_advance(Identity, Progress, Acc1) of
                  true ->
                      wake_follow(
                        Identity,
                        invalidate_current_view(Identity, Acc1));
                  false ->
                      Acc1
              end
      end, S0, Identities).

%% Digest heights are authenticated reachability/freshness hints, never
%% evidence. A height at or below the certified resident row cannot require
%% work. A newer height and every opaque block still wake the one verifier.
progress_may_advance(
  Identity, {ok, Height}, #s{histories = Histories}) ->
    case maps:get(Identity, Histories, undefined) of
        #history{height = ResidentHeight} when is_integer(ResidentHeight) ->
            Height > ResidentHeight;
        _ ->
            true
    end;
progress_may_advance(_Identity, unknown, _S) ->
    true;
progress_may_advance(_Identity, error, _S) ->
    false.

invalidate_current_view(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{current_watch = Watch} = H0 when Watch =/= none ->
            put_history(
              Identity, H0#history{current_view = unconfirmed}, S0);
        _ ->
            S0
    end.

handle_catchup_frame(Peer, Chan, Payload, S0) ->
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, _Count} ->
            case quod_catchup:decode_frame(Ns, Payload) of
                {ok, {blocks_resp, ReqId, Entries, Height}, InnerBytes}
                  when InnerBytes =< ?QUOD_TRANSPORT_MAX_FRAME_BYTES ->
                    reply_pull(Peer, ReqId, {ok, Entries, Height}, S0);
                {ok, {blocks_err, ReqId}, _InnerBytes} ->
                    reply_pull(Peer, ReqId, {error, retry}, S0);
                _ -> S0
            end;
        undefined -> S0
    end.

reply_pull(Peer, ReqId, Reply, S0) ->
    case maps:get(ReqId, S0#s.pulls, undefined) of
        #pull{peer = Peer, from = From, timer = Timer} ->
            _ = erlang:cancel_timer(Timer),
            gen_server:reply(From, Reply),
            S0#s{pulls = maps:remove(ReqId, S0#s.pulls)};
        _ ->
            S0
    end.

add_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        undefined ->
            true = quod_reg:subscribe({channel, Chan}),
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, 1}}};
        {Ns, Count} ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count + 1}}}
    end.

remove_channel(Ns, S0) ->
    Chan = quod_catchup:channel(Ns),
    case maps:get(Chan, S0#s.channels, undefined) of
        {Ns, 1} ->
            _ = catch quod_reg:unsubscribe({channel, Chan}),
            S0#s{channels = maps:remove(Chan, S0#s.channels)};
        {Ns, Count} when Count > 1 ->
            S0#s{channels = (S0#s.channels)#{Chan => {Ns, Count - 1}}};
        _ -> S0
    end.

%%%===================================================================
%%% Verification worker
%%%===================================================================

verification_worker(
  Owner, RequestRef, Work, Root, FetchFun, PageTimeout, RequestTimeout,
  Resident) ->
    %% Probe children are linked so killing a timed-out verification also
    %% kills every in-flight route fetch. Expected transport exits are
    %% normalized where the dependency is called; an internal fault takes
    %% down this monitored worker and remains visible to the runtime.
    StartedNative = erlang:monotonic_time(),
    Result0 = verification_work(
                Work, Owner, RequestRef, Root, FetchFun, PageTimeout,
                RequestTimeout, Resident),
    {Result, Meta0} = normalize_worker_result(Result0),
    Meta = close_worker_cache(Meta0),
    observe_foreign_stage(
      verification_stage(Work), foreign_result(Result), StartedNative),
    Owner ! {foreign_worker_done, RequestRef, Result, Meta}.

verification_stage({exact, _, _, _, _}) -> request_exact;
verification_stage({exact_routes, _, _, _, _}) -> request_exact;
verification_stage({current, _, _}) -> request_current;
verification_stage({current_identity, _, _}) -> request_current;
verification_stage({follow, _, _}) -> request_follow.

foreign_result({ok, _}) -> ok;
foreign_result({error, retry}) -> uncertain;
foreign_result({error, {unreachable, _}}) -> uncertain;
foreign_result({error, _}) -> failed.

observe_foreign_stage(Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_foreign_history_stage(
      Stage, Result, erlang:monotonic_time() - StartedNative).

verification_work(
  {exact, Peer, Endpoint, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout, Resident) ->
    verify_cached(
      Owner, RequestRef, Peer, Endpoint, Ref, Phase, ref_identity(Ref),
      Root, FetchFun, PageTimeout, true, false, Resident, none);
verification_work(
  {exact_routes, Routes, Ref, Phase, EntryHint}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, _RequestTimeout, Resident) ->
    verify_exact_routes(
      Routes, Owner, RequestRef, Ref, Phase, ref_identity(Ref),
      Root, FetchFun, PageTimeout, none, #{}, Resident, EntryHint);
verification_work(
  {current, Sources, Ref}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout, Resident) ->
    verify_current_cached(
      Owner, RequestRef, Sources, Ref, Root, FetchFun, PageTimeout,
      RequestTimeout, Resident);
verification_work(
  {current_identity, Sources, Identity}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout, Resident) ->
    certified_current_snapshot(
      Owner, RequestRef, Sources, Identity,
      Root, FetchFun, PageTimeout, RequestTimeout, Resident);
verification_work(
  {follow, Identity, Sources}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, RequestTimeout, Resident) ->
    follow_identity(
      Owner, RequestRef, Identity, Sources, Root, FetchFun,
      PageTimeout, RequestTimeout, Resident).

verify_exact_routes(
  [], _Owner, _RequestRef, _Ref, _Phase, _Identity,
  _Root, _FetchFun, _PageTimeout, none, Meta, _Resident, _EntryHint) ->
    {{error, retry}, Meta};
verify_exact_routes(
  [], _Owner, _RequestRef, _Ref, _Phase, _Identity,
  _Root, _FetchFun, _PageTimeout, definitive, Meta, _Resident, _EntryHint) ->
    {{error, invalid_foreign_reference}, Meta};
verify_exact_routes(
  [{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Phase, Identity,
  Root, FetchFun, PageTimeout, Prior, _Meta0, Resident, EntryHint) ->
    case verify_cached(
           Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
           Root, FetchFun, PageTimeout, true, false, Resident, EntryHint) of
        {{ok, _} = Result, Meta} ->
            {Result, Meta};
        {{error, Reason}, Meta}
          when Reason =:= phase_mismatch;
               Reason =:= invalid_foreign_reference ->
            verify_exact_routes(
              Rest, Owner, RequestRef, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, definitive, Meta, none,
              EntryHint);
        {{error, _}, Meta} ->
            verify_exact_routes(
              Rest, Owner, RequestRef, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, Prior, Meta, none, EntryHint)
    end.

normalize_worker_result({{ok, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta};
normalize_worker_result({{error, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta}.

%% A raw cache handle never crosses the worker boundary. The owner retains only
%% its immutable verified index; the next worker reopens the same append owner
%% in O(1), while a changed file falls back to ordinary recovery.
close_worker_cache(#{cache_store := Store} = Meta) ->
    Session = quod_ledger_store:snapshot(Store),
    _ = quod_ledger_store:close(Store),
    (maps:remove(cache_store, Meta))#{cache_session => Session};
close_worker_cache(Meta) ->
    Meta.

follow_identity(Owner, RequestRef, Identity = {Ns, _Anchor}, Sources, Root,
                FetchFun, PageTimeout, RequestTimeout, Resident) ->
    case quod_simplex:history_source(Identity, any) of
        {ok, LedgerRoot} ->
            LocalPeer = {local, Identity},
            LocalFetch =
                fun(_Peer, _Endpoint, RequestedNs, FromIndex, ToIndex) ->
                    case RequestedNs =:= Ns of
                        true -> quod_catchup:serve_blocks(
                                  Ns, LedgerRoot, FromIndex, ToIndex);
                        false -> {error, wrong_namespace}
                    end
                end,
            follow_local_snapshot(
              Owner, RequestRef, LocalPeer, LedgerRoot, Identity,
              Root, LocalFetch, PageTimeout, Resident);
        {error, _} ->
            case route_candidates(Sources) of
                [_ | _] ->
                    certified_current_snapshot(
                      Owner, RequestRef, Sources, Identity,
                      Root, FetchFun, PageTimeout, RequestTimeout, Resident,
                      one_page);
                [] ->
                    {{error, {unreachable, unavailable}}, #{}}
            end
    end.

follow_local_snapshot(Owner, RequestRef, LocalPeer, LedgerRoot,
                      Identity = {Ns, Anchor}, Root, FetchFun, PageTimeout,
                      Resident) ->
    case quod_ledger_store:open_ro(Ns, LedgerRoot) of
        {ok, Source} ->
            Tip = quod_ledger_store:last(Source),
            _ = quod_ledger_store:close(Source),
            case open_cache(
                   Owner, RequestRef, Identity, Root, none, Resident) of
                {ok, Store0, Height0, Projection0, PhaseIndex, _} ->
                    Outcome =
                        case Tip > Height0 of
                            true ->
                                Target = min(
                                           Tip,
                                           Height0 +
                                               ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
                                advance_snapshot_sources(
                                  [{LocalPeer, local}], Owner, RequestRef,
                                  Ns, Anchor, Identity, Store0, Height0,
                                  Projection0, PhaseIndex, Root, Target,
                                  FetchFun, PageTimeout);
                            false ->
                                {ok, Store0, Height0, Projection0}
                        end,
                    case Outcome of
                        {ok, Store1, Height1, Projection1} ->
                            PhaseSession = suspend_phase_session(PhaseIndex),
                            View = case Height1 >= Tip of
                                       true -> confirmed;
                                       false -> unconfirmed
                                   end,
                            Evidence = (current_view_evidence(
                                          Identity, Height1, Projection1,
                                          current_route_candidates(
                                            empty_route_sources(),
                                            Projection1)))#{
                                         hinted_height => Tip,
                                         current_view => View},
                            {{ok, Evidence},
                             #{height => Height1,
                               bytes => cache_persisted_bytes(
                                          Root, cache_namespace(Identity)),
                               projection => Projection1,
                               phase_session => PhaseSession,
                               cache_store => Store1}};
                        {error, _} ->
                            _ = quod_ledger_store:close(Store0),
                            close_phase_session(PhaseIndex),
                            {{error, retry},
                             #{height => Height0,
                               bytes => cache_persisted_bytes(
                                          Root, cache_namespace(Identity)),
                               projection => Projection0}}
                    end;
                {error, _} ->
                    {{error, retry}, #{}}
            end;
        _ ->
            {{error, {unreachable, unavailable}}, #{}}
    end.

verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried, Resident,
              EntryHint) ->
    Slot = ref_slot(Ref),
    case open_cache(Owner, RequestRef, Identity, Root, Slot, Resident) of
        {ok, Store0, Height0, Projection0, PhaseIndex, SlotProjection0} ->
            Outcome = case fetch_exact_reference(
                                 Owner, RequestRef, Peer, Endpoint, Ref,
                                 Phase, Identity, Store0, Height0,
                                 Projection0, SlotProjection0, PhaseIndex,
                                 Root, FetchFun, PageTimeout, EntryHint) of
                              {ok, Store1, CacheHeight, CacheProjection,
                               {projection, EvidenceProjection}} ->
                                  {verified,
                                   verify_reference_source(
                                     Peer,
                                     verify_exact_reference(
                                       Store1, Ref, Phase,
                                       EvidenceProjection),
                                     RequirePeer),
                                   Store1, CacheHeight, CacheProjection};
                              {ok, Store1, CacheHeight, CacheProjection,
                               {evidence, Evidence}} ->
                                  {verified,
                                   verify_reference_source(
                                     Peer, {ok, Evidence}, RequirePeer),
                                   Store1, CacheHeight, CacheProjection};
                              Other -> Other
            end,
            case Outcome of
                {verified, Result = {ok, _}, VerifiedStore, VerifiedHeight,
                 VerifiedProjection} ->
                    PhaseSession = suspend_phase_session(PhaseIndex),
                    Bytes = cache_persisted_bytes(
                              Root, cache_namespace(Identity)),
                    {Result,
                     #{height => VerifiedHeight, bytes => Bytes,
                       projection => VerifiedProjection,
                       phase_session => PhaseSession,
                       cache_store => VerifiedStore}};
                {verified, Result, _VerifiedStore, VerifiedHeight,
                 VerifiedProjection} ->
                    _ = quod_ledger_store:close(Store0),
                    close_phase_session(PhaseIndex),
                    Bytes = cache_persisted_bytes(
                              Root, cache_namespace(Identity)),
                    {Result,
                     #{height => VerifiedHeight, bytes => Bytes,
                       projection => VerifiedProjection}};
                {error, cache_corrupt} ->
                    _ = quod_ledger_store:close(Store0),
                    close_phase_session(PhaseIndex),
                    retry_corrupt_cache(
                      Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                      Identity, Root, FetchFun, PageTimeout,
                      RequirePeer, Retried, EntryHint);
                {error, _} ->
                    _ = quod_ledger_store:close(Store0),
                    close_phase_session(PhaseIndex),
                    {{error, retry},
                     #{height => Height0,
                       bytes => cache_persisted_bytes(
                                  Root, cache_namespace(Identity)),
                       projection => Projection0}}
            end;
        {error, cache_corrupt} ->
            retry_corrupt_cache(
              Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, RequirePeer, Retried, EntryHint);
        {error, _} ->
            {{error, retry}, #{}}
    end.

retry_corrupt_cache(_Owner, _RequestRef, _Peer, _Endpoint, _Ref, _Phase,
                    _Identity, _Root, _FetchFun, _PageTimeout,
                    _RequirePeer, true, _EntryHint) ->
    {{error, retry}, #{}};
retry_corrupt_cache(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                    Identity, Root, FetchFun, PageTimeout,
                    RequirePeer, false, EntryHint) ->
    case gen_server:call(Owner, {reset_cache, RequestRef}) of
        ok ->
            _ = file:del_dir_r(
                  cache_dir(Root, cache_namespace(Identity))),
            verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                          Identity, Root, FetchFun, PageTimeout,
                          RequirePeer, true, none, EntryHint);
        {error, _} ->
            {{error, retry}, #{}}
    end.

verify_current_cached(
  Owner, RequestRef, Sources, Ref, Root, FetchFun, PageTimeout,
  RequestTimeout, Resident) ->
    Identity = ref_identity(Ref),
    Routes = flatten_route_candidates(route_candidates(Sources)),
    Deadline = quod_time:mono_ms() + RequestTimeout,
    case verify_current_reference(
           Routes, Owner, RequestRef, Ref, Identity,
           Root, FetchFun, PageTimeout, Deadline, Resident) of
        {{ok, _FinalizeEvidence}, Meta} ->
            certified_current_snapshot(
              Owner, RequestRef, Sources, Identity,
              Root, FetchFun, PageTimeout, RequestTimeout,
              resident_from_meta(Meta));
        {{error, _} = Error, Meta} ->
            {Error, Meta}
    end.

verify_current_reference(
  [], _Owner, _RequestRef, _Ref, _Identity,
  _Root, _FetchFun, _PageTimeout, _Deadline, _Resident) ->
    {{error, retry}, #{}};
verify_current_reference(
  [{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Identity,
  Root, FetchFun, PageTimeout, Deadline, Resident) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    case Remaining of
        0 ->
            {{error, retry}, #{}};
        _ ->
            %% Reserve time for at least one fallback. Fast failures may walk
            %% more keys, but one dead live contact cannot consume the whole
            %% verification deadline before its certified address is tried.
            AttemptTimeout = min(
                               PageTimeout,
                               max(1, Remaining div min(2, length(Rest) + 1))),
            case verify_cached(
                   Owner, RequestRef, Peer, Endpoint, Ref, finalize, Identity,
                   Root, FetchFun, AttemptTimeout, false, false, Resident,
                   none) of
                {{ok, _} = Ok, Meta} ->
                    {Ok, Meta};
                {{error, retry}, _Meta} ->
                    verify_current_reference(
                      Rest, Owner, RequestRef, Ref, Identity,
                      Root, FetchFun, PageTimeout, Deadline, none);
                Definitive ->
                    Definitive
            end
    end.

resident_from_meta(
  #{height := Height, projection := Projection,
    phase_session := PhaseSession, cache_store := Store})
  when is_integer(Height), is_map(Projection), PhaseSession =/= none ->
    {verified_store, Height, Projection, PhaseSession, Store};
resident_from_meta(
  #{height := Height, projection := Projection,
    phase_session := PhaseSession})
  when is_integer(Height), is_map(Projection), PhaseSession =/= none ->
    {verified, Height, Projection, PhaseSession};
resident_from_meta(_Meta) ->
    none.

certified_current_snapshot(
  Owner, RequestRef, Sources, Identity,
  Root, FetchFun, PageTimeout, RequestTimeout, Resident) ->
    certified_current_snapshot(
      Owner, RequestRef, Sources, Identity,
      Root, FetchFun, PageTimeout, RequestTimeout, Resident, to_tip).

certified_current_snapshot(
  Owner, RequestRef, Sources, Identity = {Ns, Anchor},
  Root, FetchFun, PageTimeout, RequestTimeout, Resident, AdvanceMode) ->
    case open_cache(Owner, RequestRef, Identity, Root, none, Resident) of
        {ok, Store0, Height0, Projection0, PhaseIndex, _RefProjection} ->
            Outcome =
                begin
                    Hints = current_route_candidates(Sources, Projection0),
                    case advance_current_snapshot(
                           Owner, RequestRef, Hints, Identity, Store0,
                           Height0, Projection0, PhaseIndex, Root,
                           FetchFun, PageTimeout, RequestTimeout,
                           AdvanceMode) of
                        {ok, Store1, Height1, Projection1} ->
                            ConfirmHints = current_route_candidates(
                                             Sources, Projection1),
                            case current_view_confirmed(
                                   Owner, RequestRef, ConfirmHints, Ns,
                                   Anchor, Identity, Height1, Projection1,
                                   PhaseIndex,
                                   FetchFun, PageTimeout) of
                                true ->
                                    {ok, current_view_evidence(
                                           Identity, Height1, Projection1,
                                           ConfirmHints),
                                     Store1, Height1, Projection1};
                                false ->
                                    {unconfirmed, Store1, Height1, Projection1}
                            end;
                        {error, _} = Error ->
                            Error
                    end
                end,
            Successful = is_successful_current_outcome(Outcome),
            case Successful of
                true -> ok;
                false -> _ = quod_ledger_store:close(Store0)
            end,
            finish_phase_session(
              Successful, PhaseIndex,
              current_snapshot_result(Outcome, Root, Identity,
                                      Height0, Projection0));
        {error, _} ->
            {{error, retry}, #{}}
    end.

current_snapshot_result(
  {ok, Evidence, Store, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{ok, Evidence},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection,
       cache_store => Store}};
current_snapshot_result(
  {unconfirmed, _Store, Height, Projection}, Root, Identity,
  _OldHeight, _OldProjection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}};
current_snapshot_result(
  {error, _}, Root, Identity, Height, Projection) ->
    {{error, retry},
     #{height => Height,
       bytes => cache_persisted_bytes(Root, cache_namespace(Identity)),
       projection => Projection}}.

open_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident) ->
    StartedNative = erlang:monotonic_time(),
    Result = open_cache_raw(
               Owner, RequestRef, Identity, Root, TargetSlot, Resident),
    observe_foreign_stage(cache_open, cache_result(Result), StartedNative),
    Result.

open_cache_raw(_Owner, _RequestRef, Identity, _Root, TargetSlot,
               {verified_store, Height, Projection, PhaseSession, Store}) ->
    CacheNs = cache_namespace(Identity),
    case retained_cache_matches(
           Store, CacheNs, Height, Projection, Identity) of
        true ->
            case quod_dtx_phase_index:resume(PhaseSession) of
                {ok, PhaseIndex} ->
                    {ok, Store, Height, Projection, PhaseIndex,
                     resident_target_projection(
                       TargetSlot, Height, Projection)};
                {error, _} ->
                    _ = quod_ledger_store:close(Store),
                    {error, cache_corrupt}
            end;
        false ->
            _ = quod_ledger_store:close(Store),
            discard_resident_phase(
              {verified, Height, Projection, PhaseSession}),
            {error, cache_corrupt}
    end;
open_cache_raw(Owner, RequestRef, Identity, Root, TargetSlot,
               {verified_session, Height, Projection,
                PhaseSession, CacheSession}) ->
    CacheNs = cache_namespace(Identity),
    case quod_ledger_store:resume(CacheSession) of
        {ok, Store} ->
            case retained_cache_matches(
                   Store, CacheNs, Height, Projection, Identity) of
                true ->
                    case quod_dtx_phase_index:resume(PhaseSession) of
                        {ok, PhaseIndex} ->
                            {ok, Store, Height, Projection, PhaseIndex,
                             resident_target_projection(
                               TargetSlot, Height, Projection)};
                        {error, _} ->
                            _ = quod_ledger_store:close(Store),
                            {error, cache_corrupt}
                    end;
                false ->
                    _ = quod_ledger_store:close(Store),
                    {error, cache_corrupt}
            end;
        {error, _} ->
            close_phase_session(PhaseSession),
            open_cache_raw(
              Owner, RequestRef, Identity, Root, TargetSlot, none)
    end;
open_cache_raw(Owner, RequestRef, Identity = {Ns, Anchor}, Root, TargetSlot,
               Resident) ->
    CacheNs = cache_namespace(Identity),
    Dir = cache_dir(Root, CacheNs),
    ok = cleanup_cache_temps(Dir),
    case ensure_manifest(Owner, RequestRef, Root, Identity, CacheNs) of
        ok ->
            try quod_ledger_store:open(CacheNs, Root) of
                {ok, Store} ->
                    Height = quod_ledger_store:last(Store),
                    case load_checkpoint(Root, Identity, CacheNs, Height) of
                        {ok, CheckpointProjection} ->
                            open_cache_projection(
                              Root, CacheNs, Ns, Anchor, Store,
                              Height, CheckpointProjection,
                              TargetSlot, Resident);
                        new when Height =:= 0 ->
                            discard_resident_phase(Resident),
                            case fresh_phase_index(Root, CacheNs) of
                                {ok, PhaseIndex} ->
                                    Projection = quod_simplex:history_projection(
                                                   {Ns, Anchor}),
                                    {ok, Store, 0, Projection, PhaseIndex,
                                     undefined};
                                {error, _} ->
                                    _ = quod_ledger_store:close(Store),
                                    {error, cache_io}
                            end;
                        _ ->
                            _ = quod_ledger_store:close(Store),
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_corrupt}
    end.

retained_cache_matches(Store, CacheNs, Height, Projection, Identity) ->
    try quod_ledger_store:namespace(Store) =:= CacheNs andalso
        quod_ledger_store:last(Store) =:= Height andalso
        valid_projection(Projection, Identity)
    catch _:_ -> false
    end.

open_cache_projection(
  Root, CacheNs, Ns, Anchor, Store, Height, CheckpointProjection,
  TargetSlot, Resident) ->
    case resident_projection(
           Resident, Height, CheckpointProjection, TargetSlot,
           {Ns, Anchor}) of
        {ok, Projection, TargetProjection} ->
            case resume_resident_phase(Resident) of
                {ok, PhaseIndex} ->
                    {ok, Store, Height, Projection, PhaseIndex,
                     TargetProjection};
                {error, _} ->
                    open_replayed_cache(
                      Root, CacheNs, Ns, Anchor, Store, Height,
                      CheckpointProjection, TargetSlot)
            end;
        replay ->
            discard_resident_phase(Resident),
            open_replayed_cache(
              Root, CacheNs, Ns, Anchor, Store, Height,
              CheckpointProjection, TargetSlot)
    end.

open_replayed_cache(Root, CacheNs, Ns, Anchor, Store, Height,
                    CheckpointProjection, TargetSlot) ->
    case fresh_phase_index(Root, CacheNs) of
        {ok, PhaseIndex} ->
            Projection0 = quod_simplex:history_projection({Ns, Anchor}),
            StartedNative = erlang:monotonic_time(),
            ReplayResult = replay_cache(
                             Root, CacheNs, Ns, Anchor, Height,
                             Projection0, PhaseIndex, TargetSlot),
            observe_foreign_stage(
              cache_replay, cache_result(ReplayResult), StartedNative),
            case ReplayResult of
                {ok, Projection, TargetProjection} ->
                    case checkpoint_projection(Projection) of
                        CheckpointProjection ->
                            {ok, Store, Height, Projection,
                             PhaseIndex, TargetProjection};
                        _Different ->
                            close_cache(Store, PhaseIndex, cache_corrupt)
                    end;
                {error, retry} ->
                    close_cache(Store, PhaseIndex, retry);
                {error, _} ->
                    close_cache(Store, PhaseIndex, cache_corrupt)
            end;
        {error, _} ->
            _ = quod_ledger_store:close(Store),
            {error, cache_io}
    end.

fresh_phase_index(Root, CacheNs) ->
    _ = quod_dtx_phase_index:cleanup(Root, CacheNs),
    quod_dtx_phase_index:open(Root, CacheNs).

resume_resident_phase({verified, _Height, _Projection, PhaseSession}) ->
    quod_dtx_phase_index:resume(PhaseSession);
resume_resident_phase(_) ->
    {error, bad_phase_index_argument}.

discard_resident_phase({verified, _Height, _Projection, PhaseSession}) ->
    close_phase_session(PhaseSession);
discard_resident_phase(_) -> ok.

%% A resident projection and its suspended phase index were produced together
%% by this running owner from the exact durable prefix whose checkpoint still
%% matches.  The phase index is the missing state needed to continue through an
%% unfinished DTX group, so replaying that same prefix would only duplicate
%% verified work.
%%
%% An exact reference below the resident head is already inside that certified
%% prefix. Its slot, block hash, and record digest are checked against the
%% retained ledger entry. The exact-reference verifier uses the projection's
%% committee-era index once to restore the post-slot committee, id, and route
%% hints. Therefore exact lookups may reuse the current projection in either
%% arrival order without making validity depend on the verifier's cache head.
resident_projection(
  {verified, Height, Projection, PhaseSession}, Height, CheckpointProjection,
  TargetSlot, Identity) when PhaseSession =/= none ->
    case valid_projection(Projection, Identity) andalso
         checkpoint_projection(Projection) =:= CheckpointProjection of
        true ->
            {ok, Projection,
             resident_target_projection(TargetSlot, Height, Projection)};
        false -> replay
    end;
resident_projection(_Resident, _Height, _Projection, _TargetSlot, _Identity) ->
    replay.

close_cache(Store, PhaseIndex, Reason) ->
    _ = quod_dtx_phase_index:close(PhaseIndex),
    _ = quod_ledger_store:close(Store),
    {error, Reason}.

-ifdef(TEST).
test_resident_projection(Resident, Height, Projection, TargetSlot, Identity) ->
    resident_projection(Resident, Height, Projection, TargetSlot, Identity).
-endif.

replay_cache(_Root, _CacheNs, _Ns, _Anchor, 0, Projection, _PhaseIndex,
             _TargetSlot) ->
    {ok, Projection, undefined};
replay_cache(Root, CacheNs, Ns, Anchor, Height, Projection0, PhaseIndex,
             TargetSlot) ->
    replay_cache(Root, CacheNs, Ns, Anchor, 1, Height, Projection0,
                 PhaseIndex, TargetSlot, undefined).

replay_cache(_Root, _CacheNs, Ns, Anchor, From, Height, Projection,
             _PhaseIndex, TargetSlot, TargetProjection)
  when From > Height ->
    TargetOk = case TargetSlot of
                   none -> true;
                   _ -> TargetSlot > Height orelse
                            valid_projection(
                              TargetProjection, {Ns, Anchor})
               end,
    case valid_projection(Projection, {Ns, Anchor}) andalso TargetOk of
        true -> {ok, Projection, TargetProjection};
        false -> {error, cache_corrupt}
    end;
replay_cache(Root, CacheNs, Ns, Anchor, From, Height, Projection0, PhaseIndex,
             TargetSlot, TargetProjection0) ->
    WindowTo = min(Height, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
    %% End one replay window exactly at the requested reference slot so the
    %% evidence projection is the post-slot state even when this durable cache
    %% has already advanced beyond it.
    To = case is_integer(TargetSlot) andalso
                  TargetSlot >= From andalso TargetSlot < WindowTo of
             true -> TargetSlot;
             false -> WindowTo
         end,
    %% The network owner originally persisted this history in pages bounded by
    %% both entry count and encoded bytes. Reopening must use that same page
    %% owner: a count-bounded range can still exceed the byte ceiling when it
    %% contains many large, individually valid entries. `serve_blocks/4`
    %% returns the longest safe prefix, so replay advances by the actual page
    %% length and never mistakes a valid cache for corruption.
    try quod_catchup:serve_blocks(CacheNs, Root, From, To) of
        {ok, Entries, Height} ->
            case quod_catchup:page_stats(Entries) of
                {ok, Count, _Bytes}
                  when Count > 0, Count =< To - From + 1 ->
                    PageTo = From + Count - 1,
                    case quod_catchup:verify_forward(
                           Ns, Anchor, Projection0, From, Entries,
                           PhaseIndex) of
                        {ok, _Verified, Projection1, Delta} ->
                            case valid_projection(Projection1, {Ns, Anchor})
                                 andalso quod_dtx_phase_index:commit_delta(
                                           PhaseIndex, Delta) =:= ok of
                                true ->
                                    TargetProjection1 =
                                        case is_integer(TargetSlot) andalso
                                                  PageTo =:= TargetSlot of
                                            true -> Projection1;
                                            false -> TargetProjection0
                                        end,
                                    replay_cache(
                                      Root, CacheNs, Ns, Anchor, PageTo + 1,
                                      Height, Projection1, PhaseIndex,
                                      TargetSlot, TargetProjection1);
                                false -> {error, cache_corrupt}
                            end;
                        {error, {unavailable, network_identity, _Reason}} ->
                            {error, retry};
                        {error, _} -> {error, cache_corrupt}
                    end;
                _ -> {error, cache_corrupt}
            end
    catch _:_ ->
        {error, cache_corrupt}
    end.

fetch_exact_reference(
  Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
  Store0, Height0, Projection0, SlotProjection0, PhaseIndex,
  Root, FetchFun, PageTimeout, EntryHint) ->
    Slot = ref_slot(Ref),
    case EntryHint of
        #entry{index = Slot} when Height0 < Slot ->
            case fetch_hint_parent(
                   Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                   Store0, Height0, Projection0, PhaseIndex, Root,
                   FetchFun, PageTimeout) of
                {ok, Store1, Height1, Projection1} ->
                    case import_exact_entry_hint(
                           Owner, RequestRef, Ref, Phase, Identity,
                           Store1, Height1, Projection1, PhaseIndex,
                           Root, EntryHint) of
                        {ok, _Store2, _Height2, _Projection2,
                         {evidence, _Evidence}} = Ok ->
                            Ok;
                        fallback ->
                            fetch_exact_from_cache(
                              Owner, RequestRef, Peer, Endpoint, Slot,
                              Identity, Store1, Height1, Projection1,
                              undefined, PhaseIndex, Root, FetchFun,
                              PageTimeout);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            fetch_exact_from_cache(
              Owner, RequestRef, Peer, Endpoint, Slot, Identity,
              Store0, Height0, Projection0, SlotProjection0, PhaseIndex,
              Root, FetchFun, PageTimeout)
    end.

fetch_hint_parent(
  _Owner, _RequestRef, _Peer, _Endpoint, Slot, _Identity,
  Store, Height, Projection, _PhaseIndex, _Root, _FetchFun, _PageTimeout)
  when Height =:= Slot - 1 ->
    {ok, Store, Height, Projection};
fetch_hint_parent(
  Owner, RequestRef, Peer, Endpoint, Slot, Identity,
  Store0, Height0, Projection0, PhaseIndex, Root, FetchFun, PageTimeout) ->
    case fetch_to_height(
           Owner, RequestRef, Peer, Endpoint, Slot - 1, Identity,
           Store0, Height0, Projection0, undefined, PhaseIndex, Root,
           FetchFun, PageTimeout) of
        {ok, Store1, Height1, Projection1, _ParentProjection}
          when Height1 =:= Slot - 1 ->
            {ok, Store1, Height1, Projection1};
        {ok, _Store1, _Height1, _Projection1, _ParentProjection} ->
            {error, retry};
        {error, _} = Error ->
            Error
    end.

import_exact_entry_hint(
  Owner, RequestRef, Ref, Phase, Identity = {Ns, Anchor},
  Store0, Height0, Projection0, PhaseIndex, Root,
  #entry{index = Slot} = Entry) when Height0 =:= Slot - 1 ->
    case prepare_verified_page(
           Ns, Anchor, Identity, Projection0, PhaseIndex,
           Slot, Slot, [Entry], Slot) of
        {ok, #{verified := [VerifiedEntry], projection := Projection1} =
               Prepared} ->
            case verify_exact_reference_entry(
                   Ref, Phase, VerifiedEntry, Projection1) of
                {ok, Evidence} ->
                    case persist_verified_page(
                           Owner, RequestRef, Identity, Store0, Height0,
                           PhaseIndex, Root, Prepared) of
                        {ok, Store1, Slot, Projection1} ->
                            {ok, Store1, Slot, Projection1,
                             {evidence, Evidence}};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} ->
                    fallback
            end;
        {error, _} ->
            fallback
    end;
import_exact_entry_hint(
  _Owner, _RequestRef, _Ref, _Phase, _Identity,
  _Store, _Height, _Projection, _PhaseIndex, _Root, _Entry) ->
    fallback.

fetch_exact_from_cache(
  Owner, RequestRef, Peer, Endpoint, Slot, Identity,
  Store0, Height0, Projection0, SlotProjection0, PhaseIndex,
  Root, FetchFun, PageTimeout) ->
    case fetch_to_height(
           Owner, RequestRef, Peer, Endpoint, Slot, Identity,
           Store0, Height0, Projection0, SlotProjection0, PhaseIndex,
           Root, FetchFun, PageTimeout) of
        {ok, Store1, Height1, Projection1, EvidenceProjection} ->
            {ok, Store1, Height1, Projection1,
             {projection, EvidenceProjection}};
        {error, _} = Error ->
            Error
    end.

fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot,
                Identity = {Ns, Anchor}, Store0, Height0, Projection0,
                SlotProjection0, PhaseIndex, Root, FetchFun, PageTimeout) ->
    case Height0 >= Slot of
        true when is_map(SlotProjection0) ->
            {ok, Store0, Height0, Projection0, SlotProjection0};
        true ->
            {error, cache_corrupt};
        false ->
            From = Height0 + 1,
            To = min(Slot, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
            case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                            From, To, FetchFun, PageTimeout) of
                {ok, Entries, RemoteHeight} when is_integer(RemoteHeight),
                                                  RemoteHeight >= 0 ->
                    case prepare_verified_page(
                           Ns, Anchor, Identity, Projection0, PhaseIndex,
                           From, To, Entries, RemoteHeight) of
                        {ok, Prepared} ->
                            case persist_verified_page(
                                   Owner, RequestRef, Identity, Store0,
                                   Height0, PhaseIndex, Root, Prepared) of
                                {ok, Store1, Height1, Projection1} ->
                                    SlotProjection1 =
                                        case Height1 =:= Slot of
                                            true -> Projection1;
                                            false -> undefined
                                        end,
                                    fetch_to_height(
                                      Owner, RequestRef, Peer, Endpoint, Slot,
                                      Identity, Store1, Height1, Projection1,
                                      SlotProjection1, PhaseIndex, Root,
                                      FetchFun, PageTimeout);
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                _ ->
                    {error, retry}
            end
    end.

prepare_verified_page(
  Ns, Anchor, Identity, Projection0, PhaseIndex,
  From, To, Entries, RemoteHeight) ->
    case validate_page(Entries, From, To, RemoteHeight) of
        {ok, Count, EntryBytes} ->
            case quod_catchup:verify_forward(
                   Ns, Anchor, Projection0, From, Entries, PhaseIndex) of
                {ok, Verified, Projection1, Delta}
                  when length(Verified) =:= Count ->
                    case valid_projection(Projection1, Identity) of
                        true ->
                            {ok, #{verified => Verified,
                                   projection => Projection1,
                                   phase_delta => Delta,
                                   count => Count,
                                   stored_bytes => EntryBytes + 12 * Count}};
                        false ->
                            {error, invalid_history}
                    end;
                {error, {unavailable, network_identity, _Reason}} = Global ->
                    Global;
                {error, _Reason} ->
                    {error, invalid_history}
            end;
        {error, _} ->
            {error, invalid_history}
    end.

persist_verified_page(
  Owner, RequestRef, Identity, Store0, Height0, PhaseIndex, Root,
  #{verified := Verified, projection := Projection1,
    phase_delta := Delta, count := Count, stored_bytes := StoredBytes}) ->
    %% The checkpoint replaces its predecessor after the append. Reserve its
    %% complete maximum before either durable allocation, then reconcile to
    %% the exact persisted bytes after the atomic rename.
    Reservation = StoredBytes + ?QUOD_MAX_FOREIGN_PAGE_BYTES,
    case gen_server:call(
           Owner, {reserve_page, RequestRef, Reservation}) of
        ok ->
            try quod_ledger_store:append(Store0, Verified) of
                {ok, Store1} ->
                    case quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) of
                        ok ->
                            Height1 = Height0 + Count,
                            case write_checkpoint(
                                   Root, Identity, cache_namespace(Identity),
                                   Height1, Projection1) of
                                ok ->
                                    ActualBytes = cache_persisted_bytes(
                                                    Root,
                                                    cache_namespace(Identity)),
                                    case gen_server:call(
                                           Owner,
                                           {set_cache_size, RequestRef,
                                            ActualBytes}) of
                                        ok ->
                                            {ok, Store1, Height1, Projection1};
                                        {error, _} ->
                                            {error, cache_corrupt}
                                    end;
                                {error, _} ->
                                    {error, cache_corrupt}
                            end;
                        {error, _} ->
                            {error, cache_corrupt}
                    end
            catch _:_ ->
                {error, cache_corrupt}
            end;
        {error, _} ->
            {error, cache_unavailable}
    end.

current_route_candidates(
  #{live := Live, supplied := Supplied,
    bootstrap := Bootstrap}, Projection) ->
    Committee = quod_simplex:history_committee(Projection),
    case Committee of
        [] -> discovery_route_candidates(Live, Supplied, Bootstrap);
        [_ | _] ->
            Certified = quod_simplex:history_validator_routes(Projection),
            CertifiedEndpoints = maps:from_keys(
                                   maps:values(Certified), true),
            lists:filtermap(
              fun(Peer) ->
                  Endpoints = current_peer_endpoints(
                                Peer, Bootstrap, Live, Supplied,
                                Certified, CertifiedEndpoints),
                  case Endpoints of
                      [] -> false;
                      [_ | _] -> {true, {Peer, Endpoints}}
                  end
              end, Committee)
    end.

current_peer_endpoints(Peer, Bootstrap, Live, Supplied,
                       Certified, CertifiedEndpoints) ->
    Historical = maps:get(Peer, Certified, none),
    LiveEndpoint = first_live_endpoint(Peer, Bootstrap, Live),
    ThirdParty = permitted_supplied_endpoint(
                   Peer, Historical, Supplied, CertifiedEndpoints),
    lists:sublist(
      lists:uniq(
        [Endpoint || Endpoint <- [LiveEndpoint, Historical, ThirdParty],
                     Endpoint =/= none]),
      2).

empty_route_sources() ->
    #{live => [], supplied => [], bootstrap => [],
      projection => undefined}.

first_live_endpoint(Peer, Bootstrap, Directory) ->
    case first_peer_endpoint(Peer, Bootstrap) of
        none ->
            case quod_quic:resolve(Peer) of
                {ok, Endpoint} -> Endpoint;
                _ -> first_peer_endpoint(Peer, Directory)
            end;
        Endpoint -> Endpoint
    end.

first_peer_endpoint(Peer, Routes) ->
    case lists:keyfind(Peer, 1, Routes) of
        {Peer, Endpoint} -> Endpoint;
        false -> none
    end.

permitted_supplied_endpoint(_Peer, Historical, _Supplied,
                            _CertifiedEndpoints)
  when Historical =/= none ->
    none;
permitted_supplied_endpoint(Peer, none, Supplied, CertifiedEndpoints) ->
    case first_peer_endpoint(Peer, Supplied) of
        none -> none;
        Endpoint ->
            case maps:is_key(Endpoint, CertifiedEndpoints) of
                true -> none;
                false -> Endpoint
            end
    end.

stable_unique_routes(Routes) ->
    lists:uniq(fun({PeerKey, _Endpoint}) -> PeerKey end, Routes).

flatten_route_candidates(Candidates) ->
    [{Peer, Endpoint}
     || {Peer, Endpoints} <- Candidates,
        Endpoint <- Endpoints].

advance_current_snapshot(
  Owner, RequestRef, Hints, Identity, Store0, Height0, Projection0,
  PhaseIndex, Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode) ->
    case maps:size(quod_simplex:history_validator_routes(Projection0)) of
        0 ->
            bootstrap_snapshot_sources(
              flatten_route_candidates(Hints),
              Owner, RequestRef, Identity, Store0, Height0,
              Projection0, PhaseIndex, Root, FetchFun,
              bootstrap_route_timeout(
                PageTimeout, RequestTimeout,
                length(flatten_route_candidates(Hints))),
              PageTimeout, AdvanceMode);
        _ ->
            {Ns, _Anchor} = Identity,
            Results = probe_pages(
                        Owner, RequestRef, Hints, Ns, Height0,
                        FetchFun, PageTimeout),
            advance_snapshot(
              Owner, RequestRef, Identity, Store0, Height0, Projection0,
              PhaseIndex, Root, Results, FetchFun, PageTimeout, AdvanceMode)
    end.

bootstrap_route_timeout(PageTimeout, RequestTimeout, RouteCount) ->
    %% Discovery gets at most half the request. The remaining half is reserved
    %% for downloading and verifying the selected history and corroborating
    %% its resulting committee view.
    PerRoute = erlang:max(1, RequestTimeout div (2 * erlang:max(1, RouteCount))),
    erlang:min(PageTimeout, PerRoute).

%% Before genesis is replayed every route is only a discovery hint. Trying
%% them concurrently lets contradictory credentials for one address contend
%% during first contact. Walk the bounded list instead: a source must deliver
%% a page that passes the ordinary certificate/history fold before it wins.
bootstrap_snapshot_sources(
  [], _Owner, _RequestRef, _Identity, _Store, _Height, _Projection,
  _PhaseIndex, _Root, _FetchFun, _BootstrapTimeout, _PageTimeout,
  _AdvanceMode) ->
    {error, invalid_history};
bootstrap_snapshot_sources(
  [Source | Rest], Owner, RequestRef,
  Identity, Store0, Height0, Projection0, PhaseIndex,
  Root, FetchFun, BootstrapTimeout, PageTimeout, AdvanceMode) ->
    case bootstrap_snapshot_source(
           Source, Owner, RequestRef, Identity, Store0, Height0,
           Projection0, PhaseIndex, Root, FetchFun, BootstrapTimeout,
           PageTimeout, AdvanceMode) of
        {ok, _Store1, _Height1, _Projection1} = Ok -> Ok;
        {error, {unavailable, network_identity, _}} = Global -> Global;
        {error, Reason} ->
            logger:debug(
              "foreign history bootstrap source failed identity=~p "
              "source=~p reason=~p",
              [Identity, Source, Reason]),
            bootstrap_snapshot_sources(
              Rest, Owner, RequestRef, Identity, Store0, Height0,
              Projection0, PhaseIndex, Root, FetchFun, BootstrapTimeout,
              PageTimeout, AdvanceMode)
    end.

bootstrap_snapshot_source(
  Source = {Peer, Endpoint}, Owner, RequestRef,
  Identity = {Ns, Anchor}, Store0, Height0, Projection0, PhaseIndex,
  Root, FetchFun, BootstrapTimeout, PageTimeout, AdvanceMode) ->
    ProbeTo = Height0 + 1,
    case fetch_page(
           Owner, RequestRef, Peer, Endpoint, Ns,
           Height0 + 1, ProbeTo, FetchFun, BootstrapTimeout) of
        {ok, Entries, RemoteHeight}
          when is_integer(RemoteHeight), RemoteHeight > Height0 ->
            case validate_page(
                   Entries, Height0 + 1, ProbeTo, RemoteHeight) of
                {ok, _Count, _Bytes} ->
                    advance_snapshot_to_height(
                      [Source], Owner, RequestRef, Ns, Anchor, Identity,
                      Store0, Height0, Projection0, PhaseIndex, Root,
                      snapshot_target(AdvanceMode, Height0, RemoteHeight),
                      FetchFun, PageTimeout);
                {error, Reason} ->
                    {error, {bootstrap_page, Reason}}
            end;
        {ok, _Entries, _RemoteHeight} ->
            {error, no_new_page};
        {error, Reason} ->
            {error, {bootstrap_fetch, Reason}}
    end.

probe_pages(Owner, RequestRef, Hints, Ns, Height, FetchFun, PageTimeout) ->
    %% Snapshot probes need only the first available certified candidate plus
    %% the responder's captured durable height. Keeping one entry per route
    %% prevents an N-validator fanout from retaining N near-900-KiB pages.
    To = Height + 1,
    parallel_probes(
      Hints,
      fun({Peer, Endpoints}) ->
          probe_page_endpoints(
            Endpoints, Owner, RequestRef, Peer, Ns,
            Height + 1, To, FetchFun, PageTimeout)
      end,
      PageTimeout).

probe_page_endpoints(Endpoints, Owner, RequestRef, Peer, Ns,
                     From, To, FetchFun, PageTimeout) ->
    Deadline = quod_time:mono_ms() + PageTimeout,
    probe_candidate_endpoints(
      Endpoints, Deadline,
      fun(Endpoint, AttemptTimeout) ->
          fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                     From, To, FetchFun, AttemptTimeout)
      end,
      fun({ok, _Entries, _RemoteHeight} = Ok) -> {done, Ok};
         ({error, _}) -> continue
      end,
      {error, retry}).

parallel_probes(Items, Probe, TimeoutMs) ->
    Parent = self(),
    Tag = make_ref(),
    Pending = lists:foldl(
                fun(Item, Acc) ->
                    {Pid, MRef} = spawn_opt(
                                    fun() ->
                                        Result = Probe(Item),
                                        Parent ! {foreign_probe, Tag, self(),
                                                  Item, Result}
                                    end, [link, monitor]),
                    Acc#{Pid => {MRef, Item}}
                end, #{}, Items),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    collect_probes(Tag, Pending, Deadline, []).

collect_probes(_Tag, Pending, _Deadline, Acc)
  when map_size(Pending) =:= 0 ->
    lists:reverse(Acc);
collect_probes(Tag, Pending, Deadline, Acc) ->
    Wait = max(0, Deadline - quod_time:mono_ms()),
    receive
        {foreign_probe, Tag, Pid, Item, Result}
          when is_map_key(Pid, Pending) ->
            {{MRef, Item}, Pending1} = maps:take(Pid, Pending),
            _ = erlang:demonitor(MRef, [flush]),
            collect_probes(
              Tag, Pending1, Deadline, [{Item, Result} | Acc]);
        {'DOWN', MRef, process, Pid, _Reason}
          when is_map_key(Pid, Pending) ->
            case maps:get(Pid, Pending) of
                {MRef, _Item} ->
                    collect_probes(
                      Tag, maps:remove(Pid, Pending), Deadline, Acc);
                _ ->
                    collect_probes(Tag, Pending, Deadline, Acc)
            end
    after Wait ->
        stop_current_probes(Pending),
        lists:reverse(Acc)
    end.

stop_current_probes(Pending) ->
    maps:foreach(
      fun(Pid, {MRef, _Item}) ->
          _ = erlang:demonitor(MRef, [flush]),
          _ = unlink(Pid),
          exit(Pid, kill)
      end, Pending).

advance_snapshot(
  Owner, RequestRef, Identity = {Ns, Anchor}, Store0, Height0,
  Projection0, PhaseIndex, Root, Results, FetchFun, PageTimeout,
  AdvanceMode) ->
    ProbeTo = Height0 + 1,
    Candidates =
        [{RemoteHeight, Source}
         || {Source, {ok, Entries, RemoteHeight}} <- Results,
            is_integer(RemoteHeight), RemoteHeight > Height0,
            validate_page(Entries, Height0 + 1, ProbeTo, RemoteHeight)
                =/= {error, bad_page}],
    case Candidates of
        [] ->
            {ok, Store0, Height0, Projection0};
        _ ->
            Advertised = lists:max([H || {H, _Source} <- Candidates]),
            CandidateSources = [Source
                       || {_H, Source} <- lists:reverse(
                                             lists:keysort(1, Candidates))],
            advance_snapshot_to_height(
              flatten_route_candidates(CandidateSources),
              Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root,
              snapshot_target(AdvanceMode, Height0, Advertised),
              FetchFun, PageTimeout)
    end.

snapshot_target(one_page, Height, Advertised) ->
    min(Advertised, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES);
snapshot_target(to_tip, _Height, Advertised) ->
    Advertised.

advance_snapshot_to_height(
  _Sources, _Owner, _RequestRef, _Ns, _Anchor, _Identity,
  Store, Height, Projection, _PhaseIndex, _Root, Target,
  _FetchFun, _PageTimeout) when Height >= Target ->
    {ok, Store, Height, Projection};
advance_snapshot_to_height(
  Sources, Owner, RequestRef, Ns, Anchor, Identity,
  Store0, Height0, Projection0, PhaseIndex, Root, Target,
  FetchFun, PageTimeout) ->
    PageTarget = min(
                   Target,
                   Height0 + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
    case advance_snapshot_sources(
           Sources, Owner, RequestRef, Ns, Anchor, Identity,
           Store0, Height0, Projection0, PhaseIndex, Root, PageTarget,
           FetchFun, PageTimeout) of
        {ok, Store1, Height1, Projection1} when Height1 > Height0 ->
            advance_snapshot_to_height(
              Sources, Owner, RequestRef, Ns, Anchor, Identity,
              Store1, Height1, Projection1, PhaseIndex, Root, Target,
              FetchFun, PageTimeout);
        {ok, _Store1, _Height1, _Projection1} ->
            {error, invalid_history};
        {error, _} = Error ->
            Error
    end.

advance_snapshot_sources(
  [], _Owner, _RequestRef, _Ns, _Anchor, _Identity,
  _Store, _Height, _Projection, _PhaseIndex, _Root, _Target,
  _FetchFun, _PageTimeout) ->
    {error, invalid_history};
advance_snapshot_sources(
  [{Peer, Endpoint} | Rest], Owner, RequestRef,
  Ns, Anchor, Identity, Store0, Height0, Projection0,
  PhaseIndex, Root, Target, FetchFun, PageTimeout) ->
    case fetch_page(
           Owner, RequestRef, Peer, Endpoint, Ns,
           Height0 + 1, Target, FetchFun, PageTimeout) of
        {ok, Entries, RemoteHeight}
          when is_list(Entries), is_integer(RemoteHeight), RemoteHeight >= 0 ->
            case prepare_verified_page(
                   Ns, Anchor, Identity, Projection0, PhaseIndex,
                   Height0 + 1, Target, Entries, RemoteHeight) of
                {ok, Prepared} ->
                    case persist_verified_page(
                           Owner, RequestRef, Identity, Store0, Height0,
                           PhaseIndex, Root, Prepared) of
                        {ok, Store1, Height1, Projection1} ->
                            {ok, Store1, Height1, Projection1};
                        {error, _} = Error ->
                            Error
                    end;
                {error, invalid_history} ->
                    advance_snapshot_sources(
                      Rest, Owner, RequestRef, Ns, Anchor, Identity,
                      Store0, Height0, Projection0, PhaseIndex, Root,
                      Target, FetchFun, PageTimeout);
                {error, {unavailable, network_identity, _}} = Global ->
                    Global
            end;
        _ ->
            advance_snapshot_sources(
              Rest, Owner, RequestRef, Ns, Anchor, Identity,
              Store0, Height0, Projection0, PhaseIndex, Root,
              Target, FetchFun, PageTimeout)
    end.

current_view_confirmed(
  Owner, RequestRef, Hints, Ns, Anchor, Identity, Height, Projection,
  PhaseIndex,
  FetchFun, PageTimeout) ->
    Committee = quod_simplex:history_committee(Projection),
    case Committee of
        [] ->
            false;
        [_ | _] ->
            current_committee_confirmed(
              Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity,
              Height, Projection, PhaseIndex, FetchFun, PageTimeout)
    end.

current_committee_confirmed(
  Committee, Owner, RequestRef, Hints, Ns, Anchor, Identity, Height,
  Projection, PhaseIndex, FetchFun, PageTimeout) ->
    Candidates = [{Peer, Endpoints}
                  || {Peer, Endpoints} <- Hints,
                     lists:member(Peer, Committee)],
    Needed = quod_simplex:quorum(length(Committee)),
    Results = parallel_probes(
                Candidates,
                fun({Peer, Endpoints}) ->
                    probe_confirmed_endpoint(
                      Endpoints, Owner, RequestRef, Peer, Ns, Height,
                      Anchor, Identity, Projection, PhaseIndex,
                      FetchFun, PageTimeout)
                end,
                PageTimeout),
    Confirmed = [Peer || {{Peer, _Endpoints}, true} <- Results],
    length(Confirmed) >= Needed.

probe_confirmed_endpoint(
  Endpoints, Owner, RequestRef, Peer, Ns, Height,
  Anchor, Identity, Projection, PhaseIndex, FetchFun, PageTimeout) ->
    To = Height + 1,
    Deadline = quod_time:mono_ms() + PageTimeout,
    probe_candidate_endpoints(
      Endpoints, Deadline,
      fun(Endpoint, AttemptTimeout) ->
          fetch_page(Owner, RequestRef, Peer, Endpoint, Ns,
                     Height + 1, To, FetchFun, AttemptTimeout)
      end,
      fun(Result) ->
          case tip_response_at_least(
                 Result, Ns, Anchor, Identity, Height,
                 Projection, PhaseIndex) of
              true -> {done, true};
              false -> continue
          end
      end,
      false).

probe_candidate_endpoints([], _Deadline, _Attempt, _Accept, Exhausted) ->
    Exhausted;
probe_candidate_endpoints(
  [Endpoint | Rest], Deadline, Attempt, Accept, Exhausted) ->
    Remaining = max(0, Deadline - quod_time:mono_ms()),
    case Remaining of
        0 -> Exhausted;
        _ ->
            AttemptTimeout = max(1, Remaining div (length(Rest) + 1)),
            case Accept(Attempt(Endpoint, AttemptTimeout)) of
                {done, Result} -> Result;
                continue ->
                    probe_candidate_endpoints(
                      Rest, Deadline, Attempt, Accept, Exhausted)
            end
    end.

tip_response_at_least(
  {ok, [], RemoteHeight}, _Ns, _Anchor, _Identity,
  Height, _Projection, _PhaseIndex) ->
    is_integer(RemoteHeight) andalso RemoteHeight >= Height;
tip_response_at_least(
  {ok, Entries, RemoteHeight}, Ns, Anchor, Identity,
  Height, Projection, PhaseIndex) when is_list(Entries) ->
    To = Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES,
    case prepare_verified_page(
           Ns, Anchor, Identity, Projection, PhaseIndex,
           Height + 1, To, Entries, RemoteHeight) of
        {ok, _Prepared} -> RemoteHeight >= Height;
        {error, _} -> false
    end;
tip_response_at_least(
  _Result, _Ns, _Anchor, _Identity, _Height, _Projection, _PhaseIndex) ->
    false.

current_view_evidence(Identity, Height, Projection, Routes) ->
    Dtx = maps:get(dtx, Projection),
    #{identity => Identity,
      slot => Height,
      generation => maps:get(generation, Dtx),
      committee => quod_simplex:history_committee(Projection),
      committee_id => maps:get(committee_id, Projection),
      route_candidates => Routes}.

fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
           PageTimeout) ->
    StartedNative = erlang:monotonic_time(),
    Result = fetch_page_raw(
               Owner, RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
               PageTimeout),
    observe_foreign_stage(page_fetch, cache_result(Result), StartedNative),
    Result.

fetch_page_raw(Owner, RequestRef, Peer, Endpoint, Ns, From, To, undefined,
               PageTimeout) ->
    try gen_server:call(
          Owner, {pull_page, RequestRef, Peer, Endpoint, Ns, From, To},
          PageTimeout + 1000)
    catch exit:_ -> {error, retry}
    end;
fetch_page_raw(_Owner, _RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
               _PageTimeout) ->
    try FetchFun(Peer, Endpoint, Ns, From, To)
    catch exit:_ -> {error, retry}
    end.

cache_result({ok, _}) -> ok;
cache_result({ok, _, _}) -> ok;
cache_result({ok, _, _, _, _, _}) -> ok;
cache_result({error, retry}) -> uncertain;
cache_result({error, _}) -> failed;
cache_result(_) -> failed.

validate_page(Entries, From, To, RemoteHeight) ->
    case quod_catchup:page_stats(Entries) of
        {ok, Count, Bytes} when Count > 0, Count =< To - From + 1 ->
            case page_indices(Entries, From, To) andalso
                 RemoteHeight >= From + Count - 1 of
                true -> {ok, Count, Bytes};
                false -> {error, bad_page}
            end;
        _ ->
            {error, bad_page}
    end.

page_indices([], _Next, _To) -> true;
page_indices([#entry{index = Next} | Rest], Next, To) when Next =< To ->
    page_indices(Rest, Next + 1, To);
page_indices(_, _Next, _To) -> false.

verify_exact_reference(Store, Ref, ExpectedPhase, Projection) ->
    Slot = ref_slot(Ref),
    case {quod_ledger_store:read_at(Store, Slot),
          reference_projection(Slot, Slot, Projection)} of
        {{ok, #entry{} = Entry}, {ok, EvidenceProjection}} ->
            verify_exact_reference_entry(
              Ref, ExpectedPhase, Entry, EvidenceProjection);
        {not_found, _} ->
            {error, retry};
        {_, error} ->
            {error, retry}
    end.

verify_exact_reference_entry(
  Ref, ExpectedPhase, #entry{data = Data} = Entry, Projection) ->
    case quod_ledger:classify(Data) of
        {content, Transactions}
          when ExpectedPhase =:= transaction; ExpectedPhase =:= entry ->
            verify_exact_transaction_reference(
              Ref, Entry, Transactions, Projection);
        {controls, Controls} ->
            verify_exact_control_reference(
              Ref, ExpectedPhase, Entry, Controls, Projection);
        _ ->
            {error, invalid_foreign_reference}
    end.

verify_exact_control_reference(
  Ref, ExpectedPhase, Entry, Controls, Projection) ->
    Digest = ref_record_digest(Ref),
    case [{Kind, Control}
          || {Kind, Control} <- Controls,
             quod_dtx:record_digest(Control) =:= Digest] of
        [{ActualPhase, Control}]
          when ExpectedPhase =:= ActualPhase; ExpectedPhase =:= entry ->
            Identity = ref_identity(Ref),
            Committee = quod_simplex:history_committee(Projection),
            case quod_dtx:certified_entry_ref_matches(
                   Identity, Entry, Control, Ref, Committee) of
                true ->
                    DtxProjection = maps:get(dtx, Projection),
                    Generation = maps:get(generation, DtxProjection),
                    Routes = quod_simplex:history_validator_routes(Projection),
                    {ok,
                     #{identity => Identity,
                       slot => ref_slot(Ref),
                       block_hash => ref_block_hash(Ref),
                       record_digest => Digest,
                       phase => ActualPhase,
                       generation => Generation,
                       control => Control,
                       entry => Entry,
                       committee => Committee,
                       committee_id => maps:get(committee_id, Projection),
                       routes => Routes}};
                false ->
                    {error, invalid_foreign_reference}
            end;
        [{_OtherPhase, _Control}] ->
            {error, phase_mismatch};
        _ ->
            {error, invalid_foreign_reference}
    end.

verify_exact_transaction_reference(Ref, Entry, Transactions, Projection) ->
    Identity = ref_identity(Ref),
    Digest = ref_record_digest(Ref),
    case [T || #transaction{tx_id = TxId} = T <- Transactions,
               transaction_reference_digest(ref_slot(Ref), TxId) =:= Digest] of
        [Transaction] ->
            Committee = quod_simplex:history_committee(Projection),
            case quod_dtx:certified_entry_ref_matches(
                   Identity, Entry, Transaction, Ref, Committee) of
                true ->
                    DtxProjection = maps:get(dtx, Projection),
                    #{generation := Generation} = DtxProjection,
                    {ok, #{identity => Identity,
                           slot => ref_slot(Ref),
                           block_hash => ref_block_hash(Ref),
                           record_digest => Digest,
                           phase => transaction,
                           generation => Generation,
                           transaction => Transaction,
                           entry => Entry,
                           committee => quod_simplex:history_committee(
                                          Projection),
                           committee_id => maps:get(committee_id, Projection),
                           routes => quod_simplex:history_validator_routes(
                                       Projection)}};
                false -> {error, invalid_foreign_reference}
            end;
        _ ->
            {error, invalid_foreign_reference}
    end.


%% The genesis transaction id is a tagged, namespace-bearing value rather
%% than a 32-byte ordinary transaction id.  Its exact certified reference
%% uses the digest of that value; slot 1 is independently fixed by the pinned
%% genesis block hash before this selector is reached.
transaction_reference_digest(1, TxId) when is_binary(TxId) ->
    crypto:hash(sha256, TxId);
transaction_reference_digest(_Slot, TxId) ->
    TxId.

verify_reference_source(Peer, {ok, #{committee := Committee}} = Result,
                        true) ->
    case verified_route_peer(Peer, Committee) of
        true -> Result;
        false ->
            %% This is a route failure, not evidence that the certified
            %% reference is false; callers may try another candidate.
            {error, retry}
    end;
verify_reference_source(_Peer, Result, _RequirePeer) ->
    Result.

verified_route_peer({local, _Identity}, _Committee) -> true;
verified_route_peer(Peer, Committee) -> lists:member(Peer, Committee).

%%%===================================================================
%%% Durable cache
%%%===================================================================

cache_namespace({Ns, Anchor}) ->
    crypto:hash(
      sha256,
      term_to_binary({quod_foreign_log, ?CACHE_VERSION, Ns, Anchor},
                     [deterministic])).

cache_dir(Root, CacheNs) ->
    quod_ledger_store:ns_dir(Root, CacheNs).

manifest_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?MANIFEST).

checkpoint_path(Root, CacheNs) ->
    filename:join(cache_dir(Root, CacheNs), ?CHECKPOINT).

cache_log_bytes(Root, CacheNs) ->
    case file:read_file_info(filename:join(cache_dir(Root, CacheNs), ?LOG)) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

cache_persisted_bytes(Root, CacheNs) ->
    Dir = cache_dir(Root, CacheNs),
    file_bytes(filename:join(Dir, ?LOG)) +
        file_bytes(filename:join(Dir, ?MANIFEST)) +
        file_bytes(filename:join(Dir, ?CHECKPOINT)).

file_bytes(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, _} -> 0
    end.

ensure_manifest(Owner, RequestRef, Root, {Ns, Anchor}, CacheNs) ->
    Path = manifest_path(Root, CacheNs),
    Expected = {quod_foreign_log_cache, ?CACHE_VERSION,
                Ns, Anchor, CacheNs},
    case read_small_term(Path) of
        {ok, Expected} -> ok;
        {error, enoent} ->
            case gen_server:call(
                   Owner,
                   {reserve_page, RequestRef, ?MANIFEST_RESERVE_BYTES}) of
                ok ->
                    atomic_write(
                      Path, term_to_binary(Expected, [deterministic]));
                {error, _} ->
                    {error, cache_unavailable}
            end;
        _ ->
            {error, corrupt_manifest}
    end.

write_checkpoint(Root, {Ns, Anchor}, CacheNs, Height, Projection) ->
    Bytes = cache_log_bytes(Root, CacheNs),
    Term = {quod_foreign_log_checkpoint, ?CACHE_VERSION,
            Ns, Anchor, Height, Bytes, checkpoint_projection(Projection)},
    Blob = term_to_binary(Term, [deterministic]),
    case byte_size(Blob) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES of
        true -> atomic_write(checkpoint_path(Root, CacheNs), Blob);
        false -> {error, checkpoint_too_large}
    end.

load_checkpoint(Root, Identity = {Ns, Anchor}, CacheNs, Height) ->
    Path = checkpoint_path(Root, CacheNs),
    case read_small_term(Path) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              Ns, Anchor, Height, StoredBytes, Projection}}
          when is_integer(StoredBytes), StoredBytes >= 0 ->
            case StoredBytes =:= cache_log_bytes(Root, CacheNs) andalso
                 valid_projection(Projection, Identity) of
                true -> {ok, Projection};
                false -> {error, corrupt_checkpoint}
            end;
        {error, enoent} -> new;
        _ -> {error, corrupt_checkpoint}
    end.

read_small_term(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} when element(2, Info) =< ?QUOD_MAX_FOREIGN_PAGE_BYTES ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    case quod_safe_term:decode(
                           Bin, ?QUOD_MAX_FOREIGN_PAGE_BYTES) of
                        {ok, Term} ->
                            case term_to_binary(Term, [deterministic]) =:= Bin of
                                true -> {ok, Term};
                                false -> {error, noncanonical}
                            end;
                        {error, _} -> {error, bad_term}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> {error, too_large};
        {error, Reason} -> {error, Reason}
    end.

atomic_write(Path, Blob) ->
    ok = filelib:ensure_dir(Path),
    Token = integer_to_list(erlang:unique_integer([positive, monotonic])),
    Tmp = Path ++ ".new." ++ Token,
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Blob),
                    ok = file:datasync(Fd),
                    ok
                catch _:_ -> {error, write_failed}
                after _ = file:close(Fd)
                end,
            case Result of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> sync_dir(filename:dirname(Path));
                        {error, _} = Error -> _ = file:delete(Tmp), Error
                    end;
                {error, _} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, _} = Error -> Error
    end.

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, Fd} ->
            Result = file:datasync(Fd),
            _ = file:close(Fd),
            case Result of
                ok -> ok;
                {error, eisdir} -> ok;
                Error -> Error
            end;
        {error, eisdir} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% Foreign caches are durable D state, not a boot-time resident catalogue.
%% Opening an owner must not materialize every remote ontology the node has
%% ever touched: an exact identity is loaded only when proof verification or a
%% follow needs it. A bad cache is disposable derived state and is rebuilt from
%% the authenticated source on that first use. Once that use verifies the
%% current bounded projection, the running owner retains it for later calls.
load_or_new_history(Root, Identity) ->
    CacheNs = cache_namespace(Identity),
    Dir = cache_dir(Root, CacheNs),
    case load_history_dir(Root, Dir) of
        {ok, #history{identity = Identity} = H} ->
            H#history{last_used = quod_time:mono_ms()};
        _ ->
            _ = remove_cache_path(Dir),
            #history{identity = Identity, cache_ns = CacheNs,
                     last_used = quod_time:mono_ms()}
    end.

load_history_dir(Root, Dir) ->
    ok = cleanup_cache_temps(Dir),
    case read_small_term(filename:join(Dir, ?MANIFEST)) of
        {ok, {quod_foreign_log_cache, ?CACHE_VERSION,
              Ns, <<_:256>> = Anchor, <<_:256>> = CacheNs}}
          when is_binary(Ns), byte_size(Ns) > 0,
               byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES ->
            Identity = {Ns, Anchor},
            Bytes = cache_persisted_bytes(Root, CacheNs),
            case CacheNs =:= cache_namespace(Identity) andalso
                 cache_dir(Root, CacheNs) =:= Dir of
                true ->
                    case load_checkpoint(Root, Identity, CacheNs,
                                         checkpoint_height(Root, CacheNs)) of
                        {ok, Projection} ->
                            Height = checkpoint_height(Root, CacheNs),
                            {ok, #history{identity = Identity,
                                          cache_ns = CacheNs,
                                          height = Height, bytes = Bytes,
                                          projection = Projection,
                                          last_used = 0}};
                        _ -> error
                    end;
                false -> error
            end;
        _ -> error
    end.

cleanup_cache_temps(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            _ = [file:delete(filename:join(Dir, Name))
                 || Name <- Names, is_cache_temp(Name)],
            ok;
        {error, _} -> ok
    end.

is_cache_temp(Name) when is_list(Name) ->
    lists:prefix(?MANIFEST ++ ".new.", Name) orelse
        lists:prefix(?CHECKPOINT ++ ".new.", Name).

remove_cache_path(Path) ->
    case file:del_dir_r(Path) of
        ok -> ok;
        {error, enotdir} ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = Error -> Error
            end;
        {error, enoent} -> ok;
        {error, _} = Error -> Error
    end.

checkpoint_height(Root, CacheNs) ->
    case read_small_term(checkpoint_path(Root, CacheNs)) of
        {ok, {quod_foreign_log_checkpoint, ?CACHE_VERSION,
              _Ns, _Anchor, Height, _Bytes, _Projection}}
          when is_integer(Height), Height >= 0 -> Height;
        _ -> -1
    end.

%%%===================================================================
%%% Shared bounded-shape checks and ref accessors
%%%===================================================================

valid_projection(
  #{committee := Committee, validator_routes := Routes,
    committee_id := CommitteeId,
    admissions := Admissions, sequences := Sequences,
    dtx := Dtx, dtx_lanes := DtxLanes} = Projection,
  ExpectedIdentity)
  when is_map(Routes), is_map(Admissions), is_map(Sequences),
       is_map(DtxLanes),
       map_size(Routes) =< ?MAX_VALIDATORS,
       map_size(Admissions) =< ?MAX_VALIDATORS,
       map_size(Sequences) =< ?MAX_VALIDATORS,
       map_size(DtxLanes) =< ?MAX_VALIDATORS ->
    bounded_committee(Committee, 0) andalso
        valid_validator_routes(Routes, Committee) andalso
        (CommitteeId =:= undefined orelse
         (is_binary(CommitteeId) andalso byte_size(CommitteeId) =:= 32)) andalso
        valid_dtx_target(Dtx, ExpectedIdentity) andalso
        valid_committee_views(Projection, ExpectedIdentity);
valid_projection(_, _) -> false.

%% Committee eras are retained only by the running certified-history owner.
%% The durable checkpoint stays at the fixed current-projection shape; after a
%% restart the existing one-time replay rebuilds both the DTX phase session and
%% these eras together. This avoids both per-reference genesis replay and an
%% ever-growing checkpoint envelope.
checkpoint_projection(Projection) ->
    maps:remove(committee_views, Projection).

valid_committee_views(#{committee_views := Views} = Projection,
                      _ExpectedIdentity)
  when is_list(Views), map_size(Projection) =:= 11 ->
    valid_committee_view_rows(Views);
valid_committee_views(Projection, _ExpectedIdentity) ->
    %% Compact persisted checkpoints deliberately omit the resident-only era
    %% index and retain the exact ten-field shape.
    map_size(Projection) =:= 10.

valid_committee_view_rows([]) -> true;
valid_committee_view_rows(
  [{Start, Committee, <<_:256>>, Routes} | Rest])
  when is_integer(Start), Start > 0, is_map(Routes) ->
    bounded_committee(Committee, 0) andalso
        valid_validator_routes(Routes, Committee) andalso
        valid_committee_view_rows(Rest, Start);
valid_committee_view_rows(_) -> false.

valid_committee_view_rows([], _PreviousStart) -> true;
valid_committee_view_rows(
  [{Start, Committee, <<_:256>>, Routes} | Rest], PreviousStart)
  when is_integer(Start), Start > 0, Start < PreviousStart,
       is_map(Routes) ->
    bounded_committee(Committee, 0) andalso
        valid_validator_routes(Routes, Committee) andalso
        valid_committee_view_rows(Rest, Start);
valid_committee_view_rows(_, _) -> false.

reference_projection(Slot, Height, Projection)
  when is_integer(Slot), Slot > 0, Slot =< Height ->
    case quod_simplex:history_committee_view(Slot, Projection) of
        {ok, Committee, CommitteeId, Routes} ->
            {ok, Projection#{committee := Committee,
                             committee_id := CommitteeId,
                             validator_routes := Routes}};
        error -> error
    end;
reference_projection(_Slot, _Height, _Projection) ->
    error.

resident_target_projection(TargetSlot, Height, Projection) ->
    case TargetSlot of
        Slot when is_integer(Slot), Slot > 0, Slot =< Height ->
            %% Keep the one certified resident projection here.
            %% verify_exact_reference performs the sole exact-slot era
            %% substitution after reading the entry.
            Projection;
        _CurrentOrFuture ->
            undefined
    end.

valid_validator_routes(Routes, Committee) ->
    maps:fold(
      fun(<<_:256>> = Key, Endpoint, Valid) ->
              Valid andalso lists:member(Key, Committee) andalso
                  quod_quic:valid_endpoint(Endpoint);
         (_Key, _Endpoint, _Valid) ->
              false
      end, true, Routes).

bounded_committee([], _Count) -> true;
bounded_committee([<<_:256>> | Rest], Count) when Count < ?MAX_VALIDATORS ->
    bounded_committee(Rest, Count + 1);
bounded_committee(_, _Count) -> false.

valid_dtx_target(
  #{target := Identity, generation := Generation}, Identity)
  when is_integer(Generation), Generation >= 0,
       Generation =< ?MAX_UINT64 -> true;
valid_dtx_target(_, _) -> false.

ref_identity(
  {quod_dtx_ref, 2, Ns, Anchor, _Slot, _BlockHash, _Digest, _Proof}) ->
    {Ns, Anchor};
ref_identity(_) -> invalid.

ref_slot({quod_dtx_ref, 2, _Ns, _Anchor, Slot, _BlockHash, _Digest, _Proof}) ->
    Slot.

ref_block_hash(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, BlockHash, _Digest, _Proof}) ->
    BlockHash.

ref_record_digest(
  {quod_dtx_ref, 2, _Ns, _Anchor, _Slot, _BlockHash, Digest, _Proof}) ->
    Digest.
