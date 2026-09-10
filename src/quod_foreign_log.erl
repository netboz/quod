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
The node serving history bytes grants no authority: after certified committee
sources are exhausted, an authenticated live host may supply bytes to the same
verifier so a retained prefix can cross a complete host or committee move.
Only the verified chain and its slot-specific committee certify an exact
reference. Execution routes, current-view quorum replies, and plain reads stay
restricted to validators in the certified current projection.

The same owner also derives a certificate-verified current committee view for
an anchored identity. `quod_dtx_current_view` uses that frozen view to select
distinct current validator keys and to bind outcome/application probes to one
committee id and minimum slot. Routes remain transport hints and never become
committee evidence.

`verify/5`, `verify_reference/3`, and the current-view APIs are synchronous only from the caller's
perspective. The gen_server never waits for network, disk replay, certificate
verification, or crypto; DTX validation callers invoke them from their existing
asynchronous verdict/recovery worker boundary.
Incoming pages are decoded by the requesting verifier or its existing probe
child, not by this shared gen_server. The owner retains the page deadline,
caller monitor and exact link credit until it accepts that worker's local
decode completion. Raw delivery is neither page completion nor evidence;
only the ordinary forward verifier can establish history authority.

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
caller deadline. Exact directory/feed progress and a genuinely advanced
verified prefix release it; merely retaining an unchanged prefix does not.
A later row with a request-scoped contact may run past it.
No endpoint becomes authority or retained configuration, and no retry timer is
used to discover that progress.

A caller registration is not the shared job. Its absolute deadline includes
owner-mailbox time and is checked again when publishing and returning a result.
Expiry detaches only that caller: active and runnable/custody-blocked admitted
work survives, while a callerless unavailable-route park retires. Borrowed
local views retain their exact source-PID lifetime. A routed attempt remembers
one accepted external progress edge until its failure/park transition; its own
cache installation cannot create a new attempt. Trace metadata never changes
sharing, route eligibility, deadlines or authority.

The existing verifier worker holds the gproc name `{foreign_cache_writer,
Identity}` before any mutable cache recovery/open/cleanup. The name is released
only by actual worker death, not result delivery or a kill request. The owner-
death watcher stops an orphan; the registered name prevents its replacement
from writing during that asynchronous stop. Contention parks in this same
queue under a correlated name monitor, separately from route availability.
Admission only inspects metadata; the custodian revalidates it before mutation
and preserves the exact handed-off suspended phase session during cleanup.
This is one-BEAM custody: the release requires permanent gproc, and two VMs
must not share a live data directory, as for the main ledger.

Inside that custody, one worker-owned cursor carries the store, certified
projection and phase index through exact/current/follow work and every route
attempt. Request failure does not discard a healthy prefix or its suspended
session. A partially failed local mutation makes the cursor unusable: no next
source sees its stale prefix, and the existing cold recovery path handles the
file on a later admitted job. Empty caches are not certified resident history.

There is no numeric limit on foreign identities, follows, encoded cache, or
materialized projections. An inactive identity retains its bounded current
projection only after this running owner has verified it. Ledger handles,
phase indexes, workers, and catch-up link leases remain active only for proof or
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
         current/3, current/4,
         observe_candidate/2, route_hints/2, valid_route_candidates/1,
         follow/1, refresh/1, ack/2, projection_clauses/3, unfollow/1,
         required_references/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([cache_namespace/1, valid_projection/2, test_coalesce_notice/2,
         test_install_worker_meta/3, test_install_verified_progress/3,
         test_fail_persist_after/1,
         test_install_feed_registration/5,
         test_install_feed_opening/5,
         test_install_feed_projection/3,
         test_corrupt_resident_height/3,
         test_lifecycle_state/0,
         measure_foreign_stage/2,
         test_parallel_probes/4, test_confirmation_candidates/2]).
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
-define(TRACE_STAGE_ACTIVE, {?MODULE, trace_stage_active}).

%% One live cache cursor belongs to the existing custodian, never to a route.
%% Invalid cursors retain cleanup handles only: no continuation may read,
%% append, suspend or publish them as a verified prefix.
-record(verified_cursor, {
          store,
          height,
          projection,
          phase_index,
          target_projection = undefined,
          state = verified
         }).

%% A caller owns a deadline and observation, never the lifetime of shared work.
-record(caller, {
          deadline :: integer() | infinity,
          timer = none :: none | reference(),
          trace_ctx = undefined :: term(),
          enqueued_native :: integer(),
          residence = none :: term(),
          stage = none :: term(),
          ordinal = 0 :: non_neg_integer(),
          %% Diagnostic deduplication/count only; never a scheduling/sharing key.
          queue_observation = {none, 0} :: {term(), non_neg_integer()}
         }).

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
          callers = #{} :: #{gen_server:from() => #caller{}},
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          work :: term(),
          fetch_fun :: undefined | function(),
          source = none :: none | {pid(), reference()},
          parked = false :: false | true | {custody, reference()},
          enqueued_native :: integer(),
          job_id = undefined :: undefined | binary(),
          attempt = 1 :: pos_integer()
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
          waiting = {[], []} :: term(),
          last_used = 0 :: integer(),
          active = none :: none | reference(),
          consumers = #{} :: #{reference() => #consumer{}},
          follow_token = none :: none | reference(),
          follow_inflight = false :: boolean(),
          follow_dirty = false :: boolean(),
          follow_start_height = 0 :: non_neg_integer(),
          progress_signals_open = false :: boolean(),
          current_watch = none :: none | remote,
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
          callers = #{} :: #{gen_server:from() => #caller{}},
          peer :: term(),
          identity :: {binary(), <<_:256>>},
          work :: term(),
          worker :: pid(),
          mref :: reference(),
          source = none :: none | {pid(), reference()} | down,
          timer = none :: none | reference(),
          progress_edge = false :: boolean(),
          custody = acquiring :: acquiring | held,
          retiring = false :: boolean(),
          trace_ctx = undefined :: term(),
          fetch_fun = undefined :: undefined | function(),
          job_id :: binary(),
          attempt = 1 :: pos_integer()
         }).

-record(pull, {
          from :: none | gen_server:from(),
          caller :: pid(),
          request_ref :: reference(),
          binding :: reference(),
          range :: {pos_integer(), pos_integer()},
          deadline :: integer(),
          turn = queued :: queued | {sent, pid(), reference(), binary()} |
                           {decoding, pid(), reference(), binary(), binary()},
          trace_ctx = undefined :: term(),
          mref :: reference(),
          timer :: reference()
         }).

%% One exact lease in the existing pinned pool. Logical pages remain only in
%% pulls; credit selects their oldest runnable row, not a second frame queue.
-record(page_binding, {
          ref :: reference(),
          key :: {binary(), term(), binary()},
          lease = none :: none | reference(),
          link = none :: none | pid(),
          mref = none :: none | reference(),
          credit = none :: none | binary(),
          retiring = false :: boolean(),
          waiting = {[], []} :: term(),
          active = none :: none | binary(),
          identities = #{} :: map()
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
          pulls = #{} :: #{<<_:128>> => #pull{}},
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
          page_bindings = #{} :: #{term() => #page_binding{}},
          page_contacts = #{} :: #{term() => reference()},
          page_openings = #{} :: #{reference() => reference()},
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
    Deadline = caller_deadline(TimeoutMs),
    verification_call(
      {verify, PeerKey, Endpoint, Ref, ExpectedPhase, TimeoutMs}, Deadline);
verify(_PeerKey, _Endpoint, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

-doc """
Verify one exact foreign DTX reference through the shared source selector.

Certified directory routes, certified history routes, and bounded authenticated
bootstrap candidates are transport hints only.  The existing history verifier
still proves the exact anchor, phase, certificate chain, and committee at the
referenced slot. The node which supplied the bytes contributes no authority.
""".
-spec verify_reference(quod_dtx:certified_ref(),
                       entry | transaction | 'begin' | prepare | decision |
                       finalize | complete,
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
                       entry | transaction | 'begin' | prepare | decision |
                       finalize | complete,
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
                       entry | transaction | 'begin' | prepare | decision |
                       finalize | complete,
                       none | {<<_:256>>, term()}, none | quod_ledger:entry_artifact(),
                       pos_integer()) -> {ok, map()} | {error, term()}.
verify_reference(Ref, ExpectedPhase, Contact, EntryHint0, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0,
       TimeoutMs =< ?MAX_TIMER_MS - 1000 ->
    Deadline = caller_deadline(TimeoutMs),
    case valid_request_contact(Contact) of
        true ->
            EntryHint = normalize_entry_hint(EntryHint0),
            verification_call(
              {verify_reference, Ref, ExpectedPhase, Contact,
               EntryHint, TimeoutMs}, Deadline);
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
Verify one exact reference against a co-hosted owner's immutable history view.

When the caller supplies an immutable snapshot of its already-open committed
store and its current verified projection, a reference certified by that same
committee is read and checked directly. A reference from an older committee
era uses the same lazy cache and forward verifier as `verify/5`; its
pages come from the captured session instead of the network and no route-peer membership
claim is needed. Returned committee and committee id are fixed by the referenced
slot. Validator routes are reachability hints from that committee era, never
authority.
""".
-spec verify_local(quod_simplex:history_view(),
                   quod_dtx:certified_ref(),
                   entry | transaction | 'begin' | prepare | decision |
                   finalize | complete,
                   pos_integer() | infinity) ->
          {ok, map()} | {error, term()}.
verify_local(
  #{owner := Owner, identity := Identity, slot := Height, applied := Applied,
    snapshot := Snapshot, projection := Projection} = View,
  Ref, ExpectedPhase, TimeoutMs)
  when is_pid(Owner), is_integer(Height), Height >= 0,
       is_integer(Applied), Applied >= 0, Applied =< Height,
       ((is_integer(TimeoutMs) andalso TimeoutMs > 0 andalso
         TimeoutMs =< ?MAX_TIMER_MS - 1000) orelse TimeoutMs =:= infinity) ->
    Deadline = caller_deadline(TimeoutMs),
    Result = case validate_local_request(View, Ref, ExpectedPhase, TimeoutMs) of
        {ok, Identity} ->
            with_local_view_owner(
              View,
              fun() ->
                  case verify_resident_local_reference(
                         Snapshot, Ref, ExpectedPhase, Projection) of
                      {error, historical_committee} ->
                          verify_historical_local_reference(
                            View, Ref, ExpectedPhase, TimeoutMs, Deadline);
                      Result -> Result
                  end
              end);
        {error, _} = Error -> Error
    end,
    caller_result(Deadline, Result);
verify_local(_View, _Ref, _ExpectedPhase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

verify_historical_local_reference(View, Ref, ExpectedPhase, TimeoutMs, Deadline) ->
    verification_call({verify_local, View, Ref, ExpectedPhase, TimeoutMs}, Deadline).

caller_deadline(infinity) -> infinity;
caller_deadline(TimeoutMs) -> quod_time:mono_ms() + TimeoutMs.

caller_live(infinity) -> true;
caller_live(Deadline) -> Deadline > quod_time:mono_ms().

caller_result(Deadline, Result) ->
    case caller_live(Deadline) of true -> Result; false -> {error, retry} end.

verification_call(Request, Deadline) ->
    verification_call(quod_reg:where(?KEY), Request, Deadline).

verification_call(Pid, Request, Deadline) ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.foreign.owner_request">>, internal, #{},
      fun(Span) ->
          {Result, Cause0} = case {caller_live(Deadline), Pid} of
              {false, _} -> {{error, retry}, caller_expired};
              {true, undefined} -> {{error, retry}, owner_unavailable};
              {true, _} ->
                  Timeout = case Deadline of
                      infinity -> infinity;
                      _ -> max(0, Deadline - quod_time:mono_ms()) + 1000
                  end,
                  try gen_server:call(Pid,
                        {verification, Deadline, quod_trace:context(),
                         erlang:monotonic_time(), Request}, Timeout)
                  of R -> {R, owner_reply}
                  catch exit:_ -> {{error, retry}, owner_call_failed}
                  end
          end,
          Reply = caller_result(Deadline, Result),
          Cause = case caller_live(Deadline) of true -> Cause0; false -> caller_expired end,
          _ = quod_trace:set_attributes(Span, #{'quod.foreign.cause' => atom_to_binary(Cause)}),
          _ = quod_trace:result(Span, Reply),
          Reply
      end).

%% Later appends preserve a borrowed view. Only replacing or losing its exact
%% owner makes it unavailable; never recapture a newer session for an old view.
with_local_view_owner(View, Fun) ->
    case quod_simplex:history_view_live(View) of
        true ->
            Result = Fun(),
            case quod_simplex:history_view_live(View) of
                true -> Result;
                false -> {error, retry}
            end;
        false -> {error, retry}
    end.

local_view_fetch(#{identity := {Ns, _Anchor}, snapshot := Snapshot} = View,
                 Ns, From, To) ->
    with_local_view_owner(
      View, fun() -> quod_catchup:serve_blocks(Ns, Snapshot, From, To) end);
local_view_fetch(_View, _Ns, _From, _To) ->
    {error, wrong_namespace}.

%% A local consensus owner has already verified the complete durable prefix.
%% Its live projection retains the exact start of the current committee era;
%% only references in that era may reuse it. Older eras retain the full
%% historical verifier above.
verify_resident_local_reference(Snapshot, Ref, ExpectedPhase, Projection) ->
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
  Snapshot, Slot, Ns, _Anchor, Ref, ExpectedPhase, Projection) ->
    case quod_ledger_store:open_ro_snapshot(Snapshot) of
        {ok, Store} ->
            try
                case quod_ledger_store:namespace(Store) of
                    Ns ->
                        verify_resident_local_store(
                          Store, Slot, Ref, ExpectedPhase, Projection);
                    _OtherNamespace ->
                        {error, bad_foreign_reference}
                end
            after
                quod_ledger_store:close(Store)
            end;
        {error, _Unavailable} ->
            {error, retry}
    end.

verify_resident_local_store(Store, Slot, Ref, ExpectedPhase, Projection) ->
    case {quod_ledger_store:read_at(Store, Slot),
          reference_projection(Slot, Slot, Projection)} of
        {{ok, Entry}, {ok, EvidenceProjection}} ->
            #entry{index = Slot} = quod_ledger:entry_view(Entry),
            verify_exact_reference_entry(
              Ref, ExpectedPhase, Entry, EvidenceProjection);
        {not_found, _} ->
            {error, retry};
        {_, error} ->
            {error, historical_committee}
    end.

-doc """
Return one certificate-verified current committee view for an anchored identity.

It starts from the pinned genesis anchor, advances the shared lazy history
cache through certified entries, then requires a full quorum of the resulting
committee to corroborate the captured durable height.  Supplied routes remain
identity-pinned fetch hints only.

Before genesis is certified, candidates retain discovery order. Afterwards the
returned route view contains only certified committee keys, with live
first-party reachability ahead of the certified historical endpoint for the
same key. Untrusted hosts may still supply history bytes to cross a committee
move, but they cannot corroborate the current view. The returned view uses
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
    Deadline = caller_deadline(TimeoutMs),
    case {normalize_route_candidates(Routes0), valid_identity(Identity),
          valid_request_contact(Contact)} of
        {{ok, [_ | _] = Routes}, true, true} ->
            StartedNative = erlang:monotonic_time(),
            {Ns, _Anchor} = Identity,
            Result = quod_trace:with_span(
                       quod_trace:context(), <<"quod.foreign.current">>, internal,
                       #{'quod.namespace' => Ns},
                       fun(SpanCtx) ->
                           R = verification_call(
                                 {current, Routes, Identity, Contact, TimeoutMs}, Deadline),
                           _ = quod_trace:result(SpanCtx, R),
                           R
                       end),
            observe_foreign_stage(current_total, foreign_result(Result), StartedNative),
            caller_result(Deadline, Result);
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

-doc "Read exact clauses from the certified projection owned by this follow.".
-spec projection_clauses(reference(), [{term(), non_neg_integer()}],
                         pos_integer()) -> {ok, map()} | {error, term()}.
projection_clauses(FollowRef, Functors, TimeoutMs)
  when is_reference(FollowRef), is_list(Functors),
       is_integer(TimeoutMs), TimeoutMs > 0 ->
    case quod_reg:where(?KEY) of
        Pid when is_pid(Pid) ->
            Handle = try gen_server:call(
                           Pid, {projection_handle, FollowRef, self()}, 1000)
                     catch exit:_ -> {error, unavailable}
                     end,
            case Handle of
                {ok, ProjectionPid, Generation} ->
                    quod_foreign_projection:clauses(
                      ProjectionPid, Generation, Functors, TimeoutMs);
                {error, _} = Error -> Error
            end;
        undefined -> {error, unavailable}
    end;
projection_clauses(_, _, _) -> {error, bad_request}.

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
    #{pending => 0, queued => 0, pulls => 0, histories => 0, page_bindings => 0,
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
              page_bindings => map_size(S#s.page_bindings),
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
handle_call({projection_handle, FollowRef, ConsumerPid}, _From, S) ->
    {reply, follow_materializer(FollowRef, ConsumerPid, S), S};
handle_call({verification, Deadline, TraceCtx, EnqueuedNative, Request}, From, S0) ->
    observe_foreign_stage(owner_mailbox, ok, EnqueuedNative),
    Caller = #caller{deadline = Deadline,
                     trace_ctx = stripped_trace_context(TraceCtx),
                     enqueued_native = EnqueuedNative},
    ValidDeadline = valid_caller_deadline(Request, Deadline),
    case ValidDeadline andalso caller_live(Deadline) of
        false ->
            Cause = case ValidDeadline of true -> caller_expired; false -> malformed_request end,
            observe_unadmitted_caller(Caller, Cause),
            {reply, {error, retry}, S0};
        true ->
            handle_verification(Request, Caller, From, S0)
    end;
handle_call({claim_cache_custody, RequestRef}, {Worker, _}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker, identity = Identity, custody = acquiring, retiring = false,
                 callers = Callers} = Request ->
            case request_source_live(Request) andalso
                 quod_reg:where(cache_writer_key(Identity)) =:= Worker of
                true ->
                    Resident = resident_cache(Identity, S0),
                    H0 = maps:get(Identity, S0#s.histories),
                    H1 = H0#history{resident_verified = false, phase_session = none},
                    S1 = put_history(Identity, H1, S0),
                    Running = stage_callers(Callers, running),
                    annotate_caller_stages(Running, work_lifetime_attributes(Request#request.work)),
                    S2 = S1#s{pending = (S1#s.pending)#{RequestRef =>
                                      Request#request{custody = held,
                                          callers = Running}}},
                    {reply, {ok, Resident, worker_trace(Identity, Callers,
                              Request#request.job_id, Request#request.attempt)}, S2};
                false -> {reply, {error, retry}, S0}
            end;
        _ -> {reply, {error, retry}, S0}
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
  {pull_page, RequestRef, Peer, Endpoint, Ns, FromIndex, ToIndex, Deadline, TraceCtx}, From,
  S = #s{fetch_fun = undefined}) ->
    case maps:get(RequestRef, S#s.pending, undefined) of
        #request{identity = {Ns, _Anchor} = Identity, work = Work} ->
            admit_pull(RequestRef, Identity, Work, Peer, Endpoint,
                       FromIndex, ToIndex, Deadline, TraceCtx, From, S);
        _ ->
            {reply, {error, retry}, S}
    end;
handle_call({complete_page_decode, Key, Verdict}, {Caller, _}, S0) ->
    {Reply, S1} = complete_page_decode(Key, Verdict, Caller, S0),
    {reply, Reply, S1};
handle_call({borrow_local_view, RequestRef, View}, {Worker, _Tag}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker, identity = Identity, source = none,
                 work = {follow, Identity, _Sources, Deadline}} = Request ->
            case View of
                #{identity := Identity, owner := SourceOwner} ->
                    case Deadline > quod_time:mono_ms() andalso
                         quod_simplex:history_view_live(View) of
                        true ->
                            Source = monitor_source_owner(
                                       Identity, RequestRef, SourceOwner),
                            Pending = (S0#s.pending)#{
                                        RequestRef => Request#request{source = Source}},
                            {reply, ok, S0#s{pending = Pending}};
                        false -> {reply, {error, retry}, S0}
                    end;
                _ -> {reply, {error, retry}, S0}
            end;
        _ -> {reply, {error, retry}, S0}
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
test_lifecycle_state() ->
    gen_server:call(quod_reg:where(?KEY), test_lifecycle_state).

test_install_worker_meta(RequestRef, Meta, S) ->
    install_worker_meta(RequestRef, Meta, S).

test_install_verified_progress(RequestRef, Meta, S) ->
    install_verified_progress(RequestRef, Meta, S).

test_fail_persist_after(Stage)
  when Stage =:= ledger_append; Stage =:= phase_commit;
       Stage =:= checkpoint_write; Stage =:= cache_accounting;
       Stage =:= reserve_page ->
    put({?MODULE, persistence_failure}, Stage),
    ok.

test_caller_rows(Callers) ->
    [#{deadline => C#caller.deadline} || C <- maps:values(Callers)].

test_wait_reason(true) -> route;
test_wait_reason(false) -> runnable;
test_wait_reason({custody, _}) -> custody.

handle_private_call(test_lifecycle_state, _From, S) ->
    Rows = maps:map(
      fun(_Identity, H) ->
          Active = case maps:get(H#history.active, S#s.pending, undefined) of
              undefined -> none;
              R -> #{ref => H#history.active, worker => R#request.worker,
                     job_id => R#request.job_id,
                     callers => test_caller_rows(R#request.callers),
                     edge => R#request.progress_edge, custody => R#request.custody}
          end,
          #{active => Active, height => H#history.height,
            waiting => [#{ref => Q#queued_request.ref,
                          job_id => Q#queued_request.job_id,
                          wait_reason => test_wait_reason(Q#queued_request.parked),
                          callers => test_caller_rows(Q#queued_request.callers),
                          edge => false} || Q <- queue:to_list(H#history.waiting)]}
      end, S#s.histories),
    {reply, Rows, S};
handle_private_call({test_hold_next_page_decode, TestPid, Token, Stage}, _From, S)
  when is_pid(TestPid), is_reference(Token),
       (Stage =:= before_decode orelse Stage =:= before_completion orelse
        Stage =:= after_accept) ->
    put({?MODULE, page_decode_gate}, {TestPid, Token, Stage}),
    {reply, ok, S};
handle_private_call({test_hold_next_local_worker, TestPid, Token}, _From, S)
  when is_pid(TestPid), is_reference(Token) ->
    put({?MODULE, local_worker_gate}, {TestPid, Token}),
    {reply, ok, S};
handle_private_call({test_hold_next_follow_worker, TestPid, Token}, _From, S)
  when is_pid(TestPid), is_reference(Token) ->
    put({?MODULE, follow_worker_gate}, {TestPid, Token}),
    {reply, ok, S};
handle_private_call({test_hold_next_confirmation, TestPid, Token}, _From, S)
  when is_pid(TestPid), is_reference(Token) ->
    put({?MODULE, confirmation_gate}, {TestPid, Token}),
    {reply, ok, S};
handle_private_call({test_follow_attempt_state, Identity}, _From, S) ->
    H = maps:get(Identity, S#s.histories),
    {reply, #{height => H#history.height, hint => H#history.hinted_height,
              inflight => H#history.follow_inflight, dirty => H#history.follow_dirty,
              token => H#history.follow_token}, S};
handle_private_call(test_page_rows, _From, S) ->
    Rows = maps:map(fun(_ReqId, #pull{from = From, caller = Caller, binding = Binding,
                                     deadline = Deadline, turn = Turn}) ->
                        #{caller => Caller, binding => Binding, deadline => Deadline,
                          turn => Turn, from_pending => From =/= none}
                    end, S#s.pulls),
    {reply, Rows, S};
handle_private_call(test_page_binding, _From, S) ->
    Rows = maps:map(fun(Ref, B) ->
                       #{ref => Ref, link => B#page_binding.link,
                         active => B#page_binding.active, credit => B#page_binding.credit,
                         retiring => B#page_binding.retiring,
                         waiting => queue:to_list(B#page_binding.waiting)}
                   end, S#s.page_bindings),
    {reply, Rows, S};
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

handle_verification(
  {verify, Peer, Endpoint, Ref, Phase, TimeoutMs}, Caller, From, S0) ->
    case validate_route_request(Peer, Endpoint, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_verification(
              Peer, Endpoint, Ref, Phase, Caller,
              S0#s.fetch_fun, Identity, From, S0);
        {error, Reason} ->
            observe_unadmitted_caller(Caller, foreign_trace_reason({error, Reason})),
            {reply, {error, Reason}, S0}
    end;
handle_verification(
  {verify_reference, Ref, Phase, Contact, EntryHint, TimeoutMs}, Caller, From, S0) ->
    case validate_reference_request(Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            begin_current_worker(
              Identity, [], Contact, Caller,
              {exact_reference, Ref, Phase, EntryHint},
              From, S0);
        {error, Reason} ->
            observe_unadmitted_caller(Caller, foreign_trace_reason({error, Reason})),
            {reply, {error, Reason}, S0}
    end;
handle_verification(
  {verify_local, View, Ref, Phase, TimeoutMs}, Caller, From, S0) ->
    case validate_local_request(View, Ref, Phase, TimeoutMs) of
        {ok, Identity} ->
            LocalPeer = {local, Identity},
            FetchFun =
                fun(_Peer, _Endpoint, Ns, FromIndex, ToIndex) ->
                    local_view_fetch(View, Ns, FromIndex, ToIndex)
                end,
            begin_worker(
              LocalPeer, Identity, Caller,
              {local_exact, View, Ref, Phase}, FetchFun, From, S0);
        {error, Reason} ->
            observe_unadmitted_caller(Caller, foreign_trace_reason({error, Reason})),
            {reply, {error, Reason}, S0}
    end;
handle_verification(
  {current, Routes, Identity, Contact, TimeoutMs},
  Caller, From, S0) ->
    case validate_current_identity_request(
           Routes, Identity, TimeoutMs) of
        ok ->
            begin_current_worker(
              Identity, flatten_route_candidates(Routes), Contact, Caller,
              {current_identity, Identity},
              From, S0);
        {error, Reason} ->
            observe_unadmitted_caller(Caller, foreign_trace_reason({error, Reason})),
            {reply, {error, Reason}, S0}
    end.

valid_caller_deadline({verify_local, _, _, _, infinity}, infinity) -> true;
valid_caller_deadline(_Request, Deadline) -> is_integer(Deadline).

begin_verification(Peer, Endpoint, Ref, Phase, TimeoutMs, FetchFun,
                   Identity, From, S0) ->
    begin_worker(
      Peer, Identity, TimeoutMs,
      {exact, Peer, Endpoint, Ref, Phase}, FetchFun, From, S0).

begin_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    case start_worker(Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) of
        {ok, S1} -> {noreply, S1}
    end.

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
    %% Subscribe before route selection/dispatch. An accepted edge during
    %% the attempt belongs to that attempt even if it later parks.
    S1 = open_progress_signals(Identity, ensure_history(Identity, S0)),
    RequestRef = make_ref(),
    {InternalFrom, Callers} = request_owners(RequestRef, From, TimeoutMs),
    Queued = #queued_request{
                ref = RequestRef, from = InternalFrom,
                callers = stage_callers(Callers, queued),
                peer = none, identity = Identity, work = Work,
                fetch_fun = S1#s.fetch_fun,
                enqueued_native = erlang:monotonic_time()},
    {ok, enqueue_request(Queued, S1)}.

resolve_routed_work(Identity, #routed_work{supplied = Supplied,
                                            contact = Contact,
                                            kind = Kind}, S0) ->
    case selected_route_sources(Identity, Supplied, S0) of
        {ok, Sources0} ->
            Sources = add_request_contact(Contact, Sources0),
            case routed_source_candidates(Kind, Sources) of
                [{Peer, _Endpoint} | _] ->
                    {ready, Peer,
                     routed_worker_work(Kind, Sources, follow_request_timeout(S0))};
                [] ->
                    {wait, no_route}
            end;
        {error, anchor_conflict} ->
            {wait, anchor_conflict}
    end.

routed_worker_work(
  {exact_reference, Ref, Phase, EntryHint}, Sources, _ProbeTimeout) ->
    {exact_routes,
     history_source_candidates(Sources),
     Ref, Phase, EntryHint};
routed_worker_work({current_identity, Identity}, Sources, ProbeTimeout) ->
    {current_identity, Sources, Identity, ProbeTimeout}.

routed_source_candidates({exact_reference, _Ref, _Phase, _EntryHint}, Sources) ->
    history_source_candidates(Sources);
routed_source_candidates(_CurrentWork, Sources) ->
    flatten_route_candidates(route_candidates(Sources)).

start_distinct_worker(
  Peer, Identity, TimeoutMs, Work, FetchFun, From, S0) ->
    S1 = ensure_history(Identity, S0),
    RequestRef = make_ref(),
    {InternalFrom, Callers} = request_owners(
                                RequestRef, From, TimeoutMs),
    Queued = #queued_request{
                ref = RequestRef, from = InternalFrom,
                callers = stage_callers(Callers, queued), peer = Peer,
                identity = Identity, work = Work, fetch_fun = FetchFun,
                source = monitor_work_source(RequestRef, Work),
                enqueued_native = erlang:monotonic_time()},
    {ok, enqueue_request(Queued, S1)}.

enqueue_request(#queued_request{identity = Identity} = Queued, S0) ->
    %% Every arrival uses the same selector: distinct routes may bypass a
    %% route park, but no new arrival may bypass this cache's custody wait.
    H0 = maps:get(Identity, S0#s.histories),
    {_, JobId, _} = launch_identity(queued_launch_identity(Queued)),
    H1 = H0#history{waiting = queue:in(
          Queued#queued_request{job_id = JobId}, H0#history.waiting)},
    start_next_request(Identity, put_history(Identity, H1, S0)).

launch_request_owned(RequestRef, Peer, Identity,
                     Work, FetchFun, InternalFrom, Callers, S0) ->
    launch_request_owned(
      RequestRef, Peer, Identity, Work, Work, FetchFun,
      InternalFrom, Callers, S0).

launch_request_owned(LaunchIdentity, Peer, Identity,
                     RequestWork, WorkerWork, FetchFun,
                     InternalFrom, Callers0, S0) ->
    {RequestRef, JobId, Attempt} = launch_identity(LaunchIdentity),
    Callers = stage_callers(Callers0, acquiring),
    annotate_caller_stages(Callers, work_lifetime_attributes(RequestWork)),
    ResidentStarted = erlang:monotonic_time(),
    ResidentResult = resident_current_identity(WorkerWork, Identity, S0),
    case ResidentResult of
        {ok, Evidence} ->
            observe_foreign_stage(
              resident_current_hit, ok, ResidentStarted),
            observe_foreign_stage(
              request_current, ok, ResidentStarted),
            cancel_caller_timers(Callers),
            reply_request_callers(Callers, {ok, Evidence}),
            start_next_request(Identity, touch_history(Identity, S0));
        miss ->
            observe_foreign_stage(
              resident_current_miss, ok, ResidentStarted),
            Owner = self(),
            Root = S0#s.root,
            PageTimeout = S0#s.page_timeout_ms,
            Source = monitor_work_source(RequestRef, RequestWork),
            Worker = spawn_verification_worker(
                       RequestRef, RequestWork,
                       fun() ->
                           case acquire_cache_custody(Owner, RequestRef, Identity) of
                               {ok, Resident, Trace} ->
                                   verification_custody_acquired(RequestRef),
                                   verification_worker(
                                     Owner, RequestRef, WorkerWork, Root, FetchFun,
                                     PageTimeout, Resident, Trace);
                               denied -> ok
                           end
                       end),
            MRef = erlang:monitor(process, Worker),
            _ = quod_process:kill_when_owner_dies(Owner, Worker),
            Timer = request_work_timer(RequestWork, RequestRef),
            Request = #request{from = InternalFrom, callers = Callers,
                               peer = Peer, identity = Identity,
                               worker = Worker, work = RequestWork,
                               mref = MRef, source = Source, timer = Timer,
                               fetch_fun = FetchFun, job_id = JobId, attempt = Attempt},
            H0 = maps:get(Identity, S0#s.histories),
            %% Transfer the suspended phase session only after this worker
            %% holds its registered cache name. Contention owns no disk state.
            H1 = H0#history{active = RequestRef,
                            last_used = quod_time:mono_ms()},
            S0#s{pending = (S0#s.pending)#{RequestRef => Request},
                 histories = (S0#s.histories)#{Identity => H1}}
    end.

launch_identity({Ref, undefined, Attempt}) ->
    {Ref, binary:encode_hex(crypto:strong_rand_bytes(16), lowercase), Attempt};
launch_identity({Ref, Id, Attempt}) -> {Ref, Id, Attempt}.

queued_launch_identity(Q) ->
    {Q#queued_request.ref, Q#queued_request.job_id, Q#queued_request.attempt}.

cache_writer_key(Identity) -> {foreign_cache_writer, Identity}.

prepare_cache_custody(Root, Identity, Resident) ->
    %% Admission inspection was read-only. Re-read/recover through the ordinary
    %% verifier; only this registered writer may sweep abandoned files.
    CacheNs = cache_namespace(Identity),
    Retained = case Resident of
        {verified_session, _, _, PhaseSession, _} -> PhaseSession;
        none -> none
    end,
    ok = cleanup_cache_temps(cache_dir(Root, CacheNs)),
    ok = quod_dtx_phase_index:cleanup(Root, CacheNs, Retained).

acquire_cache_custody(Owner, RequestRef, Identity) ->
    Registered = try quod_reg:reg(cache_writer_key(Identity))
                 catch error:badarg -> false; exit:_ -> false
                 end,
    case Registered of
        true ->
            %% The owner and source lifetimes are monitored. This local
            %% handoff does not borrow a detachable caller's deadline.
            case gen_server:call(Owner, {claim_cache_custody, RequestRef}, infinity) of
                {ok, _, _} = Grant -> Grant;
                {error, _} -> denied
            end;
        false ->
            Owner ! {cache_custody_denied, RequestRef, self()},
            denied
    end.

worker_trace({Ns, Anchor}, Callers, JobId, Attempt) ->
    Ordered = lists:sort(
                fun(A, B) -> A#caller.enqueued_native =< B#caller.enqueued_native end,
                maps:values(Callers)),
    Contexts = [otel_tracer:current_span_ctx(C#caller.trace_ctx)
                || C <- Ordered, C#caller.trace_ctx =/= undefined],
    case quod_trace:shared_context(Contexts) of
        none -> none;
        {Context, Links} ->
            {Context, Links, #{'quod.namespace' => Ns,
                              'quod.foreign.job_id' => JobId,
                              'quod.foreign.attempt' => Attempt,
                              'quod.genesis_anchor' => binary:encode_hex(Anchor, lowercase)}}
    end.

-ifdef(TEST).
%% A one-shot gate pauses the real admitted reader before disk work. Tests can
%% kill the source while an infinite public call is genuinely owned, without
%% replacing the verifier, source monitor, or worker-DOWN cleanup paths.
spawn_verification_worker(_RequestRef, Work, Fun) ->
    Gate = case Work of
               {local_exact, _, _, _} -> {local, erase({?MODULE, local_worker_gate})};
               {follow, _, _, _} -> {follow, erase({?MODULE, follow_worker_gate})};
               _ -> undefined
           end,
    ConfirmationGate = case Work of
                           #routed_work{kind = {current_identity, _}} ->
                               erase({?MODULE, confirmation_gate});
                           {current_identity, _, _, _} ->
                               erase({?MODULE, confirmation_gate});
                           _ -> undefined
                       end,
    spawn_opt(
      fun() ->
          put({?MODULE, confirmation_gate}, ConfirmationGate),
          put({?MODULE, custody_acquired_gate}, Gate),
          Fun()
      end, verification_worker_options()).

verification_custody_acquired(RequestRef) ->
    case erase({?MODULE, custody_acquired_gate}) of
        {local, {TestPid, Token}} ->
            TestPid ! {local_worker_held, Token, RequestRef, self()},
            receive {release_local_worker, Token} -> ok end;
        {follow, {TestPid, Token}} ->
            TestPid ! {follow_worker_held, Token, RequestRef, self()},
            receive {release_follow_worker, Token} -> ok end;
        _ -> ok
    end.
-else.
spawn_verification_worker(_RequestRef, _Work, Fun) ->
    spawn_opt(Fun, verification_worker_options()).
verification_custody_acquired(_RequestRef) -> ok.
-endif.

verification_worker_options() ->
    [{max_heap_size,
      #{size => foreign_worker_heap_words(), kill => true, error_logger => true}}].

request_owners(_RequestRef, {follow, _, _} = From, _TimeoutMs) ->
    {From, #{}};
request_owners(RequestRef, From, TimeoutMs) ->
    {none, add_request_caller(RequestRef, From, TimeoutMs, #{})}.

add_request_caller(RequestRef, From, Caller = #caller{deadline = Deadline}, Callers) ->
    Timer = request_caller_timer(RequestRef, From, Deadline),
    Observed = start_caller_residence(Caller),
    Callers#{From => Observed#caller{timer = Timer}}.

start_caller_residence(#caller{trace_ctx = undefined} = Caller) -> Caller;
start_caller_residence(#caller{trace_ctx = Context, enqueued_native = Enqueued,
                                deadline = Deadline} = Caller) ->
    {ResidenceCtx, Span} = quod_trace:start_span(
        Context, <<"quod.foreign.caller_residence">>, internal,
        (caller_budget_attributes(Deadline))#{
          'quod.owner.mailbox_native' => erlang:monotonic_time() - Enqueued}),
    stage_caller(Caller#caller{residence = {ResidenceCtx, Span}}, admitted).

observe_unadmitted_caller(Caller, Cause) ->
    end_caller_residence(start_caller_residence(Caller), Cause).

stage_callers(Callers, Stage) ->
    maps:map(fun(_From, Caller) -> stage_caller(Caller, Stage) end, Callers).

annotate_caller_stages(Callers, Attributes) ->
    maps:foreach(fun(_From, #caller{stage = Stage}) ->
        case Stage of
            none -> ok;
            {_, Span} -> _ = quod_trace:set_attributes(Span, Attributes), ok
        end
    end, Callers).

park_routed_callers(Callers, Reason) ->
    Parked = stage_callers(Callers, parked),
    annotate_caller_stages(Parked, #{'quod.owner.park_reason' => atom_to_binary(Reason)}),
    Parked.

stage_caller(#caller{residence = none} = Caller, _Stage) -> Caller;
stage_caller(#caller{stage = {Stage, _}} = Caller, Stage) -> Caller;
stage_caller(#caller{residence = {Context, _}, ordinal = Ordinal,
                     deadline = Deadline, queue_observation = {_, Count}} = Caller, Stage) ->
    end_caller_stage(Caller),
    {_, Span} = quod_trace:start_span(
        Context, <<"quod.foreign.owner_stage">>, internal,
        (caller_budget_attributes(Deadline))#{'quod.owner.stage' => atom_to_binary(Stage),
          'quod.owner.stage_ordinal' => Ordinal + 1}),
    Caller#caller{stage = {Stage, Span}, ordinal = Ordinal + 1,
                  queue_observation = {none, Count}}.

end_caller_stage(#caller{stage = none}) -> ok;
end_caller_stage(#caller{stage = {_, Span}}) ->
    _ = otel_span:end_span(Span),
    ok.

end_caller_residence(#caller{residence = none}, _Cause) -> ok;
end_caller_residence(#caller{residence = {_, Span}, ordinal = Count,
                             queue_observation = {_, Blockers}} = Caller, Cause) ->
    end_caller_stage(Caller),
    _ = quod_trace:set_attributes(Span, #{'quod.owner.stages_expected' => Count,
                                        'quod.owner.blockers_expected' => Blockers,
                                        'quod.owner.terminal' => atom_to_binary(Cause)}),
    _ = otel_span:end_span(Span),
    ok.

caller_budget_attributes(infinity) ->
    #{'quod.caller.budget_kind' => <<"infinity">>};
caller_budget_attributes(Deadline) ->
    #{'quod.caller.budget_kind' => <<"finite">>,
      'quod.caller.remaining_ms' => max(0, Deadline - quod_time:mono_ms())}.

work_lifetime_attributes({follow, _, _, Deadline}) ->
    #{'quod.foreign.work_lifetime' => <<"follow_deadline">>,
      'quod.foreign.work_remaining_ms' => max(0, Deadline - quod_time:mono_ms())};
work_lifetime_attributes({local_exact, _, _, _}) ->
    #{'quod.foreign.work_lifetime' => <<"source_lifetime">>};
work_lifetime_attributes(Work) ->
    %% These shared jobs have no caller-owned job timer. Per-page and current
    %% probe budgets remain their existing, separate dependency lifetimes.
    Lifetime = case observed_work_kind(Work) of
        <<"current">> -> <<"shared_current">>;
        _ -> <<"shared_exact">>
    end,
    #{'quod.foreign.work_lifetime' => Lifetime}.

observed_work_kind(#routed_work{kind = Kind}) -> observed_work_kind(Kind);
observed_work_kind({exact_reference, _, _, _}) -> <<"exact">>;
observed_work_kind({exact_routes, _, _, _, _}) -> <<"exact">>;
observed_work_kind({exact, _, _, _, _}) -> <<"exact">>;
observed_work_kind({local_exact, _, _, _}) -> <<"local_exact">>;
observed_work_kind({current_identity, _}) -> <<"current">>;
observed_work_kind({current_identity, _, _, _}) -> <<"current">>;
observed_work_kind({follow, _, _, _}) -> <<"follow">>;
observed_work_kind(_) -> <<"unknown">>.

request_caller_timer(_RequestRef, _From, infinity) ->
    none;
request_caller_timer(RequestRef, From, Deadline) ->
    erlang:send_after(
      max(0, Deadline - quod_time:mono_ms()), self(),
      {verification_caller_timeout, RequestRef, From}).

request_work_timer({follow, _Identity, _Sources, Deadline}, RequestRef) ->
    erlang:send_after(
      max(0, Deadline - quod_time:mono_ms()), self(),
      {verification_timeout, RequestRef});
request_work_timer(_Work, _RequestRef) ->
    none.

stripped_trace_context(undefined) -> undefined;
stripped_trace_context(Context) ->
    case quod_trace:shared_context([otel_tracer:current_span_ctx(Context)]) of
        {Clean, _Links} -> Clean;
        none -> undefined
    end.

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
  {current_identity, Sources, Identity, _ProbeTimeout}, Identity,
  S) ->
    resident_confirmed_current(Sources, Identity, S);
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
    retain_current_view(Identity, Height, S0);
retain_current_watch(_Identity, _Work, _Result, S0) ->
    S0.

retain_current_view(Identity, Height, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{height = Height, resident_verified = true} = H0 ->
            View = retained_current_view(Height, H0),
            H1 = H0#history{
                   current_watch = remote,
                   hinted_height = retained_hint(Height, H0),
                   current_view = View},
            open_progress_signals(Identity, put_history(Identity, H1, S0));
        _ ->
            S0
    end.

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
                    Joined = add_request_caller(RequestRef, From, TimeoutMs, Callers),
                    observe_active_join(maps:get(From, Joined), Request),
                    Stage = case Request#request.custody of
                        acquiring -> acquiring;
                        held -> running
                    end,
                    Staged = stage_callers(Joined, Stage),
                    annotate_caller_stages(Staged, work_lifetime_attributes(ActiveWork)),
                    {joined, Pending#{RequestRef => Request#request{
                        callers = Staged}}};
                false ->
                    no
            end;
        _ ->
            no
    end.

observe_active_join(#caller{trace_ctx = undefined}, _Request) -> ok;
observe_active_join(#caller{trace_ctx = Context}, Request) ->
    Links = case Request#request.trace_ctx of
        undefined -> [];
        WorkerContext -> opentelemetry:links([otel_tracer:current_span_ctx(WorkerContext)])
    end,
    quod_trace:with_span(Context, <<"quod.foreign.join">>, internal,
      #{'quod.worker.pid' => list_to_binary(pid_to_list(Request#request.worker)),
        'quod.foreign.job_id' => Request#request.job_id,
        'quod.foreign.attempt' => Request#request.attempt},
      Links, fun(_) -> ok end).

join_waiting_request(Work, From, TimeoutMs, Identity,
                     #history{waiting = Waiting0} = History, S) ->
    case join_waiting_item(
           Work, From, TimeoutMs, Identity, queue:to_list(Waiting0)) of
        {joined, Waiting1, Wake} ->
            S1 = put_history(
                   Identity,
                   History#history{waiting = queue:from_list(Waiting1)}, S),
            S2 = case Wake of
                     true -> start_next_request(Identity, S1);
                     false -> S1
                 end,
            {joined, observe_queue_blockers(Identity, S2)};
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
        wake ->
            {joined,
             [Queued#queued_request{
                callers = stage_callers(add_request_caller(
                            RequestRef, From, TimeoutMs, Callers), queued),
                parked = false} | Rest],
             true};
        true ->
            {joined,
             [Queued#queued_request{
                callers = stage_callers(add_request_caller(
                            RequestRef, From, TimeoutMs, Callers), waiting_stage(Parked))} | Rest],
             false};
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

prepend_join_waiting_item(Queued, {joined, Rest, Wake}) ->
    {joined, [Queued | Rest], Wake};
prepend_join_waiting_item(_Queued, no) ->
    no.

waiting_stage(true) -> parked;
waiting_stage(false) -> queued;
waiting_stage({custody, _}) -> custody_wait.

%% Route lists are not semantic identity for an active certified job, but a
%% parked row has no job yet. A new request arriving over the same currently
%% authenticated contact is a concrete availability edge: wake the one shared
%% row and verify again. A different supplied/contact hint keeps its own row so
%% it can run instead of donating its only route to the older wait.
shareable_waiting_work(
  #routed_work{contact = {Peer, Endpoint}, kind = Kind1},
  #routed_work{contact = {Peer, Endpoint}, kind = Kind2},
  true, Identity) ->
    case shareable_routed_kind(Kind1, Kind2, Identity) of
        true -> wake;
        false -> false
    end;
shareable_waiting_work(
  #routed_work{supplied = Supplied, contact = Contact, kind = Kind},
  #routed_work{supplied = Supplied, contact = Contact, kind = Kind},
  true, _Identity) ->
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
        Peer -> {noreply, handle_feed_signal(Peer, Link, Chan, Payload, S)}
    end;
handle_info({catchup_credit, Link, BindingRef, Grant}, S) ->
    {noreply, accept_page_credit(Link, BindingRef, Grant, S)};
handle_info({catchup_page, Link, BindingRef, Grant, ReqId, Result, NextGrant}, S) ->
    {noreply, accept_page_result(Link, BindingRef, Grant, ReqId, Result, NextGrant, S)};
handle_info({{catchup_page_owner_down, ReqId}, MRef, process, _Pid, _Reason}, S) ->
    case maps:get(ReqId, S#s.pulls, undefined) of
        #pull{mref = MRef} -> {noreply, cancel_pull(ReqId, puller_down, S)};
        _ -> {noreply, S}
    end;
handle_info({{catchup_binding_down, BindingRef}, MRef, process, Link, _Reason}, S) ->
    case maps:get(BindingRef, S#s.page_bindings, undefined) of
        #page_binding{ref = BindingRef, mref = MRef, link = Link} ->
            {noreply, reopen_waiting_binding(BindingRef, retire_page_binding(BindingRef, S))};
        _ -> {noreply, S}
    end;
%% The same live-finality edge that drives the local feed is the reliable wake
%% for a co-hosted followed ontology.  The entry itself is never evidence here:
%% every interested identity still advances through the one certified follower.
handle_info({committed, Ns, Slot, _Entry}, S) ->
    {noreply, wake_namespace_progress(Ns, Slot, S)};
handle_info({certified_head, Ns, Slot}, S) ->
    {noreply, wake_namespace_progress(Ns, Slot, S)};
%% A materializer can discover its Root dependency immediately before or
%% after Root publishes this edge.  The waiting handler below covers the
%% crossed order; this edge resumes every worker already parked on it.
handle_info({replay_ready, _Id, _Height}, S) ->
    {noreply, resume_network_identity_projections(S)};
handle_info({foreign_worker_done, RequestRef, Result, Meta0}, S0) ->
    handle_worker_done(RequestRef, Result, Meta0, S0);
handle_info({cache_custody_denied, RequestRef, Worker}, S0) ->
    {noreply, park_cache_custody(RequestRef, Worker, S0)};
handle_info({verification_trace, RequestRef, Worker, Span}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker} = Request ->
            Context = otel_tracer:set_current_span(otel_ctx:new(), Span),
            S1 = S0#s{pending = (S0#s.pending)#{RequestRef =>
                                      Request#request{trace_ctx = Context}}},
            {noreply, observe_queue_blockers(Request#request.identity, S1)};
        _ -> {noreply, S0}
    end;
handle_info({verification_caller_timeout, RequestRef, From}, S0) ->
    {noreply, expire_request_caller(RequestRef, From, S0)};
handle_info({verification_timeout, RequestRef}, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker} = Request ->
            exit(Worker, kill),
            %% Keep this identity active until the monitor confirms that the
            %% cache worker is dead.  Releasing it here could admit a second
            %% writer against the same ledger/checkpoint between `exit/2` and
            %% the eventual DOWN message.
            S1 = S0#s{pending = (S0#s.pending)#{RequestRef =>
                                      Request#request{retiring = true}}},
            {noreply, observe_queue_blockers(Request#request.identity, S1)};
        undefined ->
            {noreply, S0}
    end;
handle_info({pull_timeout, ReqId}, S0) ->
    {noreply, cancel_pull(ReqId, page_expired, S0)};
handle_info({follow_refresh, Identity, Token}, S0) ->
    {noreply, begin_follow_refresh(Identity, Token, S0)};
handle_info({directory_route_available, Identity}, S0) ->
    S1 = reopen_identity_bindings(Identity, reconcile_feed_registrations(Identity, S0)),
    S2 = release_route_waiters(Identity, directory_route, S1),
    {noreply, wake_follow_if_route_needed(Identity, S2)};
handle_info(
  {gproc, unreg, Monitor, _Name},
  S0 = #s{transport_monitor = Monitor}) ->
    %% The transport owns every connection and stream.  Its replacement
    %% invalidates both completed links and openings whose cast may have died
    %% in the old owner's mailbox.  Keep only semantic follow/verification
    %% interest; the exact registered edge below rebuilds from current routes.
    S1 = lists:foldl(fun retire_page_binding/2, S0, maps:keys(S0#s.page_bindings)),
    {noreply, close_all_feed_registrations(S1)};
handle_info(
  {gproc, registered, Monitor, _Name},
  S0 = #s{transport_monitor = Monitor}) ->
    S1 = lists:foldl(fun reopen_waiting_binding/2, S0, maps:keys(S0#s.page_bindings)),
    {noreply, reconcile_all_feed_registrations(S1)};
handle_info({gproc, unreg, Monitor, {n, l, {foreign_cache_writer, Identity}}}, S0) ->
    {noreply, release_cache_custody(Identity, Monitor, S0)};
handle_info(
  {link_up, OpenRef, <<_:256>> = Peer, Chan, Link}, S0)
  when is_reference(OpenRef), is_binary(Chan), is_pid(Link) ->
    case maps:is_key(OpenRef, S0#s.feed_registration_openings) of
        true -> {noreply, finish_feed_registration_open(OpenRef, Peer, Chan, Link, S0)};
        false -> {noreply, finish_page_open(OpenRef, Peer, Chan, Link, S0)}
    end;
handle_info(
  {link_error, OpenRef, <<_:256>> = Peer, Chan}, S0)
  when is_reference(OpenRef), is_binary(Chan) ->
    {noreply, fail_page_open(OpenRef, Peer, Chan,
                fail_feed_registration_open(OpenRef, Peer, Chan, S0))};
handle_info(
  {foreign_projection_building, Identity, Generation, Height}, S0) ->
    {noreply, projection_building(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_waiting, Identity, Generation, _Reason, Height}, S0) ->
    {noreply, projection_waiting(Identity, Generation, Height, S0)};
handle_info(
  {foreign_projection_ready, Identity, Generation, Result}, S0) ->
    {noreply, projection_ready(Identity, Generation, Result, S0)};
handle_info({{borrow_down, Identity, RequestRef}, MRef, process, Owner, _Reason}, S0) ->
    {noreply, borrow_source_down(Identity, RequestRef, MRef, Owner, S0)};
handle_info({'DOWN', MRef, process, Pid, Reason}, S0) ->
    case maps:get(MRef, S0#s.feed_registration_monitors, undefined) of
        {_Identity, _Peer} ->
            {noreply, feed_registration_down(MRef, Pid, S0)};
        undefined ->
            case request_by_monitor(MRef, S0#s.pending) of
                {ok, RequestRef} ->
                    Request = maps:get(RequestRef, S0#s.pending),
                    Cause = case Request#request.source of
                        down -> source_down;
                        _ -> worker_down
                    end,
                    {noreply, finish_request(RequestRef, {error, retry}, Cause, S0)};
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

terminate(_Reason, #s{page_bindings = Bindings,
                      progress_channels = ProgressChannels,
                      histories = Histories,
                      feed_registrations = FeedRegistrations,
                      transport_monitor = TransportMonitor, pending = Pending}) ->
    maps:foreach(fun(_Ref, R) ->
        maps:foreach(fun(_From, C) -> end_caller_residence(C, owner_down) end,
                     R#request.callers)
    end, Pending),
    maps:foreach(
      fun(Identity, #history{materializer = Materializer,
                            waiting = Waiting, phase_session = PhaseSession}) ->
              lists:foreach(fun(Q) ->
                  release_custody_monitor(Identity, Q),
                  maps:foreach(fun(_From, C) -> end_caller_residence(C, owner_down) end,
                               Q#queued_request.callers)
              end, queue:to_list(Waiting)),
              stop_materializer(Materializer),
              close_phase_session(PhaseSession)
      end, Histories),
    maps:foreach(fun release_page_binding/2, Bindings),
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
    case validate_reference(Ref, TimeoutMs) of
        {ok, Identity} ->
            case valid_phase(Phase) of
                true -> {ok, Identity};
                false -> {error, bad_foreign_reference}
            end;
        {error, _} = Error ->
            Error
    end.

normalize_entry_hint(Entry) ->
    case quod_catchup:page_stats([Entry]) of
        {ok, 1, _Bytes} -> Entry;
        {error, _} -> none
    end.

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
  #{owner := Owner, identity := {Ns, Anchor}, slot := Height,
    applied := Applied, snapshot := _Snapshot, projection := Projection},
  {quod_dtx_ref, 2, Ns, <<_:256>> = Anchor, Slot,
   <<_:256>>, <<_:256>>, Proof} = Ref,
  Phase, TimeoutMs)
  when is_pid(Owner), is_integer(Height), Height >= 0,
       is_integer(Applied), Applied >= 0, Applied =< Height,
       is_binary(Ns), byte_size(Ns) > 0,
       byte_size(Ns) =< ?DIRECTORY_MAX_NAMESPACE_BYTES,
       is_integer(Slot), Slot > 0,
       is_binary(Proof), byte_size(Proof) > 0 ->
    case valid_local_timeout(TimeoutMs) andalso valid_phase(Phase)
         andalso quod_dtx:validate_certified_ref(Ref)
         andalso valid_projection(Projection, {Ns, Anchor}) of
        true -> {ok, {Ns, Anchor}};
        false -> {error, bad_foreign_reference}
    end;
validate_local_request(_View, _Ref, _Phase, _TimeoutMs) ->
    {error, bad_foreign_reference}.

valid_local_timeout(infinity) -> true;
valid_local_timeout(TimeoutMs) ->
    is_integer(TimeoutMs) andalso TimeoutMs > 0
        andalso TimeoutMs =< ?MAX_TIMER_MS - 1000.

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

validate_reference(Ref, TimeoutMs) ->
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
            {ok, #{request => [], live => Directory, supplied => Supplied,
                   bootstrap => Bootstrap, projection => Projection}}
    end.

add_request_contact(none, Sources) ->
    Sources;
add_request_contact({Peer, Endpoint}, Sources) ->
    %% The TLS-authenticated contact carrying this request is the freshest
    %% first-party endpoint for its key. Keep its provenance distinct and only
    %% in this work item: failed ontology authentication must leave no
    %% remembered identity or address, while both initial fetch and current-tip
    %% confirmation can still prefer the exact contact over stale stored hints.
    Sources#{request := [{Peer, Endpoint}]}.

route_candidates(#{request := Request, live := Live, supplied := Supplied,
                   bootstrap := Bootstrap, projection := Projection} = Sources) ->
    case is_map(Projection) of
        true -> current_route_candidates(Sources, Projection);
        false -> discovery_route_candidates(Request, Live, Supplied, Bootstrap)
    end.

discovery_route_candidates(Request, Live, Supplied, Bootstrap) ->
    Routes = lists:sublist(
               stable_unique_routes(Request ++ Live ++ Supplied ++ Bootstrap),
               ?MAX_VALIDATORS),
    [{Peer, [Endpoint]} || {Peer, Endpoint} <- Routes].

%% Fetching bytes and trusting an answer are different operations. Certified
%% committee routes stay first, but the same history verifier may fetch from a
%% current authenticated contact after every old host has left. The fallback
%% gains no vote and is never returned by route_hints/2 unless the fetched
%% history itself later certifies its key as a current validator.
history_source_candidates(
  #{request := Request, live := Live, supplied := Supplied,
    bootstrap := Bootstrap} = Sources) ->
    Certified = flatten_route_candidates(route_candidates(Sources)),
    Discovery = flatten_route_candidates(
                  discovery_route_candidates(
                    Request, Live, Supplied, Bootstrap)),
    lists:uniq(Certified ++ Discovery).

history_fallback_sources(Sources, CertifiedHints) ->
    Certified = flatten_route_candidates(CertifiedHints),
    [Source || Source <- history_source_candidates(Sources),
               not lists:member(Source, Certified)].

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
    S;
ensure_history(Identity, S0) ->
    H0 = load_or_new_history(S0#s.root, Identity),
    H = H0#history{bootstrap_hints = bootstrap_hints(Identity, S0)},
    S1 = S0#s{bootstrap = maps:remove(Identity, S0#s.bootstrap)},
    S1#s{histories = (S1#s.histories)#{Identity => H}}.

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

handle_worker_done(RequestRef, Result, Meta0, S0) ->
    Context = case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{trace_ctx = Ctx} -> Ctx;
        _ -> undefined
    end,
    quod_trace:with_optional_span(Context, <<"quod.foreign.result_install">>,
      internal, #{}, fun() -> receive_worker_result(RequestRef, Result, Meta0, S0) end).

receive_worker_result(RequestRef, Result, Meta0, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{} = Request ->
            case request_source_live(Request) of
                true -> install_worker_result(RequestRef, Result, Meta0, Request, S0);
                false ->
                    close_phase_session(maps:get(phase_session, Meta0, none)),
                    {noreply, cancel_source_request(RequestRef, S0)}
            end;
        undefined ->
            {noreply, S0}
    end.

install_worker_result(RequestRef, Result, Meta,
                      #request{identity = Identity, work = Work}, S0) ->
    S2 = measure_foreign_ok(
           result_install,
           fun() ->
               install_verified_progress(RequestRef, Meta, S0)
           end),
    S3 = retain_current_watch(Identity, Work, Result, S2),
    case {Result, maps:get(RequestRef, S3#s.pending, undefined)} of
        {{error, retry}, #request{work = #routed_work{}}} ->
            {noreply, park_failed_routed_request(RequestRef, S3)};
        _ ->
            {noreply, finish_request(RequestRef, Result,
                                    foreign_trace_reason(Result), S3)}
    end.

%% A local borrow is owned by the existing queued/active request, including an
%% infinite caller. The exact view participates in work equality: replacing a
%% source or advancing its session cannot join a different borrowed operation.
monitor_work_source(
  RequestRef, {local_exact, #{owner := Owner, identity := Identity}, _Ref, _Phase}) ->
    monitor_source_owner(Identity, RequestRef, Owner);
monitor_work_source(_RequestRef, _Work) ->
    none.

monitor_source_owner(Identity, RequestRef, Owner) ->
    {Owner, erlang:monitor(
              process, Owner, [{tag, {borrow_down, Identity, RequestRef}}])}.

release_source_monitor({Owner, MRef}) when is_pid(Owner), is_reference(MRef) ->
    _ = erlang:demonitor(MRef, [flush]),
    ok;
release_source_monitor(_NoneOrDown) ->
    ok.

request_source_live(#request{retiring = true}) -> false;
request_source_live(#request{source = none}) -> true;
request_source_live(#request{source = down}) -> false;
request_source_live(#request{identity = Identity, source = {Owner, _MRef}}) ->
    quod_simplex:history_view_live(#{owner => Owner, identity => Identity}).

borrow_source_down(Identity, RequestRef, MRef, Owner, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{identity = Identity, source = {Owner, MRef}} ->
            cancel_source_request(RequestRef, S0);
        undefined ->
            queued_source_down(Identity, RequestRef, MRef, Owner, S0);
        _ -> S0
    end.

cancel_source_request(RequestRef, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{source = down} -> S0;
        #request{worker = Worker, source = Source} = Request ->
            release_source_monitor(Source),
            exit(Worker, kill),
            %% The cache writer still owns this identity until its exact DOWN.
            %% Late success is discarded, and the ordinary DOWN completion
            %% replies retry to every caller of only this borrowed operation.
            Pending = (S0#s.pending)#{
                        RequestRef => Request#request{source = down, retiring = true}},
            observe_queue_blockers(Request#request.identity, S0#s{pending = Pending});
        undefined -> S0
    end.

queued_source_down(Identity, RequestRef, MRef, Owner, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{} = H0 ->
            drop_queued_source(Identity, RequestRef, MRef, Owner, H0, S0);
        undefined -> S0
    end.

drop_queued_source(Identity, RequestRef, MRef, Owner, H0, S0) ->
    {Drop, Keep} = lists:partition(
                     fun(#queued_request{ref = Ref, source = Source}) ->
                             Ref =:= RequestRef andalso Source =:= {Owner, MRef}
                     end, queue:to_list(H0#history.waiting)),
    case Drop of
        [] -> S0;
        [#queued_request{callers = Callers, source = Source} = Queued] ->
            release_custody_monitor(Identity, Queued),
            release_source_monitor(Source),
            cancel_caller_timers(Callers),
            reply_request_callers(Callers, {error, retry}, source_down),
            S1 = put_history(
                   Identity, H0#history{waiting = queue:from_list(Keep)}, S0),
            start_next_request(Identity, S1)
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
        {#request{from = From, callers = Callers0,
                  identity = Identity, work = #routed_work{} = Work,
                  mref = MRef, timer = Timer, progress_edge = Edge,
                  job_id = JobId, attempt = Attempt}, Pending1} ->
            Callers = live_request_callers(Callers0),
            annotate_caller_stages(Callers, #{'quod.owner.progress_edge_consumed' => Edge}),
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
                                callers = case Edge of
                                    true -> stage_callers(Callers, queued);
                                    false -> park_routed_callers(Callers, no_progress_edge)
                                end,
                                peer = none,
                                identity = Identity, work = Work,
                                fetch_fun = S1#s.fetch_fun,
                                parked = not Edge,
                                job_id = JobId, attempt = Attempt + 1,
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

park_cache_custody(RequestRef, Worker, S0) ->
    case maps:get(RequestRef, S0#s.pending, undefined) of
        #request{worker = Worker, custody = acquiring, retiring = false, from = From,
                 callers = Callers, identity = Identity, peer = Peer,
                 work = Work, source = Source, mref = MRef, timer = Timer,
                 fetch_fun = FetchFun, job_id = JobId, attempt = Attempt} ->
            %% An absent name immediately emits unreg. Installing the monitor
            %% before the row is safe because this owner serializes both turns.
            %% A registry outage here fails this owner, never strands an
            %% unmonitored wait. No lookup is treated as writer release.
            Monitor = quod_reg:monitor_name(cache_writer_key(Identity), info),
            cancel_optional_timer(Timer),
            _ = erlang:demonitor(MRef, [flush]),
            Histories = clear_active_request(Identity, RequestRef, S0#s.histories),
            H0 = maps:get(Identity, Histories),
            Queued = #queued_request{ref = RequestRef, from = From,
                        callers = stage_callers(Callers, custody_wait),
                        identity = Identity, peer = Peer, work = Work,
                        source = Source, fetch_fun = FetchFun,
                        parked = {custody, Monitor},
                        job_id = JobId, attempt = Attempt,
                        enqueued_native = erlang:monotonic_time()},
            observe_queue_blockers(Identity, S0#s{
                 pending = maps:remove(RequestRef, S0#s.pending),
                 histories = Histories#{Identity => H0#history{
                     waiting = queue:in_r(Queued, H0#history.waiting)}}});
        _ -> S0
    end.

release_cache_custody(Identity, Monitor, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{waiting = Waiting} = H0 ->
            Items = queue:to_list(Waiting),
            case lists:any(fun(Q) -> Q#queued_request.parked =:= {custody, Monitor} end,
                           Items) of
                true ->
                    _ = quod_reg:demonitor_name(cache_writer_key(Identity), Monitor),
                    Ready = [case Q#queued_request.parked of
                                 {custody, Monitor} -> Q#queued_request{parked = false,
                                     callers = stage_callers(Q#queued_request.callers, queued)};
                                 _ -> Q
                             end || Q <- Items],
                    start_next_request(Identity, put_history(
                        Identity, H0#history{waiting = queue:from_list(Ready)}, S0));
                false -> S0
            end;
        _ -> S0
    end.

release_custody_monitor(Identity, #queued_request{parked = {custody, Monitor}}) ->
    _ = catch quod_reg:demonitor_name(cache_writer_key(Identity), Monitor),
    ok;
release_custody_monitor(_Identity, _Queued) -> ok.

clear_active_request(Identity, RequestRef, Histories) ->
    case maps:get(Identity, Histories, undefined) of
        #history{active = RequestRef} = H0 ->
            Histories#{Identity => H0#history{
                                     active = none,
                                     last_used = quod_time:mono_ms()}};
        _ ->
            Histories
    end.

finish_request(RequestRef, Reply, Cause, S0) ->
    case maps:take(RequestRef, S0#s.pending) of
        {#request{from = From, callers = Callers,
                  identity = Identity, source = Source,
                  mref = MRef, timer = Timer}, Pending1} ->
            cancel_optional_timer(Timer),
            cancel_caller_timers(Callers),
            release_source_monitor(Source),
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
                    reply_request_callers(Callers, Reply, Cause),
                    S2
            end,
            release_idle_page_bindings(start_next_request(Identity, S3));
        error ->
            S0
    end.

reply_request_callers(Callers, Reply) ->
    reply_request_callers(Callers, Reply, foreign_trace_reason(Reply)).

reply_request_callers(Callers, Reply, ResultCause) ->
    measure_foreign_ok(
      caller_wake,
      fun() ->
          maps:foreach(
            fun(From, #caller{deadline = Deadline} = Caller) ->
                    Cause = case caller_live(Deadline) of
                        true -> ResultCause;
                        false -> expired
                    end,
                    end_caller_residence(Caller, Cause),
                    gen_server:reply(From, caller_result(Deadline, Reply))
            end, Callers)
      end).

live_request_callers(Callers) ->
    maps:filter(fun(From, #caller{deadline = Deadline, timer = Timer} = Caller) ->
        case caller_live(Deadline) of
            true -> true;
            false ->
                cancel_optional_timer(Timer),
                end_caller_residence(Caller, expired),
                gen_server:reply(From, {error, retry}),
                false
        end
    end, Callers).

cancel_optional_timer(none) -> ok;
cancel_optional_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

cancel_caller_timers(Callers) ->
    maps:foreach(
      fun(_Caller, #caller{timer = Timer}) ->
              cancel_optional_timer(Timer),
              ok
      end, Callers).

start_next_request(Identity, S0) ->
    observe_queue_blockers(Identity, select_next_request(Identity, S0)).

select_next_request(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{active = none, waiting = Waiting0} = H0 ->
            case take_runnable_request(
                   Identity, queue:to_list(Waiting0), S0) of
                {ready, Queued, Peer, WorkerWork, Rest} ->
                    %% Admission remains in this owner turn. If the source died
                    %% during transfer, the new monitor immediately reports DOWN.
                    release_source_monitor(Queued#queued_request.source),
                    H1 = H0#history{waiting = queue:from_list(Rest)},
                    S1 = put_history(Identity, H1, S0),
                    observe_foreign_stage(
                      queue_wait, ok,
                      Queued#queued_request.enqueued_native),
                    case Queued#queued_request.work of
                        #routed_work{} = RequestWork ->
                            launch_request_owned(
                              queued_launch_identity(Queued), Peer, Identity,
                                              RequestWork, WorkerWork,
                              Queued#queued_request.fetch_fun,
                              Queued#queued_request.from,
                              Queued#queued_request.callers, S1);
                        _ ->
                            launch_request_owned(
                              queued_launch_identity(Queued), Peer, Identity,
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

%% Observe only this identity's existing selector/lifetime transitions. There is
%% no scheduling index: route parks are bypassable, a custody head is not, and
%% an active worker remains the predecessor through retirement until its DOWN.
%% The long owner_stage already measures queue residence; these short linked
%% children identify changes within it without replacing its duration or parent.
observe_queue_blockers(Identity, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{waiting = Waiting, active = Active} = H ->
            case queue:is_empty(Waiting) of
                true -> S0;
                false ->
                    Blocker = case maps:get(Active, S0#s.pending, undefined) of
                        #request{} = R -> active_queue_descriptor(R);
                        undefined -> none
                    end,
                    {Rows, _} = lists:mapfoldl(
                      fun(Q, Earlier) ->
                          Own = case Q#queued_request.parked of
                              true -> queued_descriptor(route_park, Q, false);
                              {custody, _} -> queued_descriptor(custody_wait, Q, false);
                              false -> case Earlier of
                                  none -> unknown_queue_descriptor();
                                  _ -> Earlier
                              end
                          end,
                          Callers = maps:map(fun(_From, C) ->
                              observe_queue_caller(C, Identity, Own)
                          end, Q#queued_request.callers),
                          Next = case {Earlier, Q#queued_request.parked} of
                              {none, {custody, _}} ->
                                  queued_descriptor(earlier_custody_wait, Q, true);
                              {none, false} -> queued_descriptor(earlier_queued, Q, true);
                              _ -> Earlier
                          end,
                          {Q#queued_request{callers = Callers}, Next}
                      end, Blocker, queue:to_list(Waiting)),
                    put_history(Identity, H#history{waiting = queue:from_list(Rows)}, S0)
            end;
        undefined -> S0
    end.

active_queue_descriptor(R) ->
    Class = case R#request.retiring of true -> retiring; false -> active end,
    Age = case maps:values(R#request.callers) of
        [] -> #{'quod.owner.blocker_age_kind' => <<"unknown">>};
        Callers ->
            Oldest = lists:min([C#caller.enqueued_native || C <- Callers]),
            #{'quod.owner.blocker_age_kind' => <<"oldest_live_caller">>,
              'quod.owner.blocker_age_native' => erlang:monotonic_time() - Oldest}
    end,
    queue_descriptor(Class, R#request.job_id, R#request.attempt,
                     R#request.work, R#request.trace_ctx, Age).

queued_descriptor(Class, Q, LinkCaller) ->
    Context = case LinkCaller of
        false -> undefined;
        true -> case worker_trace(Q#queued_request.identity,
                        Q#queued_request.callers, Q#queued_request.job_id,
                        Q#queued_request.attempt) of
            none -> undefined;
            {Ctx, _, _} -> Ctx
        end
    end,
    queue_descriptor(Class, Q#queued_request.job_id, Q#queued_request.attempt,
      Q#queued_request.work, Context,
      #{'quod.owner.blocker_age_kind' => <<"queue_row">>,
        'quod.owner.blocker_age_native' =>
            erlang:monotonic_time() - Q#queued_request.enqueued_native}).

queue_descriptor(Class, JobId, Attempt, Work, Context, Age) ->
    Span = case Context of
        undefined -> undefined;
        _ -> otel_tracer:current_span_ctx(Context)
    end,
    Recorded = otel_span:is_recording(Span),
    {LinkKey, Links} = case Recorded of
        true -> {{otel_span:trace_id(Span), otel_span:span_id(Span)},
                 opentelemetry:links([Span])};
        false -> {none, []}
    end,
    Kind = observed_work_kind(Work),
    {{Class, JobId, Attempt, Kind, LinkKey},
      Age#{'quod.owner.blocker' => atom_to_binary(Class),
           'quod.owner.blocker_job_id' => JobId,
           'quod.owner.blocker_attempt' => Attempt,
           'quod.owner.blocker_work' => Kind,
           'quod.owner.blocker_trace_available' => Recorded}, Links}.

unknown_queue_descriptor() ->
    {unknown, #{'quod.owner.blocker' => <<"unknown">>,
                'quod.owner.blocker_trace_available' => false,
                'quod.owner.blocker_age_kind' => <<"unknown">>}, []}.

observe_queue_caller(#caller{residence = none} = Caller, _Identity, _Descriptor) -> Caller;
observe_queue_caller(#caller{queue_observation = {Key, _}} = Caller,
                     _Identity, {Key, _, _}) -> Caller;
observe_queue_caller(#caller{residence = {Context, Residence}, deadline = Deadline,
                             queue_observation = {_, Count}} = Caller,
                     {Ns, Anchor}, {Key, Attributes, Links}) ->
    case otel_span:is_recording(Residence) of
        false -> Caller;
        true ->
            quod_trace:with_span(Context, <<"quod.foreign.queue_blocker">>, internal,
              (maps:merge(Attributes, caller_budget_attributes(Deadline)))#{
                'quod.namespace' => Ns,
                'quod.genesis_anchor' => binary:encode_hex(Anchor, lowercase),
                'quod.owner.blocker_ordinal' => Count + 1}, Links, fun(_) -> ok end),
            Caller#caller{queue_observation = {Key, Count + 1}}
    end.

take_runnable_request(Identity, Waiting, S0) ->
    take_runnable_request(Identity, Waiting, [], S0).

take_runnable_request(_Identity, [], Skipped, _S0) ->
    {waiting, lists:reverse(Skipped)};
take_runnable_request(
  _Identity, [#queued_request{parked = {custody, _}} | _] = Rest, Skipped, _S0) ->
    %% Custody excludes every job for this cache, not just one routed row.
    {waiting, lists:reverse(Skipped) ++ Rest};
take_runnable_request(
  Identity,
  [Queued = #queued_request{work = #routed_work{}, parked = true} | Rest],
  Skipped, S0) ->
    take_runnable_request(Identity, Rest, [Queued | Skipped], S0);
take_runnable_request(
  Identity,
  [Queued = #queued_request{work = #routed_work{} = Work} | Rest],
  Skipped, S0) ->
    Callers = stage_callers(Queued#queued_request.callers, route_selection),
    case resolve_routed_work(Identity, Work, S0) of
        {ready, Peer, WorkerWork} ->
            annotate_caller_stages(Callers, #{'quod.owner.route_result' => <<"ready">>}),
            {ready, Queued#queued_request{callers = Callers}, Peer, WorkerWork,
             lists:reverse(Skipped) ++ Rest};
        {wait, Reason} ->
            annotate_caller_stages(Callers,
                #{'quod.owner.route_result' => atom_to_binary(Reason)}),
            take_runnable_request(
              Identity, Rest,
              [Queued#queued_request{parked = true,
                  callers = park_routed_callers(Callers, Reason)} | Skipped], S0)
    end;
take_runnable_request(
  _Identity, [Queued | Rest], Skipped, _S0) ->
    {ready, Queued, Queued#queued_request.peer,
     Queued#queued_request.work, lists:reverse(Skipped) ++ Rest}.

release_route_waiters(Identity, EventClass, S0) ->
    S1 = case maps:get(Identity, S0#s.histories, undefined) of
        #history{active = Ref, waiting = Waiting} ->
            lists:foreach(fun(#queued_request{parked = Parked, callers = Callers}) ->
                case Parked of
                    true -> annotate_caller_stages(Callers,
                              #{'quod.owner.wake' => atom_to_binary(EventClass)});
                    _ -> ok
                end
            end, queue:to_list(Waiting)),
            case maps:get(Ref, S0#s.pending, undefined) of
                #request{work = #routed_work{}, callers = Callers} = Request ->
                    annotate_caller_stages(Callers,
                        #{'quod.owner.wake' => atom_to_binary(EventClass),
                          'quod.owner.progress_edge_buffered' => true}),
                    S0#s{pending = (S0#s.pending)#{Ref =>
                                     Request#request{progress_edge = true}}};
                _ -> S0
            end;
        _ -> S0
    end,
    release_queued_route_waiters(Identity, S1).

release_queued_route_waiters(Identity, S0) ->
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

release_route_waiter(#queued_request{work = #routed_work{}, parked = true} = Queued) ->
    Queued#queued_request{parked = false,
        callers = stage_callers(Queued#queued_request.callers, queued)};
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
                {Caller, Callers1} ->
                    end_caller_residence(Caller, expired),
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
        {Caller, Callers1} ->
            end_caller_residence(Caller, expired),
            case Parked =:= true andalso map_size(Callers1) =:= 0 of
                true ->
                    release_source_monitor(Queued#queued_request.source),
                    {updated, Rest};
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

follow_materializer(FollowRef, ConsumerPid, S) ->
    case follow_consumer(FollowRef, S) of
        {ok, _Identity, #consumer{pid = ConsumerPid},
         #history{projection_state = ready,
                  materializer = #materializer{pid = Pid,
                                               generation = Generation}}} ->
            {ok, Pid, Generation};
        {ok, _Identity, #consumer{pid = ConsumerPid}, _History} ->
            {error, building};
        _ -> {error, not_found}
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
%% it, release its exact catch-up leases and disk handles, but retain the one bounded
%% projection, immutable ledger-index session, and suspended derived phase
%% session already verified by this owner. A current-view watch keeps the feed
%% freshness registration; the next real delta resumes the same verifier
%% instead of replaying or rescanning history.
%% After a node restart only the cache remains; first use verifies it fully.
hibernate_history(Identity, S0) ->
    S1 = case maps:get(Identity, S0#s.histories, undefined) of
        #history{active = none, consumers = Consumers, materializer = none,
                 follow_token = none, follow_inflight = false} = H0
          when map_size(Consumers) =:= 0 ->
            case queue:is_empty(H0#history.waiting) of
                true ->
                    Released = maybe_close_progress_signals(Identity, S0),
                    hibernate_idle_history(Identity,
                        maps:get(Identity, Released#s.histories), Released);
                false -> S0
            end;
        _ ->
            S0
    end,
    release_idle_page_bindings(S1).

hibernate_idle_history(_Identity,
                       #history{resident_verified = true}, S0) ->
    S0;
hibernate_idle_history(Identity, H, S0) ->
    close_phase_session(H#history.phase_session),
    Bootstrap = case H#history.bootstrap_hints of
                    [] -> maps:remove(Identity, S0#s.bootstrap);
                    Hints -> (S0#s.bootstrap)#{Identity => Hints}
                end,
    S0#s{histories = maps:remove(Identity, S0#s.histories),
              bootstrap = Bootstrap,
              total_bytes = max(0, S0#s.total_bytes - H#history.bytes)}.

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
                                    follow_inflight = true,
                                    follow_dirty = false,
                                    follow_start_height = H0#history.height},
                    S1 = put_history(Identity, H1, S0),
                    Timeout = follow_request_timeout(S1),
                    Deadline = quod_time:mono_ms() + Timeout,
                    case selected_route_sources(Identity, [], S1) of
                        {error, anchor_conflict} ->
                            finish_follow_refresh(
                              Identity, Token,
                              {error, {unreachable, anchor_conflict}}, S1);
                        {ok, Sources} ->
                            case start_worker(
                                   {follow, Identity}, Identity, Timeout,
                                   {follow, Identity, Sources, Deadline}, S1#s.fetch_fun,
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
            KnownHint = case {H0#history.hinted_height, Hint} of
                            {Old, New} when is_integer(Old), is_integer(New) -> max(Old, New);
                            {Old, unknown} -> Old;
                            {_, New} -> New
                        end,
            Advanced = Reason =:= none andalso
                       H0#history.height > H0#history.follow_start_height,
            H1 = H0#history{last_probe_ms = Now, hinted_height = KnownHint,
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
            continue_follow_progress(Identity, Advanced, KnownHint, S3);
        undefined ->
            S0
    end.

%% A certified page which says that a later tip already exists is also an
%% exact progress edge: continue immediately instead of waiting for another
%% feed digest.  It is merged with any signal received while the worker was
%% active, so both conditions still produce only one next job.  No unchanged
%% or failed result can create a loop.
continue_follow_progress(Identity, Advanced, Hint, S0) ->
    case maps:get(Identity, S0#s.histories, undefined) of
        #history{follow_dirty = Dirty, height = Height} = H0 ->
            MoreCertified =
                Advanced andalso
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
                 cache_session = CacheSession,
                 materializer = Materializer,
                 consumers = Consumers} = H0
          when Height > 0, is_map(Projection), CacheSession =/= none,
               map_size(Consumers) > 0 ->
            case history_head(Projection) of
                {Height, <<_:256>>} ->
                    View = #{owner => self(), identity => Identity, slot => Height,
                             snapshot => CacheSession, projection => Projection},
                    case Materializer of
                        none ->
                            {Pid, MRef, Generation} =
                                quod_foreign_projection:start_monitor(
                                  self(), Identity,
                                  quod_ledger_store:ns_dir(
                                    filename:join(S0#s.root, "projections"),
                                    H0#history.cache_ns), View),
                            M = #materializer{pid = Pid, mref = MRef,
                                              generation = Generation},
                            quod_foreign_projection:advance(
                              Pid, Generation, View),
                            put_history(
                              Identity,
                              H0#history{materializer = M,
                                         projection_state = building,
                                         projection_wait = none},
                              S0#s{projection_rebuilds =
                                       S0#s.projection_rebuilds + 1});
                        #materializer{pid = Pid, generation = Generation} ->
                            quod_foreign_projection:advance(
                              Pid, Generation, View),
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
    Pending = lists:foldl(fun({Ref, _}, Acc) ->
        Request = maps:get(Ref, Acc),
        Acc#{Ref => Request#request{retiring = true}}
    end, S0#s.pending, Matches),
    S1 = S0#s{pending = Pending},
    case maps:get(Identity, S1#s.histories, undefined) of
        #history{waiting = Waiting0} = H0 ->
            lists:foreach(fun(Q) ->
                case queued_follow(Identity, Q) of
                    true -> release_custody_monitor(Identity, Q);
                    false -> ok
                end
            end, queue:to_list(Waiting0)),
            Waiting1 =
                queue:from_list(
                  [Queued
                   || Queued <- queue:to_list(Waiting0),
                      not queued_follow(Identity, Queued)]),
            start_next_request(
              Identity, put_history(Identity, H0#history{waiting = Waiting1}, S1));
        undefined ->
            S1
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
    Refs = [ReqId || {ReqId, #pull{request_ref = Ref}} <- maps:to_list(S0#s.pulls),
                     Ref =:= RequestRef],
    Bindings = lists:usort([(maps:get(ReqId, S0#s.pulls))#pull.binding || ReqId <- Refs]),
    S1 = lists:foldl(fun(Id, Acc) -> cancel_pull_owned(Id, request_retired, Acc) end,
                    S0, Refs),
    lists:foldl(fun drive_page_binding/2, S1, Bindings).

%% Residency is not attempt permission. Only a new verified prefix can wake
%% parked siblings; an unchanged failed request must not wake another failed
%% request back and forth without an external progress edge.
install_verified_progress(RequestRef, Meta, S0) ->
    {ok, Identity} = request_identity(RequestRef, S0),
    OldHeight = (maps:get(Identity, S0#s.histories))#history.height,
    S1 = install_worker_meta(
           RequestRef, Meta, record_follow_progress(RequestRef, Meta, S0)),
    case maps:get(resident_verified, Meta, false) andalso
         maps:get(height, Meta, OldHeight) > OldHeight of
        true -> release_queued_route_waiters(Identity, S1);
        false -> S1
    end.

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
                    Height = maps:get(height, Meta, H0#history.height),
                    PriorSession = case {Height, Projection} of
                                       {OldHeight, OldProjection}
                                         when OldHeight =:= H0#history.height,
                                              OldProjection =:= H0#history.projection ->
                                           H0#history.cache_session;
                                       _ -> none
                                   end,
                    CacheSession = maps:get(cache_session, Meta, PriorSession),
                    close_replaced_phase_session(
                      H0#history.phase_session, PhaseSession),
                    CurrentView = case ResidentVerified andalso
                                       Height =:= H0#history.height andalso
                                       Projection =:= H0#history.projection of
                                      true -> H0#history.current_view;
                                      false -> unconfirmed
                                  end,
                    H1 = H0#history{height = Height,
                                    bytes = ActualBytes,
                                    projection = Projection,
                                    resident_verified = ResidentVerified,
                                    phase_session = PhaseSession,
                                    cache_session = CacheSession,
                                    current_view = CurrentView,
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

suspend_phase_session(PhaseIndex) ->
    case measure_foreign_stage(
           phase_suspend,
           fun() -> quod_dtx_phase_index:suspend(PhaseIndex) end) of
        {ok, Session} -> Session;
        {error, _} ->
            close_phase_session(PhaseIndex),
            none
    end.

phase_session_stats(PhaseIndex) ->
    case quod_dtx_phase_index:stats(PhaseIndex) of
        {ok, #{rows := Rows, file_bytes := FileBytes}} ->
            #{phase_index_rows => Rows,
              phase_index_bytes => FileBytes};
        {error, _} ->
            #{}
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
            ok = quod_directory:route_needed(Identity),
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
                 H0#history.active =:= none andalso
                 queue:is_empty(H0#history.waiting) of
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
              Identity, release_route_waiters(Identity, feed_recipient, S1));
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
                  Identity, local_commit,
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
              Acc1 = release_route_waiters(Identity, peer_feed, Acc),
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

admit_pull(RequestRef, Identity = {Ns, _}, Work, Peer, Endpoint,
           FromIndex, ToIndex, Deadline0, TraceCtx, From = {Caller, _}, S0) ->
    Deadline = case Work of
                   {follow, _, _, WorkDeadline} -> min(Deadline0, WorkDeadline);
                   _ -> Deadline0
               end,
    case Deadline > quod_time:mono_ms() of
        false -> {reply, {error, retry}, S0};
        true ->
            {BindingRef, S1} = ensure_page_binding({Peer, Endpoint, Ns}, Identity, S0),
            ReqId = crypto:strong_rand_bytes(16),
            Timer = erlang:send_after(max(0, Deadline - quod_time:mono_ms()),
                                      self(), {pull_timeout, ReqId}),
            MRef = erlang:monitor(process, Caller, [{tag, {catchup_page_owner_down, ReqId}}]),
            Pull = #pull{from = From, caller = Caller, trace_ctx = TraceCtx,
                         request_ref = RequestRef, binding = BindingRef,
                         range = {FromIndex, ToIndex}, deadline = Deadline,
                         mref = MRef, timer = Timer},
            B = maps:get(BindingRef, S1#s.page_bindings),
            S2 = put_page_binding(B#page_binding{waiting = queue:in(ReqId, B#page_binding.waiting)},
                                  S1#s{pulls = (S1#s.pulls)#{ReqId => Pull}}),
            traced_page_owner(TraceCtx, page_admission,
              #{'quod.foreign.page_expected_terminal' => 1,
                'quod.foreign.page_id' => binary:encode_hex(ReqId, lowercase)},
              fun() ->
                  {noreply, drive_page_binding(BindingRef, reopen_waiting_binding(BindingRef, S2))}
              end)
    end.

ensure_page_binding(Key, Identity, S0) ->
    case maps:get(Key, S0#s.page_contacts, undefined) of
        undefined ->
            Ref = make_ref(),
            B = #page_binding{ref = Ref, key = Key, identities = #{Identity => true}},
            {Ref, put_page_binding(B, S0#s{page_contacts = (S0#s.page_contacts)#{Key => Ref}})};
        Ref ->
            B = maps:get(Ref, S0#s.page_bindings),
            {Ref, put_page_binding(B#page_binding{identities = (B#page_binding.identities)#{Identity => true}}, S0)}
    end.

put_page_binding(B = #page_binding{ref = Ref}, S) ->
    S#s{page_bindings = (S#s.page_bindings)#{Ref => B}}.

reopen_waiting_binding(Ref, S0) ->
    case maps:get(Ref, S0#s.page_bindings, undefined) of
        #page_binding{lease = none, link = none, retiring = false,
                      key = {Peer, Endpoint, Ns}, waiting = Waiting} = B ->
            case not queue:is_empty(Waiting) andalso
                 is_pid(quod_reg:where({transport, node})) of
                true ->
                    Lease = quod_quic:open_link_pinned_lease(Peer, Endpoint, quod_catchup:channel(Ns)),
                    put_page_binding(B#page_binding{lease = Lease},
                      S0#s{page_openings = (S0#s.page_openings)#{Lease => Ref}});
                false -> S0
            end;
        _ -> S0
    end.

finish_page_open(OpenRef, Peer, Chan, Link, S0) ->
    case maps:get(OpenRef, S0#s.page_openings, undefined) of
        undefined -> S0;
        Ref ->
            case maps:get(Ref, S0#s.page_bindings, undefined) of
                #page_binding{lease = OpenRef, link = none,
                              key = {Peer, _Endpoint, Ns}} = B ->
                    case Chan =:= quod_catchup:channel(Ns) of
                        true ->
                            MRef = erlang:monitor(process, Link, [{tag, {catchup_binding_down, Ref}}]),
                            quod_link:bind_catchup(Link, Ref),
                            put_page_binding(B#page_binding{link = Link, mref = MRef},
                              S0#s{page_openings = maps:remove(OpenRef, S0#s.page_openings)});
                        false -> S0
                    end;
                _ -> S0
            end
    end.

fail_page_open(OpenRef, Peer, Chan, S0) ->
    case maps:get(OpenRef, S0#s.page_openings, undefined) of
        undefined -> S0;
        Ref ->
            B = maps:get(Ref, S0#s.page_bindings),
            case B#page_binding.key of
                {Peer, _Endpoint, Ns} ->
                    case Chan =:= quod_catchup:channel(Ns) of
                        true ->
                            %% This concrete opening attempt has failed. Its
                            %% unsent pages complete once; only their existing
                            %% semantic owner may choose another source.
                            S1 = lists:foldl(
                                   fun(ReqId, S) -> complete_pull(ReqId, {error, link_down},
                                                                 link_down, S) end,
                                   S0, queue:to_list(B#page_binding.waiting)),
                            release_idle_page_bindings(retire_page_binding(Ref, S1));
                        false -> S0
                    end;
                _ -> S0
            end
    end.

accept_page_credit(Link, Ref, Grant, S0) ->
    case maps:get(Ref, S0#s.page_bindings, undefined) of
        #page_binding{link = Link, credit = none, active = none, retiring = false} = B ->
            drive_page_binding(Ref, put_page_binding(B#page_binding{credit = Grant}, S0));
        _ -> S0
    end.

drive_page_binding(Ref, S0) ->
    case maps:get(Ref, S0#s.page_bindings, undefined) of
        #page_binding{link = Link, credit = Grant, active = none,
                      retiring = false, waiting = Waiting} = B
          when is_pid(Link), is_binary(Grant) ->
            case queue:out(Waiting) of
                {empty, _} -> S0;
                {{value, ReqId}, Rest} ->
                    Pull = maps:get(ReqId, S0#s.pulls),
                    case Pull#pull.deadline > quod_time:mono_ms() of
                        false -> drive_page_binding(Ref,
                                   complete_pull(ReqId, {error, retry}, page_expired, S0));
                        true ->
                            {From, To} = Pull#pull.range,
                            quod_link:request_page(Link, Ref, Grant, ReqId, From, To),
                            put_page_binding(B#page_binding{credit = none, active = ReqId, waiting = Rest},
                              S0#s{pulls = (S0#s.pulls)#{ReqId => Pull#pull{turn = {sent, Link, Ref, Grant}}}})
                    end
            end;
        _ -> S0
    end.

accept_page_result(Link, Ref, Grant, ReqId, Result, NextGrant, S0) ->
    case {maps:get(Ref, S0#s.page_bindings, undefined), maps:get(ReqId, S0#s.pulls, undefined)} of
        {#page_binding{link = Link, active = ReqId, credit = none, retiring = false},
         #pull{binding = Ref, turn = {sent, Link, Ref, Grant}, deadline = Deadline}} ->
            case Deadline > quod_time:mono_ms() of
                false -> cancel_pull(ReqId, page_expired, S0);
                true -> accept_live_page_result(Link, Ref, Grant, ReqId, Result, NextGrant, S0)
            end;
        _ -> S0
    end.

accept_live_page_result(Link, Ref, Grant, ReqId, {ok, Blobs, Height}, NextGrant, S0) ->
    Pull = maps:get(ReqId, S0#s.pulls),
    %% Raw delivery consumes the call alias, not page custody. The original
    %% monitor/deadline and active binding survive until this worker completes
    %% decoding. No successor may overtake that completion.
    Key = {self(), ReqId, Ref, Link, Grant},
    Gate = take_page_decode_gate(),
    traced_page_owner(Pull#pull.trace_ctx, page_delivery,
      fun() ->
          gen_server:reply(Pull#pull.from,
                           {decode_page, Key, Blobs, Height, Pull#pull.deadline, Gate}),
          S0#s{pulls = (S0#s.pulls)#{ReqId => Pull#pull{
                    from = none, turn = {decoding, Link, Ref, Grant, NextGrant}}}}
      end);
accept_live_page_result(_Link, Ref, _Grant, ReqId, {error, _} = Error, NextGrant, S0) ->
    %% Wire errors are terminal without a decode turn, but still return credit.
    finish_page_turn(ReqId, Ref, Error, NextGrant, S0).

complete_page_decode({Owner, ReqId, Ref, Link, Grant}, Verdict, Caller, S0)
  when Owner =:= self(), (Verdict =:= decoded orelse Verdict =:= malformed) ->
    case {maps:get(ReqId, S0#s.pulls, undefined),
          maps:get(Ref, S0#s.page_bindings, undefined)} of
        {#pull{from = none, caller = Caller, binding = Ref, deadline = Deadline,
               turn = {decoding, Link, Ref, Grant, NextGrant}},
         #page_binding{ref = Ref, link = Link, active = ReqId,
                       credit = none, retiring = false}} ->
            case Verdict =:= decoded andalso Deadline > quod_time:mono_ms() of
                true -> {ok, finish_page_turn(ReqId, Ref, ok, NextGrant, S0)};
                false ->
                    Cause = case Verdict of
                        malformed -> malformed_page;
                        decoded -> page_expired
                    end,
                    {{error, retry}, cancel_pull(ReqId, Cause, S0)}
            end;
        _ -> {{error, retry}, S0}
    end;
complete_page_decode(_Key, _Verdict, _Caller, S) ->
    {{error, retry}, S}.

finish_page_turn(ReqId, Ref, Reply, NextGrant, S0) ->
    Cause = case Reply of ok -> completed; {error, _} -> wire_error end,
    S1 = complete_pull(ReqId, Reply, Cause, S0),
    B1 = maps:get(Ref, S1#s.page_bindings),
    drive_page_binding(Ref, put_page_binding(B1#page_binding{credit = NextGrant}, S1)).

traced_page_owner(TraceCtx, Stage, Fun) ->
    traced_page_owner(TraceCtx, Stage, #{}, Fun).

traced_page_owner(undefined, _Stage, _Attributes, Fun) -> Fun();
traced_page_owner(TraceCtx, Stage, Attributes, Fun) ->
    quod_trace:with_span(TraceCtx, <<"quod.foreign.", (atom_to_binary(Stage))/binary>>,
                         internal, Attributes, fun(_) -> Fun() end).

complete_pull(ReqId, Reply, Cause, S0) ->
    case maps:take(ReqId, S0#s.pulls) of
        {#pull{from = From, timer = Timer, mref = MRef, binding = Ref,
               trace_ctx = TraceCtx, turn = Turn, deadline = Deadline}, Pulls} ->
            %% The raw reply may already have consumed From. Mark the one
            %% retained page's actual terminal cause before any reply/removal,
            %% including link loss while its worker is decoding. The owner
            %% creates its own child: it must not mutate the worker's page
            %% span, which may already have ended after caller-side expiry.
            TurnName = case Turn of queued -> queued; _ -> element(1, Turn) end,
            traced_page_owner(TraceCtx, page_completion_owner,
              #{'quod.foreign.page_terminal_count' => 1,
                'quod.foreign.page_id' => binary:encode_hex(ReqId, lowercase),
                'quod.foreign.page_terminal' => atom_to_binary(Cause),
                'quod.foreign.page_turn' => atom_to_binary(TurnName),
                'quod.foreign.page_deadline_expired' => Deadline =< quod_time:mono_ms()},
              fun() ->
                  _ = erlang:cancel_timer(Timer),
                  _ = erlang:demonitor(MRef, [flush]),
                  reply_page_caller(From, Reply),
                  B = maps:get(Ref, S0#s.page_bindings),
                  B1 = case B#page_binding.active of
                           ReqId -> B#page_binding{active = none};
                           _ -> B#page_binding{waiting = queue:filter(fun(Id) -> Id =/= ReqId end, B#page_binding.waiting)}
                       end,
                  put_page_binding(B1, S0#s{pulls = Pulls})
              end);
        error -> S0
    end.

reply_page_caller(none, _Reply) -> ok;
reply_page_caller(From, Reply) -> gen_server:reply(From, Reply).

cancel_pull(ReqId, Cause, S0) ->
    case maps:get(ReqId, S0#s.pulls, undefined) of
        #pull{binding = Ref} -> drive_page_binding(Ref, cancel_pull_owned(ReqId, Cause, S0));
        undefined -> S0
    end.

cancel_pull_owned(ReqId, Cause, S0) ->
    case maps:get(ReqId, S0#s.pulls, undefined) of
        #pull{turn = queued} ->
            complete_pull(ReqId, {error, retry}, Cause, S0);
        #pull{binding = Ref, turn = Turn} ->
            Link = spent_page_link(Turn),
            S1 = complete_pull(ReqId, {error, retry}, Cause, S0),
            B = maps:get(Ref, S1#s.page_bindings),
            quod_link:close(Link),
            %% Do not bind unsent rows to a still-retiring cached stream.
            put_page_binding(B#page_binding{credit = none, retiring = true}, S1);
        undefined -> S0
    end.

spent_page_link({sent, Link, _Ref, _Grant}) -> Link;
spent_page_link({decoding, Link, _Ref, _Grant, _NextGrant}) -> Link.

retire_page_binding(Ref, S0) ->
    case maps:get(Ref, S0#s.page_bindings, undefined) of
        #page_binding{active = Active, lease = Lease} = B0 ->
            S1 = case Active of
                     none -> S0;
                     _ -> complete_pull(Active, {error, link_down}, link_down, S0)
                 end,
            B = maps:get(Ref, S1#s.page_bindings),
            release_page_binding(Ref, B0),
            put_page_binding(B#page_binding{lease = none, link = none, mref = none,
                                            credit = none, retiring = false},
              S1#s{page_openings = maps:remove(Lease, S1#s.page_openings)});
        undefined -> S0
    end.

release_page_binding(_Ref, #page_binding{key = {Peer, Endpoint, Ns}, lease = Lease, mref = MRef}) ->
    case MRef of none -> ok; _ -> erlang:demonitor(MRef, [flush]) end,
    case Lease of
        none -> ok;
        _ -> quod_quic:release_link_pinned(Peer, Endpoint, quod_catchup:channel(Ns), Lease)
    end.

reopen_identity_bindings(Identity, S0) ->
    maps:fold(fun(Ref, #page_binding{identities = Identities}, S) ->
                  case maps:is_key(Identity, Identities) of
                      true -> reopen_waiting_binding(Ref, S);
                      false -> S
                  end
              end, S0, S0#s.page_bindings).

release_idle_page_bindings(S0) ->
    maps:fold(fun(Ref, #page_binding{identities = Identities} = B, S) ->
                  Live = maps:filter(fun(Identity, _) -> page_identity_interested(Identity, S) end, Identities),
                  case map_size(Live) =:= 0 andalso B#page_binding.active =:= none
                       andalso queue:is_empty(B#page_binding.waiting) of
                      true ->
                          release_page_binding(Ref, B),
                          S#s{page_bindings = maps:remove(Ref, S#s.page_bindings),
                              page_contacts = maps:remove(B#page_binding.key, S#s.page_contacts),
                              page_openings = maps:remove(B#page_binding.lease, S#s.page_openings)};
                      false -> put_page_binding(B#page_binding{identities = Live}, S)
                  end
              end, S0, S0#s.page_bindings).

page_identity_interested(Identity, S) ->
    case maps:get(Identity, S#s.histories, undefined) of
        #history{consumers = Consumers, active = Active, waiting = Waiting} ->
            map_size(Consumers) > 0 orelse Active =/= none orelse not queue:is_empty(Waiting);
        undefined -> false
    end.

%%%===================================================================
%%% Verification worker
%%%===================================================================

verification_worker(
  Owner, RequestRef, Work, Root, FetchFun, PageTimeout, Resident, Trace) ->
    %% Probe children are linked so terminating their verification worker also
    %% terminates every in-flight route fetch. Expected transport exits are
    %% normalized where the dependency is called; an internal fault takes
    %% down this monitored worker and remains visible to the runtime.
    StartedNative = erlang:monotonic_time(),
    traced_verification_work(
      Trace, Work, Owner, RequestRef,
      fun(SpanCtx) ->
          trace_foreign_stage(cache_prepare,
            fun() -> prepare_cache_custody(Root, verification_identity(Work), Resident) end),
          Result0 = verification_work(
                      Work, Owner, RequestRef, Root, FetchFun, PageTimeout,
                      Resident),
          {Result, Meta0} = normalize_worker_result(Result0),
          Meta = close_worker_cache(Meta0),
          observe_foreign_stage(
            verification_stage(Work), foreign_result(Result), StartedNative),
          trace_foreign_stage(worker_handoff,
            fun() ->
                Owner ! {foreign_worker_done, RequestRef, Result, Meta},
                ok
            end),
          _ = quod_trace:set_attributes(
                SpanCtx, worker_trace_attributes(Resident, Meta)),
          trace_foreign_result(SpanCtx, Result),
          ok
      end).

verification_stage({local_exact, _, _, _}) -> request_exact;
verification_stage({exact, _, _, _, _}) -> request_exact;
verification_stage({exact_routes, _, _, _, _}) -> request_exact;
verification_stage({current_identity, _, _, _}) -> request_current;
verification_stage({follow, _, _, _}) -> request_follow.

traced_verification_work(none, _Work, _Owner, _RequestRef, Fun) ->
    Fun(undefined);
traced_verification_work({TraceCtx, Links, JobAttributes}, Work,
                         Owner, RequestRef, Fun) ->
    quod_trace:with_span(
      TraceCtx, <<"quod.foreign.verification_worker">>, internal,
      maps:merge(JobAttributes, verification_trace_attributes(Work)), Links,
      fun(SpanCtx) ->
          Owner ! {verification_trace, RequestRef, self(), SpanCtx},
          Previous = put(?TRACE_STAGE_ACTIVE, otel_span:is_recording(SpanCtx)),
          PreviousCounts = put({?MODULE, trace_counts}, #{}),
          try
              Fun(SpanCtx)
          catch Class:Reason:Stack ->
              trace_foreign_exception(SpanCtx, Class),
              erlang:raise(Class, Reason, Stack)
          after
              _ = quod_trace:set_attributes(SpanCtx, trace_count_attributes()),
              restore_trace_counts(PreviousCounts),
              restore_trace_stage(Previous)
          end
      end).

restore_trace_stage(undefined) -> erase(?TRACE_STAGE_ACTIVE);
restore_trace_stage(Previous) -> put(?TRACE_STAGE_ACTIVE, Previous).

restore_trace_counts(undefined) -> erase({?MODULE, trace_counts});
restore_trace_counts(Previous) -> put({?MODULE, trace_counts}, Previous).

verification_trace_attributes(Work) ->
    {Ns, Anchor} = verification_identity(Work),
    Attributes = #{'quod.namespace' => Ns,
                   'quod.genesis_anchor' => binary:encode_hex(Anchor, lowercase),
                   'quod.foreign.work' => atom_to_binary(verification_stage(Work)),
                   'quod.foreign.worker_pid' => list_to_binary(pid_to_list(self()))},
    case verification_reference(Work) of
        {Ref, Phase} ->
            Attributes#{'quod.foreign.requested_slot' => ref_slot(Ref),
                        'quod.foreign.expected_phase' => atom_to_binary(Phase)};
        none -> Attributes
    end.

verification_identity({local_exact, #{identity := Identity}, _, _}) -> Identity;
verification_identity({exact, _, _, Ref, _}) -> ref_identity(Ref);
verification_identity({exact_routes, _, Ref, _, _}) -> ref_identity(Ref);
verification_identity({current_identity, _, Identity, _ProbeTimeout}) -> Identity;
verification_identity({follow, Identity, _, _Deadline}) -> Identity.

verification_reference({local_exact, _, Ref, Phase}) -> {Ref, Phase};
verification_reference({exact, _, _, Ref, Phase}) -> {Ref, Phase};
verification_reference({exact_routes, _, Ref, Phase, _}) -> {Ref, Phase};
verification_reference(_) -> none.

worker_trace_attributes(Resident, Meta) ->
    OldHeight = resident_height(Resident),
    NewHeight = maps:get(height, Meta, OldHeight),
    CommitteeSize = trace_committee_size(
                      maps:get(projection, Meta, undefined)),
    CommitteeEras = trace_committee_eras(
                      maps:get(projection, Meta, undefined)),
    PhaseRows = maps:get(phase_index_rows, Meta, 0),
    PhaseBytes = maps:get(phase_index_bytes, Meta, 0),
    #{'quod.foreign.resident_start_height' => OldHeight,
      'quod.foreign.final_verified_height' => NewHeight,
      'quod.foreign.committee_size' => CommitteeSize,
      'quod.foreign.committee_eras' => CommitteeEras,
      'quod.foreign.phase_index_rows' => PhaseRows,
      'quod.foreign.phase_index_bytes' => PhaseBytes}.

resident_height({verified_session, Height, _Projection,
                 _PhaseSession, _CacheSession}) -> Height;
resident_height(_) -> 0.

trace_committee_size(Projection) when is_map(Projection) ->
    try length(quod_simplex:history_committee(Projection))
    catch _:_ -> 0
    end;
trace_committee_size(_) -> 0.

trace_committee_eras(#{committee_views := Views}) when is_list(Views) ->
    length(Views);
trace_committee_eras(_) -> 0.

foreign_result({ok, _}) -> ok;
foreign_result({error, retry}) -> uncertain;
foreign_result({error, {unreachable, _}}) -> uncertain;
foreign_result({error, _}) -> failed.

observe_foreign_stage(Stage, Result, StartedNative)
  when is_integer(StartedNative) ->
    quod_metrics:observe_foreign_history_stage(
      Stage, Result, erlang:monotonic_time() - StartedNative).

measure_foreign_stage(Stage, Fun) ->
    StartedNative = erlang:monotonic_time(),
    Result = trace_foreign_stage(Stage, Fun),
    observe_foreign_stage(
      Stage, foreign_stage_result(foreign_stage_observation(Stage, Result)), StartedNative),
    Result.

measure_foreign_ok(Stage, Fun) ->
    StartedNative = erlang:monotonic_time(),
    Result = trace_foreign_stage(Stage, Fun),
    observe_foreign_stage(Stage, ok, StartedNative),
    Result.

trace_foreign_stage(Stage, Fun) ->
    trace_foreign_stage(Stage, #{}, Fun).

trace_foreign_stage(Stage, Attributes, Fun) ->
    case get(?TRACE_STAGE_ACTIVE) of
        true ->
            Ordinal = trace_count(stage_started, 1),
            Name = <<"quod.foreign.", (atom_to_binary(Stage, utf8))/binary>>,
            quod_trace:with_span(
              quod_trace:context(), Name, internal,
              Attributes#{'quod.foreign.stage_ordinal' => Ordinal,
                          'quod.foreign.stage_process' => list_to_binary(pid_to_list(self()))},
              fun(SpanCtx) ->
                  try
                      Result = Fun(),
                      trace_foreign_result(SpanCtx, foreign_stage_observation(Stage, Result)),
                      Result
                  catch Class:Reason:Stack ->
                      %% Closed labels only; preserve the exact production
                      %% exception class, reason and stack without exporting it.
                      trace_foreign_exception(SpanCtx, Class),
                      erlang:raise(Class, Reason, Stack)
                  after
                      trace_count(stage_completed, 1)
                  end
              end);
        _ -> Fun()
    end.

trace_foreign_exception(SpanCtx, Class) ->
    _ = quod_trace:set_attributes(
          SpanCtx, #{'quod.foreign.exception_class' => atom_to_binary(Class)}),
    trace_foreign_result(SpanCtx, {error, unclassified_exception}).

trace_foreign_result(undefined, _Result) -> ok;
trace_foreign_result(SpanCtx, Result) ->
    Reason = foreign_trace_reason(Result),
    Status = case foreign_stage_result(Result) of
                 failed -> {error, Reason};
                 uncertain -> {error, Reason};
                 ok -> ok
             end,
    _ = quod_trace:result(SpanCtx, Status),
    _ = quod_trace:set_attributes(
          SpanCtx, #{'quod.foreign.reason' => atom_to_binary(Reason)}),
    ok.

foreign_trace_reason({{error, Reason}, _Meta}) -> foreign_trace_reason({error, Reason});
foreign_trace_reason({error, Reason, #verified_cursor{}}) -> foreign_trace_reason({error, Reason});
foreign_trace_reason({error, {unavailable, network_identity, _}}) -> network_identity_unavailable;
foreign_trace_reason({error, {unreachable, _}}) -> unreachable;
foreign_trace_reason({error, Reason})
  when Reason =:= retry; Reason =:= timeout; Reason =:= cache_corrupt;
       Reason =:= cache_io; Reason =:= cache_unavailable;
       Reason =:= phase_mismatch; Reason =:= invalid_foreign_reference;
       Reason =:= bad_foreign_reference; Reason =:= invalid_history;
       Reason =:= invalid_page; Reason =:= unavailable;
       Reason =:= bad_frame; Reason =:= link_down;
       Reason =:= unclassified_exception -> Reason;
foreign_trace_reason({error, _}) -> unclassified;
foreign_trace_reason(false) -> rejected;
foreign_trace_reason(new) -> new_cache;
foreign_trace_reason({not_found, _}) -> not_found;
foreign_trace_reason({_, error}) -> projection_unavailable;
foreign_trace_reason(Result) ->
    case foreign_stage_result(Result) of ok -> ok; _ -> unclassified end.

%% Worker-local observation only. Counts never enter work equality, authority
%% or checkpoints. Probe children have their own sequence and report it on
%% their own parent span; they are not silently added to this worker's totals.
trace_count(Key, Increment) ->
    case get(?TRACE_STAGE_ACTIVE) of
        true ->
            Counts = case get({?MODULE, trace_counts}) of
                         undefined -> #{};
                         Existing -> Existing
                     end,
            Value = maps:get(Key, Counts, 0) + Increment,
            put({?MODULE, trace_counts}, Counts#{Key => Value}),
            Value;
        _ -> 0
    end.

trace_first_height(Height) ->
    case get(?TRACE_STAGE_ACTIVE) of
        true ->
            Counts = get({?MODULE, trace_counts}),
            case maps:is_key(disk_start_height, Counts) of
                true -> ok;
                false -> put({?MODULE, trace_counts}, Counts#{disk_start_height => Height})
            end;
        _ -> ok
    end.

trace_count_attributes() ->
    Counts = case get({?MODULE, trace_counts}) of
                 undefined -> #{};
                 Existing -> Existing
             end,
    #{'quod.foreign.stages_started' => maps:get(stage_started, Counts, 0),
      'quod.foreign.stages_completed' => maps:get(stage_completed, Counts, 0),
      'quod.foreign.disk_start_height' => maps:get(disk_start_height, Counts, -1),
      'quod.foreign.disk_replayed_entries' => maps:get(replayed_entries, Counts, 0),
      'quod.foreign.cold_opens' => maps:get(cold_opens, Counts, 0),
      'quod.foreign.resume_failures' => maps:get(resume_failures, Counts, 0),
      'quod.foreign.network_advance_verified_entries' => maps:get(network_entries, Counts, 0),
      'quod.foreign.local_advance_verified_entries' => maps:get(local_entries, Counts, 0),
      'quod.foreign.hint_verified_entries' => maps:get(hint_entries, Counts, 0),
      'quod.foreign.probe_children_started' => maps:get(probes_started, Counts, 0),
      'quod.foreign.probe_results_received' => maps:get(probe_results, Counts, 0),
      'quod.foreign.probe_children_cancelled' => maps:get(probes_cancelled, Counts, 0)}.

trace_verified_page({local, _Identity}, Count) -> trace_count(local_entries, Count);
trace_verified_page(_Peer, Count) -> trace_count(network_entries, Count).

foreign_stage_result(true) -> ok;
foreign_stage_result(ok) -> ok;
foreign_stage_result({ok, _}) -> ok;
foreign_stage_result({ok, _, _}) -> ok;
foreign_stage_result({ok, _, _, _}) -> ok;
foreign_stage_result({ok, _, _, _, _}) -> ok;
foreign_stage_result({ok, _, _, _, _, _}) -> ok;
foreign_stage_result({{ok, _}, _Meta}) -> ok;
foreign_stage_result({{error, _} = Error, _Meta}) -> foreign_stage_result(Error);
foreign_stage_result({error, Reason, #verified_cursor{}}) -> foreign_stage_result({error, Reason});
foreign_stage_result(new) -> ok;
foreign_stage_result(false) -> failed;
foreign_stage_result({error, retry}) -> uncertain;
foreign_stage_result({error, {unreachable, _}}) -> uncertain;
foreign_stage_result({error, _}) -> failed;
foreign_stage_result(_) -> failed.

%% Normalize only observation, never the helper's return value. These shapes
%% mean completion at their named stage, not successful verification: an all-
%% probe collection can contain refusals, and a suspended session stays opaque
%% to this layer. Other stages and unknown shapes keep the failing catch-all.
foreign_stage_observation(page_wait, {decode_page, {_, _, _, _, _}, Blobs, Height, Deadline, _})
  when is_list(Blobs), is_integer(Height), Height >= 0, is_integer(Deadline) -> ok;
foreign_stage_observation(probe_collection, Results) when is_list(Results) -> ok;
foreign_stage_observation(ledger_suspend, #{cache_session := _} = Meta)
  when not is_map_key(cache_store, Meta) -> ok;
foreign_stage_observation(_Stage, Result) -> Result.

verification_work(Work, Owner, RequestRef, Root, FetchFun, PageTimeout, Resident) ->
    Identity = verification_identity(Work),
    TargetSlot = case verification_reference(Work) of
                     {Ref, _Phase} -> ref_slot(Ref);
                     none -> none
                 end,
    %% All work, including a follow that loses its source before borrowing,
    %% returns through this one cursor scope after custody transfer. No early
    %% selection failure can strand a still-suspended resident session.
    with_verified_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident,
      fun(Cursor) ->
          verification_cursor_work(Work, Owner, RequestRef, Root, FetchFun, PageTimeout, Cursor)
      end).

verification_cursor_work(
  {local_exact, #{identity := Identity}, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, Cursor) ->
    verify_cached(Owner, RequestRef, {local, Identity}, local, Ref, Phase,
                  Identity, Root, FetchFun, PageTimeout, Cursor, none);
verification_cursor_work(
  {exact, Peer, Endpoint, Ref, Phase}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, Cursor) ->
    verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase, ref_identity(Ref),
                  Root, FetchFun, PageTimeout, Cursor, none);
verification_cursor_work(
  {exact_routes, Routes, Ref, Phase, EntryHint}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, Cursor) ->
    verify_exact_routes(Routes, Owner, RequestRef, Ref, Phase, ref_identity(Ref),
                        Root, FetchFun, PageTimeout, none, Cursor, EntryHint);
verification_cursor_work(
  {current_identity, Sources, Identity, ProbeTimeout}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, Cursor) ->
    certified_current_snapshot(Owner, RequestRef, Sources, Identity, Root,
                               FetchFun, PageTimeout, ProbeTimeout, Cursor, to_tip);
verification_cursor_work(
  {follow, Identity, Sources, Deadline}, Owner, RequestRef,
  Root, FetchFun, PageTimeout, Cursor) ->
    follow_identity(Owner, RequestRef, Identity, Sources, Root, FetchFun,
                    PageTimeout, Deadline, Cursor).

%% Both availability and definitive request failures retain the same sound
%% prefix. A local persistence failure is different: the cursor cannot be
%% borrowed by the next route, even when its old height still looks plausible.
verify_exact_routes([], _Owner, _RequestRef, _Ref, _Phase, _Identity,
                    _Root, _FetchFun, _PageTimeout, Prior, Cursor, _EntryHint) ->
    Reason = case Prior of none -> retry; definitive -> invalid_foreign_reference end,
    {{error, Reason}, Cursor};
verify_exact_routes([{Peer, Endpoint} | Rest], Owner, RequestRef, Ref, Phase, Identity,
                    Root, FetchFun, PageTimeout, Prior, Cursor, EntryHint) ->
    case trace_foreign_stage(exact_route,
           fun() -> verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                                  Identity, Root, FetchFun, PageTimeout, Cursor, EntryHint)
           end) of
        {Result, #verified_cursor{state = invalid} = Invalid} ->
            {Result, Invalid};
        {{ok, _} = Result, Next} ->
            {Result, Next};
        {{error, Reason}, Next}
          when Reason =:= phase_mismatch; Reason =:= invalid_foreign_reference ->
            verify_exact_routes(Rest, Owner, RequestRef, Ref, Phase, Identity,
                                Root, FetchFun, PageTimeout, definitive, Next, EntryHint);
        {{error, _}, Next} ->
            verify_exact_routes(Rest, Owner, RequestRef, Ref, Phase, Identity,
                                Root, FetchFun, PageTimeout, Prior, Next, EntryHint)
    end.

%% The one worker opens/resumes once, and every route receives its cursor.
%% Existing corrupt-cache recovery is an admission boundary, never a fallback
%% from a partially mutated cursor into a next-peer attempt.
with_verified_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident, Work) ->
    case open_verified_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident, false) of
        {ok, Store, Height, Projection, PhaseIndex, TargetProjection} ->
            Cursor = #verified_cursor{store = Store, height = Height,
                                      projection = Projection, phase_index = PhaseIndex,
                                      target_projection = TargetProjection},
            try Work(Cursor) of
                {Result, #verified_cursor{} = Final} ->
                    {Result, #{cache_cursor => Final,
                               bytes => cache_persisted_bytes(
                                          Root, cache_namespace(Identity))}}
            catch Class:Reason:Stack ->
                %% Closing the original handle also closes its shared file
                %% descriptor after a later append; no mutable cursor escapes.
                _ = close_cache(Store, PhaseIndex, cache_corrupt),
                erlang:raise(Class, Reason, Stack)
            end;
        {error, _} ->
            {{error, retry}, #{}}
    end.

open_verified_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident, Retried) ->
    case open_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident) of
        {error, cache_corrupt} when not Retried ->
            case gen_server:call(Owner, {reset_cache, RequestRef}) of
                ok ->
                    _ = file:del_dir_r(cache_dir(Root, cache_namespace(Identity))),
                    open_verified_cache(Owner, RequestRef, Identity, Root,
                                        TargetSlot, none, true);
                {error, _} -> {error, cache_corrupt}
            end;
        Result -> Result
    end.

normalize_worker_result({{ok, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta};
normalize_worker_result({{error, _} = Result, Meta}) when is_map(Meta) ->
    {Result, Meta}.

%% Neither a mutable ledger nor an active phase index crosses the worker
%% boundary. Suspend once, regardless of whether the caller's claim was valid.
close_worker_cache(#{cache_cursor := #verified_cursor{
                       state = verified, store = Store, height = Height,
                       projection = Projection, phase_index = PhaseIndex}} = Meta0)
  when Height > 0 ->
    Meta = maps:remove(cache_cursor, Meta0),
    PhaseStats = phase_session_stats(PhaseIndex),
    PhaseSession = suspend_phase_session(PhaseIndex),
    measure_foreign_ok(ledger_suspend,
      fun() ->
          Session = quod_ledger_store:snapshot(Store),
          _ = quod_ledger_store:close(Store),
          maps:merge(Meta#{height => Height, projection => Projection,
                          phase_session => PhaseSession, cache_session => Session,
                          resident_verified => PhaseSession =/= none}, PhaseStats)
      end);
close_worker_cache(#{cache_cursor := #verified_cursor{
                       state = State, store = Store, phase_index = PhaseIndex}} = Meta) ->
    %% An empty cache has no certified prefix at all. Retaining its initial
    %% projection would let a failed fabricated identity become resident.
    Disposition = case State of verified -> ok; invalid -> {error, cache_corrupt} end,
    _ = release_cache(Store, PhaseIndex, Disposition),
    (maps:remove(cache_cursor, Meta))#{resident_verified => false,
                                      phase_session => none, cache_session => none};
close_worker_cache(Meta) ->
    Meta.

follow_identity(Owner, RequestRef, Identity, Sources, Root,
                FetchFun, PageTimeout, Deadline, Cursor) ->
    case quod_simplex:history_view(Identity, any, Deadline) of
        {ok, #{identity := Identity, slot := Tip} = SourceView} ->
            Remaining = max(0, Deadline - quod_time:mono_ms()),
            Borrow = try gen_server:call(
                           Owner, {borrow_local_view, RequestRef, SourceView}, Remaining)
                     catch exit:_ -> {error, retry}
                     end,
            case Borrow of
                ok -> follow_borrowed_local_view(
                        Owner, RequestRef, Identity, Tip, SourceView, Root,
                        PageTimeout, Deadline, Cursor);
                {error, _} -> {{error, {unreachable, unavailable}}, Cursor}
            end;
        {error, _} ->
            Remaining = Deadline - quod_time:mono_ms(),
            case {Remaining > 0, route_candidates(Sources)} of
                {true, [_ | _]} ->
                    certified_current_snapshot(
                      Owner, RequestRef, Sources, Identity, Root, FetchFun,
                      PageTimeout, Remaining, Cursor, one_page);
                _ ->
                    {{error, {unreachable, unavailable}}, Cursor}
            end
    end.

follow_borrowed_local_view(Owner, RequestRef, Identity, Tip, SourceView, Root,
                           PageTimeout, Deadline, Cursor) ->
    LocalFetch =
        fun(_Peer, _Endpoint, RequestedNs, FromIndex, ToIndex) ->
            case quod_time:mono_ms() < Deadline of
                true -> local_view_fetch(SourceView, RequestedNs, FromIndex, ToIndex);
                false -> {error, retry}
            end
        end,
    {Result, Next} = follow_local_snapshot(
                       Owner, RequestRef, {local, Identity}, Tip, Identity,
                       Root, LocalFetch, PageTimeout, Cursor),
    case quod_simplex:history_view_live(SourceView) andalso
         quod_time:mono_ms() < Deadline of
        true -> {Result, Next};
        false -> {{error, {unreachable, unavailable}}, Next}
    end.

follow_local_snapshot(Owner, RequestRef, LocalPeer, Tip, Identity,
                      Root, FetchFun, PageTimeout, Cursor = #verified_cursor{height = Height}) ->
    Target = min(Tip, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
    case advance_snapshot_to_height(
           [{LocalPeer, local}], Owner, RequestRef, Identity, Cursor,
           Root, Target, FetchFun, PageTimeout) of
        {ok, Final = #verified_cursor{height = FinalHeight, projection = Projection}} ->
            View = case FinalHeight >= Tip of true -> confirmed; false -> unconfirmed end,
            Evidence = (current_view_evidence(
                          Identity, FinalHeight, Projection,
                          current_route_candidates(empty_route_sources(), Projection)))#{
                         hinted_height => Tip, current_view => View},
            {{ok, Evidence}, Final};
        {error, _Reason, Final} -> {{error, retry}, Final}
    end.

verify_cached(Owner, RequestRef, Peer, Endpoint, Ref, Phase, Identity,
              Root, FetchFun, PageTimeout, Cursor, EntryHint) ->
    case fetch_exact_reference(Owner, RequestRef, Peer, Endpoint, Ref, Phase,
                               Identity, Cursor, Root, FetchFun, PageTimeout, EntryHint) of
        {ok, Next = #verified_cursor{store = Store}, {projection, EvidenceProjection}} ->
            {verify_exact_reference(Store, Ref, Phase, EvidenceProjection), Next};
        {ok, Next, {evidence, Evidence}} ->
            {{ok, Evidence}, Next};
        {error, _Reason, Next} ->
            {{error, retry}, Next}
    end.

certified_current_snapshot(
  Owner, RequestRef, Sources, Identity,
  Root, FetchFun, PageTimeout, RequestTimeout,
  Cursor = #verified_cursor{projection = Projection}, AdvanceMode) ->
    Hints = current_route_candidates(Sources, Projection),
    case advance_current_snapshot(
           Owner, RequestRef, Hints, Identity, Cursor, Root,
           FetchFun, PageTimeout, RequestTimeout, AdvanceMode) of
        {ok, Next} ->
            confirm_current_snapshot(Owner, RequestRef, Sources, Identity,
              Next, Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode, true);
        {error, _Reason, Next} -> {{error, retry}, Next}
    end.

confirm_current_snapshot(
  Owner, RequestRef, Sources, Identity = {Ns, Anchor},
  Cursor = #verified_cursor{height = Height, projection = Projection, phase_index = PhaseIndex},
  Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode, AllowFallback) ->
    ConfirmHints = current_route_candidates(Sources, Projection),
    Confirmed = measure_foreign_stage(tip_confirm,
      fun() -> current_view_confirmed(Owner, RequestRef, ConfirmHints, Ns, Anchor,
                 Identity, Height, Projection, PhaseIndex, FetchFun, PageTimeout) end),
    case {Confirmed, AllowFallback} of
        {true, _} ->
            {{ok, current_view_evidence(Identity, Height, Projection, ConfirmHints)}, Cursor};
        {false, true} ->
            recover_current_snapshot_from_history_source(
              Owner, RequestRef, Sources, ConfirmHints, Identity, Cursor, Root,
              FetchFun, PageTimeout, RequestTimeout, AdvanceMode);
        {false, false} ->
            {{error, retry}, Cursor}
    end.

recover_current_snapshot_from_history_source(
  Owner, RequestRef, Sources, ConfirmHints, Identity, Cursor = #verified_cursor{height = Height},
  Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode) ->
    Fallback = history_fallback_sources(Sources, ConfirmHints),
    RouteTimeout = bootstrap_route_timeout(PageTimeout, RequestTimeout, length(Fallback)),
    case sequential_snapshot_sources(Fallback, Owner, RequestRef, Identity, Cursor,
                                     Root, FetchFun, RouteTimeout, PageTimeout, AdvanceMode) of
        {ok, Next = #verified_cursor{height = NextHeight}} when NextHeight > Height ->
            confirm_current_snapshot(Owner, RequestRef, Sources, Identity, Next,
              Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode, false);
        {ok, Next} -> {{error, retry}, Next};
        {error, _Reason, Next} -> {{error, retry}, Next}
    end.

open_cache(Owner, RequestRef, Identity, Root, TargetSlot, Resident) ->
    StartedNative = erlang:monotonic_time(),
    Mode = case Resident of
               {verified_session, _, _, _, _} -> <<"resident_resume">>;
               none -> <<"cold_reconstruction">>
           end,
    Result = trace_foreign_stage(cache_open,
               #{'quod.foreign.cache_open_mode' => Mode},
               fun() ->
                   open_cache_raw(
                     Owner, RequestRef, Identity, Root, TargetSlot, Resident)
               end),
    observe_foreign_stage(cache_open, cache_result(Result), StartedNative),
    Result.

%% The running owner retains the ledger session, projection and phase index
%% together. Exact lookups still bind slot/hash/digest to the retained entry
%% and select its committee era; resuming the certified prefix adds no new
%% authority and does not replay unfinished DTX groups.
open_cache_raw(Owner, RequestRef, Identity, Root, TargetSlot,
               {verified_session, Height, Projection,
                PhaseSession, CacheSession}) ->
    CacheNs = cache_namespace(Identity),
    case measure_foreign_stage(
           ledger_resume,
           fun() -> quod_ledger_store:resume(CacheSession) end) of
        {ok, Store} ->
            trace_first_height(quod_ledger_store:last(Store)),
            Matches = measure_foreign_stage(
                        projection_validate,
                        fun() ->
                            retained_cache_matches(
                              Store, CacheNs, Height, Projection, Identity)
                        end),
            case Matches of
                true ->
                    case measure_foreign_stage(
                           phase_resume,
                           fun() ->
                               quod_dtx_phase_index:resume(PhaseSession)
                           end) of
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
            trace_count(resume_failures, 1),
            close_phase_session(PhaseSession),
            open_cache_raw(
              Owner, RequestRef, Identity, Root, TargetSlot, none)
    end;
open_cache_raw(Owner, RequestRef, Identity = {Ns, Anchor}, Root, TargetSlot, none) ->
    CacheNs = cache_namespace(Identity),
    case ensure_manifest(Owner, RequestRef, Root, Identity, CacheNs) of
        ok ->
            trace_count(cold_opens, 1),
            try measure_foreign_stage(
                  ledger_open,
                  fun() -> quod_ledger_store:open(CacheNs, Root, wrapped) end) of
                {ok, Store} ->
                    Height = quod_ledger_store:last(Store),
                    trace_first_height(Height),
                    Checkpoint = measure_foreign_stage(
                                   checkpoint_read,
                                   fun() ->
                                       load_checkpoint(
                                         Root, Identity, CacheNs, Height)
                                   end),
                    case Checkpoint of
                        {ok, CheckpointProjection} ->
                            open_replayed_cache(
                              Root, CacheNs, Ns, Anchor, Store,
                              Height, CheckpointProjection,
                              TargetSlot);
                        new when Height =:= 0 ->
                            case measure_foreign_stage(
                                   phase_open,
                                   fun() -> fresh_phase_index(Root, CacheNs) end) of
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

open_replayed_cache(Root, CacheNs, Ns, Anchor, Store, Height,
                    CheckpointProjection, TargetSlot) ->
    trace_foreign_stage(cache_reconstruction,
      #{'quod.foreign.disk_height' => Height},
      fun() ->
          open_replayed_cache_raw(Root, CacheNs, Ns, Anchor, Store, Height,
                                  CheckpointProjection, TargetSlot)
      end).

open_replayed_cache_raw(Root, CacheNs, Ns, Anchor, Store, Height,
                        CheckpointProjection, TargetSlot) ->
    case measure_foreign_stage(
           phase_open,
           fun() -> fresh_phase_index(Root, CacheNs) end) of
        {ok, PhaseIndex} ->
            Projection0 = quod_simplex:history_projection({Ns, Anchor}),
            ReplayResult = measure_foreign_stage(cache_replay,
                             fun() ->
                                 replay_cache(
                                   Store, Ns, Anchor, Height,
                                   Projection0, PhaseIndex, TargetSlot)
                             end),
            case ReplayResult of
                {ok, Projection, TargetProjection} ->
                    case trace_foreign_stage(checkpoint_compare,
                           fun() ->
                               checkpoint_projection(Projection) =:= CheckpointProjection
                           end) of
                        true ->
                            {ok, Store, Height, Projection,
                             PhaseIndex, TargetProjection};
                        false ->
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
    quod_dtx_phase_index:open(Root, CacheNs).

close_cache(Store, PhaseIndex, Reason) ->
    release_cache(Store, PhaseIndex, {error, Reason}).

release_cache(Store, PhaseIndex, Result) ->
    trace_foreign_stage(cache_cleanup,
      fun() ->
          _ = quod_dtx_phase_index:close(PhaseIndex),
          _ = quod_ledger_store:close(Store),
          Result
      end).

replay_cache(_Store, _Ns, _Anchor, 0, Projection, _PhaseIndex,
             _TargetSlot) ->
    {ok, Projection, undefined};
replay_cache(Store, Ns, Anchor, Height, Projection0, PhaseIndex,
             TargetSlot) ->
    replay_cache(Store, Ns, Anchor, 1, Height, Projection0,
                 PhaseIndex, TargetSlot, undefined).

replay_cache(_Store, Ns, Anchor, From, Height, Projection,
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
replay_cache(Store, Ns, Anchor, From, Height, Projection0, PhaseIndex,
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
    %% both entry count and encoded bytes. Reuse the cold recovery owner\'s
    %% already-open handle with the same bounded reader: no page rescans the
    %% index, and large valid entries still advance by the actual safe prefix.
    try quod_catchup:read_blocks(Store, From, To) of
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
                                    trace_count(replayed_entries, Count),
                                    TargetProjection1 =
                                        case is_integer(TargetSlot) andalso
                                                  PageTo =:= TargetSlot of
                                            true -> Projection1;
                                            false -> TargetProjection0
                                        end,
                                    replay_cache(
                                      Store, Ns, Anchor, PageTo + 1,
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
  Cursor = #verified_cursor{height = Height}, Root, FetchFun, PageTimeout, EntryHint) ->
    Slot = ref_slot(Ref),
    case entry_index(EntryHint) of
        Slot when Height < Slot ->
            case fetch_hint_parent(Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                                   Cursor, Root, FetchFun, PageTimeout) of
                {ok, Parent} ->
                    case import_exact_entry_hint(Owner, RequestRef, Ref, Phase, Identity,
                                                 Parent, Root, EntryHint) of
                        {ok, _, {evidence, _}} = Ok -> Ok;
                        fallback ->
                            fetch_exact_from_cache(Owner, RequestRef, Peer, Endpoint, Slot,
                                                   Identity, Parent, Root, FetchFun, PageTimeout);
                        {error, _, _} = Error -> Error
                    end;
                {error, _, _} = Error -> Error
            end;
        _ ->
            fetch_exact_from_cache(Owner, RequestRef, Peer, Endpoint, Slot,
                                   Identity, Cursor, Root, FetchFun, PageTimeout)
    end.

fetch_hint_parent(_Owner, _RequestRef, _Peer, _Endpoint, Slot, _Identity,
                  Cursor = #verified_cursor{height = Height}, _Root, _FetchFun, _PageTimeout)
  when Height =:= Slot - 1 ->
    {ok, Cursor};
fetch_hint_parent(Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                  Cursor, Root, FetchFun, PageTimeout) ->
    case fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot - 1, Identity,
                         Cursor, Root, FetchFun, PageTimeout) of
        {ok, Next = #verified_cursor{height = Height}, _} when Height =:= Slot - 1 ->
            {ok, Next};
        {ok, Next, _} -> {error, retry, Next};
        {error, _, _} = Error -> Error
    end.

import_exact_entry_hint(Owner, RequestRef, Ref, Phase, Identity,
                        Cursor = #verified_cursor{height = Height}, Root, Entry) ->
    Slot = Height + 1,
    case entry_index(Entry) of
        Slot -> import_next_entry_hint(Owner, RequestRef, Ref, Phase, Identity,
                                       Cursor, Root, Entry, Slot);
        _ -> fallback
    end.

import_next_entry_hint(Owner, RequestRef, Ref, Phase, Identity = {Ns, Anchor},
                      Cursor = #verified_cursor{projection = Projection, phase_index = PhaseIndex},
                      Root, Entry, Slot) ->
    case prepare_verified_page(Ns, Anchor, Identity, Projection, PhaseIndex,
                               Slot, Slot, [Entry], Slot) of
        {ok, #{verified := [VerifiedEntry], projection := NextProjection} = Prepared} ->
            case verify_exact_reference_entry(Ref, Phase, VerifiedEntry, NextProjection) of
                {ok, Evidence} ->
                    trace_count(hint_entries, 1),
                    case persist_verified_page(Owner, RequestRef, Identity, Cursor, Root, Prepared) of
                        {ok, Next} -> {ok, Next, {evidence, Evidence}};
                        {error, _, _} = Error -> Error
                    end;
                {error, _} -> fallback
            end;
        {error, _} -> fallback
    end.

fetch_exact_from_cache(Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                      Cursor, Root, FetchFun, PageTimeout) ->
    case fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                         Cursor, Root, FetchFun, PageTimeout) of
        {ok, Next, EvidenceProjection} -> {ok, Next, {projection, EvidenceProjection}};
        {error, _, _} = Error -> Error
    end.

fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot, Identity = {Ns, Anchor},
                Cursor = #verified_cursor{height = Height, projection = Projection,
                                          phase_index = PhaseIndex,
                                          target_projection = TargetProjection},
                Root, FetchFun, PageTimeout) ->
    case Height >= Slot of
        true when is_map(TargetProjection) ->
            {ok, Cursor, TargetProjection};
        true ->
            {error, cache_corrupt, Cursor#verified_cursor{state = invalid}};
        false ->
            From = Height + 1,
            To = min(Slot, From + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES - 1),
            case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, From, To, FetchFun, PageTimeout) of
                {ok, Entries, RemoteHeight} when is_integer(RemoteHeight), RemoteHeight >= 0 ->
                    case prepare_verified_page(Ns, Anchor, Identity, Projection, PhaseIndex,
                                               From, To, Entries, RemoteHeight) of
                        {ok, Prepared} ->
                            trace_verified_page(Peer, maps:get(count, Prepared)),
                            case persist_verified_page(Owner, RequestRef, Identity, Cursor, Root, Prepared) of
                                {ok, Next = #verified_cursor{height = NextHeight,
                                                             projection = NextProjection}}
                                  when NextHeight > Height ->
                                    Target = case NextHeight =:= Slot of
                                                 true -> NextProjection; false -> undefined end,
                                    fetch_to_height(Owner, RequestRef, Peer, Endpoint, Slot, Identity,
                                      Next#verified_cursor{target_projection = Target},
                                      Root, FetchFun, PageTimeout);
                                {ok, Next} -> {error, invalid_history, Next};
                                {error, _, _} = Error -> Error
                            end;
                        {error, Reason} -> {error, Reason, Cursor}
                    end;
                _ -> {error, retry, Cursor}
            end
    end.

prepare_verified_page(
  Ns, Anchor, Identity, Projection0, PhaseIndex,
  From, To, Entries, RemoteHeight) ->
    measure_foreign_stage(page_verify,
      fun() -> prepare_verified_page_raw(Ns, Anchor, Identity, Projection0, PhaseIndex,
                                         From, To, Entries, RemoteHeight) end).

prepare_verified_page_raw(
  Ns, Anchor, Identity, Projection0, PhaseIndex,
  From, To, Entries, RemoteHeight) ->
    case validate_page(Entries, From, To, RemoteHeight) of
        {ok, Count, EntryBytes} ->
            case quod_catchup:verify_forward(Ns, Anchor, Projection0, From, Entries, PhaseIndex) of
                {ok, Verified, Projection1, Delta} when length(Verified) =:= Count ->
                    case valid_projection(Projection1, Identity) of
                        true ->
                            {ok, #{verified => Verified, projection => Projection1,
                                   phase_delta => Delta, count => Count,
                                   stored_bytes => EntryBytes + 12 * Count}};
                        false -> {error, invalid_history}
                    end;
                {error, {unavailable, network_identity, _Reason}} = Global -> Global;
                {error, _Reason} -> {error, invalid_history}
            end;
        {error, _} -> {error, invalid_history}
    end.

persist_verified_page(
  Owner, RequestRef, Identity,
  Cursor = #verified_cursor{store = Store, height = Height, phase_index = PhaseIndex},
  Root, #{verified := Verified, projection := Projection,
          phase_delta := Delta, count := Count, stored_bytes := StoredBytes}) ->
    %% Reservation refusal precedes mutation and preserves the old prefix.
    %% Once append is attempted, ANY failure invalidates this cursor. The old
    %% cursor must never flow into another source after a partially durable page.
    Reservation = StoredBytes + ?QUOD_MAX_FOREIGN_PAGE_BYTES,
    case persistence_reservation(measure_foreign_stage(cache_accounting,
           fun() -> gen_server:call(Owner, {reserve_page, RequestRef, Reservation}) end)) of
        ok ->
            try
                {ok, NextStore} = persistence_stage(ledger_append,
                                   fun() -> quod_ledger_store:append(Store, Verified) end),
                ok = persistence_stage(phase_commit,
                       fun() -> quod_dtx_phase_index:commit_delta(PhaseIndex, Delta) end),
                NextHeight = Height + Count,
                ok = persistence_stage(checkpoint_write,
                       fun() -> write_checkpoint(Root, Identity, cache_namespace(Identity),
                                                 NextHeight, Projection) end),
                ActualBytes = cache_persisted_bytes(Root, cache_namespace(Identity)),
                ok = persistence_stage(cache_accounting,
                       fun() -> gen_server:call(Owner, {set_cache_size, RequestRef, ActualBytes}) end),
                {ok, Cursor#verified_cursor{store = NextStore, height = NextHeight,
                                            projection = Projection, target_projection = undefined}}
            catch _:_ ->
                {error, cache_corrupt, Cursor#verified_cursor{state = invalid}}
            end;
        {error, _} ->
            {error, cache_unavailable, Cursor}
    end.

persistence_stage(Stage, Fun) ->
    Result = measure_foreign_stage(Stage, Fun),
    persistence_boundary(Stage),
    Result.

-ifdef(TEST).
%% Fault injection is worker-owned and consumed once, after the real mutation.
%% The production branch is inert; no timing, outcome or recovery policy lives here.
persistence_reservation(Result) ->
    case get({?MODULE, persistence_failure}) of
        reserve_page ->
            erase({?MODULE, persistence_failure}),
            {error, test_reservation_refused};
        _ -> Result
    end.

persistence_boundary(Stage) ->
    case get({?MODULE, persistence_failure}) of
        Stage ->
            erase({?MODULE, persistence_failure}),
            error(test_persistence_failure);
        _ -> ok
    end.
-else.
persistence_reservation(Result) -> Result.
persistence_boundary(_Stage) -> ok.
-endif.

current_route_candidates(
  #{request := Request, live := Live, supplied := Supplied,
    bootstrap := Bootstrap}, Projection) ->
    Committee = quod_simplex:history_committee(Projection),
    case Committee of
        [] -> discovery_route_candidates(Request, Live, Supplied, Bootstrap);
        [_ | _] ->
            Certified = quod_simplex:history_validator_routes(Projection),
            CertifiedEndpoints = maps:from_keys(
                                   maps:values(Certified), true),
            lists:filtermap(
              fun(Peer) ->
                  Endpoints = current_peer_endpoints(
                                Peer, Request, Bootstrap, Live, Supplied,
                                Certified, CertifiedEndpoints),
                  case Endpoints of
                      [] -> false;
                      [_ | _] -> {true, {Peer, Endpoints}}
                  end
              end, Committee)
    end.

current_peer_endpoints(Peer, Request, Bootstrap, Live, Supplied,
                       Certified, CertifiedEndpoints) ->
    RequestEndpoint = first_peer_endpoint(Peer, Request),
    Historical = maps:get(Peer, Certified, none),
    LiveEndpoint = first_live_endpoint(Peer, Bootstrap, Live),
    ThirdParty = permitted_supplied_endpoint(
                   Peer, Historical, Supplied, CertifiedEndpoints),
    lists:sublist(
      lists:uniq(
        [Endpoint || Endpoint <- [RequestEndpoint, LiveEndpoint,
                                  Historical, ThirdParty],
                     Endpoint =/= none]),
      2).

empty_route_sources() ->
    #{request => [], live => [], supplied => [], bootstrap => [],
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

advance_current_snapshot(Owner, RequestRef, Hints, Identity,
                         Cursor = #verified_cursor{height = Height, projection = Projection},
                         Root, FetchFun, PageTimeout, RequestTimeout, AdvanceMode) ->
    case maps:size(quod_simplex:history_validator_routes(Projection)) of
        0 ->
            Sources = flatten_route_candidates(Hints),
            sequential_snapshot_sources(Sources, Owner, RequestRef, Identity, Cursor,
              Root, FetchFun, bootstrap_route_timeout(PageTimeout, RequestTimeout, length(Sources)),
              PageTimeout, AdvanceMode);
        _ ->
            {Ns, _Anchor} = Identity,
            Results = probe_pages(Owner, RequestRef, Hints, Ns, Height, FetchFun, PageTimeout),
            advance_snapshot(Owner, RequestRef, Identity, Cursor, Root,
                             Results, FetchFun, PageTimeout, AdvanceMode)
    end.

bootstrap_route_timeout(PageTimeout, RequestTimeout, RouteCount) ->
    %% Discovery gets at most half the request. The remaining half is reserved
    %% for downloading and verifying the selected history and corroborating
    %% its resulting committee view.
    PerRoute = erlang:max(1, RequestTimeout div (2 * erlang:max(1, RouteCount))),
    erlang:min(PageTimeout, PerRoute).

%% A route owns no prefix. Partial verified advancement survives its failure;
%% an invalid local cursor stops the walk before another source sees that file.
sequential_snapshot_sources([], _Owner, _RequestRef, _Identity, Cursor,
                            _Root, _FetchFun, _BootstrapTimeout, _PageTimeout, _AdvanceMode) ->
    {error, invalid_history, Cursor};
sequential_snapshot_sources([Source | Rest], Owner, RequestRef, Identity, Cursor,
                            Root, FetchFun, BootstrapTimeout, PageTimeout, AdvanceMode) ->
    case sequential_snapshot_source(Source, Owner, RequestRef, Identity, Cursor,
                                    Root, FetchFun, BootstrapTimeout, PageTimeout, AdvanceMode) of
        {ok, _} = Ok -> Ok;
        {error, _, #verified_cursor{state = invalid}} = Invalid -> Invalid;
        {error, {unavailable, network_identity, _}, _} = Global -> Global;
        {error, Reason, Next} ->
            logger:debug("foreign history bootstrap source failed identity=~p source=~p reason=~p",
                         [Identity, Source, Reason]),
            sequential_snapshot_sources(Rest, Owner, RequestRef, Identity, Next,
                                        Root, FetchFun, BootstrapTimeout, PageTimeout, AdvanceMode)
    end.

sequential_snapshot_source(
  Source = {Peer, Endpoint}, Owner, RequestRef, Identity = {Ns, _Anchor},
  Cursor = #verified_cursor{height = Height}, Root, FetchFun,
  BootstrapTimeout, PageTimeout, AdvanceMode) ->
    ProbeTo = Height + 1,
    case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, Height + 1, ProbeTo,
                    FetchFun, BootstrapTimeout) of
        {ok, Entries, RemoteHeight} when is_integer(RemoteHeight), RemoteHeight > Height ->
            case validate_page(Entries, Height + 1, ProbeTo, RemoteHeight) of
                {ok, _Count, _Bytes} ->
                    advance_snapshot_to_height([Source], Owner, RequestRef, Identity,
                      Cursor, Root, snapshot_target(AdvanceMode, Height, RemoteHeight),
                      FetchFun, PageTimeout);
                {error, Reason} -> {error, {bootstrap_page, Reason}, Cursor}
            end;
        {ok, _Entries, _RemoteHeight} -> {error, no_new_page, Cursor};
        {error, Reason} -> {error, {bootstrap_fetch, Reason}, Cursor}
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
    parallel_probes(Items, Probe, TimeoutMs, all).

%% Initial discovery needs every result for maximum-height selection. Only
%% final confirmation selects a threshold, over one worker per committee key.
%% Both policies share correlation, the absolute deadline and child cleanup.
parallel_probes(Items, Probe, TimeoutMs, Completion) ->
    trace_foreign_stage(probe_collection,
      #{'quod.foreign.expected_probe_children' => length(Items)},
      fun() -> parallel_probes_raw(Items, Probe, TimeoutMs, Completion) end).

parallel_probes_raw(Items, Probe, TimeoutMs, Completion) ->
    Parent = self(),
    Tag = make_ref(),
    TraceCtx = quod_trace:context(),
    TraceStages = get(?TRACE_STAGE_ACTIVE),
    trace_count(probes_started, length(Items)),
    Pending = lists:foldl(
                fun({Ordinal, Item}, Acc) ->
                    {Pid, MRef} = spawn_opt(
                                    fun() ->
                                        Result = traced_probe_work(
                                                   TraceCtx, TraceStages, Ordinal,
                                                   fun() -> Probe(Item) end),
                                        Parent ! {foreign_probe, Tag, self(),
                                                  Item, Result}
                                    end, [link, monitor]),
                    Acc#{Pid => {MRef, Item}}
                end, #{}, lists:enumerate(Items)),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    Collection = case Completion of
                     all -> {all, []};
                     {threshold, Needed} when is_integer(Needed), Needed > 0 ->
                         {threshold, Needed, #{}}
                 end,
    collect_probes(Tag, Pending, Deadline, Collection).

traced_probe_work(TraceCtx, true, Ordinal, Fun) ->
    quod_trace:with_span(
      TraceCtx, <<"quod.foreign.probe_worker">>, internal,
      #{'quod.foreign.probe_ordinal' => Ordinal},
      fun(SpanCtx) ->
          Previous = put(?TRACE_STAGE_ACTIVE, true),
          PreviousCounts = put({?MODULE, trace_counts}, #{}),
          try
              Result = Fun(),
              trace_foreign_result(SpanCtx, Result),
              Result
          catch Class:Reason:Stack ->
              trace_foreign_exception(SpanCtx, Class),
              erlang:raise(Class, Reason, Stack)
          after
              Counts = get({?MODULE, trace_counts}),
              _ = quod_trace:set_attributes(SpanCtx,
                    #{'quod.foreign.stages_started' => maps:get(stage_started, Counts, 0),
                      'quod.foreign.stages_completed' => maps:get(stage_completed, Counts, 0)}),
              restore_trace_counts(PreviousCounts),
              restore_trace_stage(Previous)
          end
      end);
traced_probe_work(TraceCtx, _Inactive, _Ordinal, Fun) ->
    quod_trace:with_context(TraceCtx, Fun).

collect_probes(Tag, Pending, Deadline, Collection) ->
    case probe_collection_complete(Collection, map_size(Pending)) of
        true ->
            stop_current_probes(Pending),
            probe_collection_result(Collection);
        false ->
            Wait = max(0, Deadline - quod_time:mono_ms()),
            receive
                {foreign_probe, Tag, Pid, Item, Result}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {MRef, Item} ->
                            trace_count(probe_results, 1),
                            _ = erlang:demonitor(MRef, [flush]),
                            collect_probes(
                              Tag, maps:remove(Pid, Pending), Deadline,
                              collect_probe_result(Collection, Item, Result));
                        _ ->
                            collect_probes(Tag, Pending, Deadline, Collection)
                    end;
                {'DOWN', MRef, process, Pid, _Reason}
                  when is_map_key(Pid, Pending) ->
                    case maps:get(Pid, Pending) of
                        {MRef, _Item} ->
                            collect_probes(
                              Tag, maps:remove(Pid, Pending), Deadline, Collection);
                        _ ->
                            collect_probes(Tag, Pending, Deadline, Collection)
                    end
            after Wait ->
                stop_current_probes(Pending),
                probe_collection_result(Collection)
            end
    end.

probe_collection_complete({all, _Results}, Remaining) -> Remaining =:= 0;
probe_collection_complete({threshold, Needed, Confirmed}, Remaining) ->
    Count = map_size(Confirmed),
    Count >= Needed orelse Count + Remaining < Needed.

collect_probe_result({all, Results}, Item, Result) ->
    {all, [{Item, Result} | Results]};
collect_probe_result({threshold, Needed, Confirmed}, {Peer, _Endpoints}, true) ->
    {threshold, Needed, Confirmed#{Peer => true}};
collect_probe_result({threshold, _, _} = Collection, _Item, _Result) ->
    Collection.

probe_collection_result({all, Results}) -> lists:reverse(Results);
probe_collection_result({threshold, Needed, Confirmed}) ->
    map_size(Confirmed) >= Needed.

stop_current_probes(Pending) ->
    trace_count(probes_cancelled, map_size(Pending)),
    maps:foreach(
      fun(Pid, {MRef, _Item}) ->
          _ = erlang:demonitor(MRef, [flush]),
          _ = unlink(Pid),
          exit(Pid, kill)
      end, Pending).

advance_snapshot(Owner, RequestRef, Identity,
                 Cursor = #verified_cursor{height = Height}, Root, Results,
                 FetchFun, PageTimeout, AdvanceMode) ->
    ProbeTo = Height + 1,
    Candidates = [{RemoteHeight, Source}
                  || {Source, {ok, Entries, RemoteHeight}} <- Results,
                     is_integer(RemoteHeight), RemoteHeight > Height,
                     validate_page(Entries, Height + 1, ProbeTo, RemoteHeight)
                       =/= {error, bad_page}],
    case Candidates of
        [] -> {ok, Cursor};
        _ ->
            Advertised = lists:max([H || {H, _Source} <- Candidates]),
            CandidateSources = [Source || {_H, Source} <-
                                lists:reverse(lists:keysort(1, Candidates))],
            advance_snapshot_to_height(flatten_route_candidates(CandidateSources),
              Owner, RequestRef, Identity, Cursor, Root,
              snapshot_target(AdvanceMode, Height, Advertised), FetchFun, PageTimeout)
    end.

snapshot_target(one_page, Height, Advertised) ->
    min(Advertised, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES);
snapshot_target(to_tip, _Height, Advertised) ->
    Advertised.

advance_snapshot_to_height(_Sources, _Owner, _RequestRef, _Identity,
                           Cursor = #verified_cursor{height = Height},
                           _Root, Target, _FetchFun, _PageTimeout) when Height >= Target ->
    {ok, Cursor};
advance_snapshot_to_height(Sources, Owner, RequestRef, Identity,
                           Cursor = #verified_cursor{height = Height},
                           Root, Target, FetchFun, PageTimeout) ->
    PageTarget = min(Target, Height + ?QUOD_MAX_FOREIGN_PAGE_ENTRIES),
    case advance_snapshot_sources(Sources, Owner, RequestRef, Identity, Cursor,
                                  Root, PageTarget, FetchFun, PageTimeout) of
        {ok, Next = #verified_cursor{height = NextHeight}} when NextHeight > Height ->
            advance_snapshot_to_height(Sources, Owner, RequestRef, Identity, Next,
                                       Root, Target, FetchFun, PageTimeout);
        {ok, Next} -> {error, invalid_history, Next};
        {error, _, _} = Error -> Error
    end.

advance_snapshot_sources([], _Owner, _RequestRef, _Identity, Cursor,
                         _Root, _Target, _FetchFun, _PageTimeout) ->
    {error, invalid_history, Cursor};
advance_snapshot_sources([{Peer, Endpoint} | Rest], Owner, RequestRef,
                         Identity = {Ns, Anchor},
                         Cursor = #verified_cursor{height = Height, projection = Projection,
                                                   phase_index = PhaseIndex},
                         Root, Target, FetchFun, PageTimeout) ->
    case fetch_page(Owner, RequestRef, Peer, Endpoint, Ns, Height + 1, Target,
                    FetchFun, PageTimeout) of
        {ok, Entries, RemoteHeight}
          when is_list(Entries), is_integer(RemoteHeight), RemoteHeight >= 0 ->
            case prepare_verified_page(Ns, Anchor, Identity, Projection, PhaseIndex,
                                       Height + 1, Target, Entries, RemoteHeight) of
                {ok, Prepared} ->
                    trace_verified_page(Peer, maps:get(count, Prepared)),
                    persist_verified_page(Owner, RequestRef, Identity, Cursor, Root, Prepared);
                {error, invalid_history} ->
                    advance_snapshot_sources(Rest, Owner, RequestRef, Identity, Cursor,
                                             Root, Target, FetchFun, PageTimeout);
                {error, {unavailable, network_identity, _} = Reason} ->
                    {error, Reason, Cursor}
            end;
        _ ->
            advance_snapshot_sources(Rest, Owner, RequestRef, Identity, Cursor,
                                     Root, Target, FetchFun, PageTimeout)
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
    Candidates = confirmation_candidates(Hints, Committee),
    Needed = quod_simplex:quorum(length(Committee)),
    Confirmed = parallel_probes(
                Candidates,
                fun({Peer, Endpoints}) ->
                    probe_confirmed_endpoint(
                      Endpoints, Owner, RequestRef, Peer, Ns, Height,
                      Anchor, Identity, Projection, PhaseIndex,
                      FetchFun, PageTimeout)
                end,
                PageTimeout, {threshold, Needed}),
    confirmation_collected(Confirmed).

%% Reachability rows can repeat; neither another endpoint nor another hint is
%% another possible confirmer. Preserve the existing first-seen endpoint walk.
confirmation_candidates(Hints, Committee) ->
    Members = maps:from_keys(Committee, true),
    {Order, Grouped} = lists:foldl(
      fun({Peer, Endpoints}, {Keys, Rows} = Acc) ->
          case maps:is_key(Peer, Members) of
              false -> Acc;
              true ->
                  case maps:find(Peer, Rows) of
                      error -> {[Peer | Keys], Rows#{Peer => Endpoints}};
                      {ok, Prior} -> {Keys, Rows#{Peer := Prior ++ Endpoints}}
                  end
          end
      end, {[], #{}}, Hints),
    [{Peer, lists:uniq(maps:get(Peer, Grouped))}
     || Peer <- lists:reverse(Order)].

-ifdef(TEST).
test_parallel_probes(Items, Probe, TimeoutMs, Completion) ->
    parallel_probes(Items, Probe, TimeoutMs, Completion).

test_confirmation_candidates(Hints, Committee) ->
    confirmation_candidates(Hints, Committee).

%% Pause after the real collector, while the enclosing request is still live.
%% Whole-request cancellation must not conceal a leaked immediate-puller row.
confirmation_collected(Result) ->
    case erase({?MODULE, confirmation_gate}) of
        {TestPid, Token} ->
            TestPid ! {foreign_confirmation_returned, Token, self(), Result},
            receive {release_foreign_confirmation, Token} -> ok end;
        _ -> ok
    end,
    Result.
-else.
confirmation_collected(Result) -> Result.
-endif.

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
    Source = case Peer of {local, _} -> <<"local">>; _ -> <<"network">> end,
    Result = trace_foreign_stage(page_fetch,
               #{'quod.foreign.page_source' => Source,
                 'quod.foreign.page_from' => From,
                 'quod.foreign.page_to' => To},
               fun() ->
                   Page = fetch_page_raw(
                            Owner, RequestRef, Peer, Endpoint, Ns, From, To,
                            FetchFun, PageTimeout),
                   trace_page_result(Page),
                   Page
               end),
    observe_foreign_stage(page_fetch, cache_result(Result), StartedNative),
    Result.

trace_page_result({ok, Entries, Height}) when is_list(Entries), is_integer(Height) ->
    case get(?TRACE_STAGE_ACTIVE) of
        true ->
            _ = quod_trace:set_attributes(
                  otel_tracer:current_span_ctx(quod_trace:context()),
                  #{'quod.foreign.page_entries' => length(Entries),
                    'quod.foreign.remote_height' => Height}),
            ok;
        _ -> ok
    end;
trace_page_result(_) -> ok.

fetch_page_raw(Owner, RequestRef, Peer, Endpoint, Ns, From, To, undefined,
               PageTimeout) ->
    Deadline = quod_time:mono_ms() + PageTimeout,
    TraceCtx = page_trace_context(),
    Raw = trace_foreign_stage(page_wait,
            fun() ->
                page_owner_call(Owner,
                  {pull_page, RequestRef, Peer, Endpoint, Ns, From, To, Deadline,
                   TraceCtx}, Deadline)
            end),
    case Raw of
        {decode_page, Key, Blobs, Height, PullDeadline, Gate} ->
            decode_pulled_page(Owner, Key, Blobs, Height,
                               min(Deadline, PullDeadline), Gate);
        {error, _} = Error -> Error
    end;
fetch_page_raw(_Owner, _RequestRef, Peer, Endpoint, Ns, From, To, FetchFun,
               _PageTimeout) ->
    try FetchFun(Peer, Endpoint, Ns, From, To)
    catch exit:_ -> {error, retry}
    end.

%% This is the requesting verifier/probe, never the node-wide owner. Local
%% snapshot fetchers above already return decoded entries and do not use a
%% remote page grant. The decoder's own faults must escape to worker-DOWN
%% cleanup; only the owner call's transport exit is normalized to retry.
decode_pulled_page(Owner, Key, Blobs, Height, Deadline, Gate) ->
    page_decode_gate(before_decode, Gate, Key),
    case Deadline > quod_time:mono_ms() of
        false -> page_wait_failure(page_expired);
        true ->
            Decoded = trace_foreign_stage(page_decode,
                        fun() -> quod_catchup:decode_entries(Blobs, wrapped) end),
            Verdict = case Decoded of {ok, _} -> decoded; {error, _} -> malformed end,
            page_decode_gate(before_completion, Gate, Key),
            Completion = trace_foreign_stage(page_completion,
                           fun() -> page_owner_call(Owner,
                             {complete_page_decode, Key, Verdict}, Deadline) end),
            case {Completion, Decoded} of
                {ok, {ok, Entries}} ->
                    page_decode_gate(after_accept, Gate, Key),
                    case Deadline > quod_time:mono_ms() of
                        true -> {ok, Entries, Height};
                        false -> page_wait_failure(page_expired)
                    end;
                _ -> {error, retry}
            end
    end.

page_trace_context() ->
    case get(?TRACE_STAGE_ACTIVE) of
        true -> quod_trace:context();
        _ -> undefined
    end.

page_owner_call(Owner, Request, Deadline) ->
    case Deadline - quod_time:mono_ms() of
        Remaining when Remaining > 0 ->
            %% Both local calls share the page's original absolute budget.
            %% In particular, an owner stalled after removing the row cannot
            %% leave the completion caller waiting on an already-cancelled timer.
            Reply = try gen_server:call(Owner, Request, Remaining)
                    catch
                        exit:{timeout, _} -> page_wait_failure(page_expired);
                        exit:_ -> page_wait_failure(owner_call_failed)
                    end,
            case Deadline > quod_time:mono_ms() of
                true -> Reply;
                false -> page_wait_failure(page_expired)
            end;
        _ -> page_wait_failure(page_expired)
    end.

%% This observation belongs to the calling verifier/probe, which alone mutates
%% its wait/completion/fetch span. The owner may retire its page row after this
%% span has already ended; that separate terminal child uses the retained parent
%% context rather than trying to annotate an exported worker span.
page_wait_failure(Cause) ->
    case get(?TRACE_STAGE_ACTIVE) of
        true ->
            _ = quod_trace:set_attributes(
                  otel_tracer:current_span_ctx(quod_trace:context()),
                  #{'quod.foreign.page_wait_cause' => atom_to_binary(Cause)});
        _ -> ok
    end,
    {error, retry}.

-ifdef(TEST).
take_page_decode_gate() -> erase({?MODULE, page_decode_gate}).

page_decode_gate(Stage, {TestPid, Token, Stage}, Key = {Owner, _, _, _, _}) ->
    TestPid ! {foreign_page_decode, Stage, Token, self(), Key},
    wait_page_decode_gate(TestPid, Token, Owner);
page_decode_gate(_Stage, _Gate, _Key) -> ok.

wait_page_decode_gate(TestPid, Token, Owner) ->
    receive
        {continue_foreign_page_decode, Token} -> ok;
        {test_complete_foreign_page, Token, Key, Verdict} ->
            Result = gen_server:call(Owner, {complete_page_decode, Key, Verdict}),
            TestPid ! {foreign_page_completion, Token, Result},
            wait_page_decode_gate(TestPid, Token, Owner)
    end.
-else.
take_page_decode_gate() -> undefined.
page_decode_gate(_Stage, _Gate, _Key) -> ok.
-endif.

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
page_indices([Entry | Rest], Next, To) when Next =< To ->
    entry_index(Entry) =:= Next andalso page_indices(Rest, Next + 1, To);
page_indices(_, _Next, _To) -> false.

entry_index(Entry) ->
    try (quod_ledger:entry_view(Entry))#entry.index
    catch error:_ -> error
    end.

verify_exact_reference(Store, Ref, ExpectedPhase, Projection) ->
    Slot = ref_slot(Ref),
    Lookup = trace_foreign_stage(exact_lookup,
               fun() ->
                   {quod_ledger_store:read_at(Store, Slot),
                    reference_projection(Slot, Slot, Projection)}
               end),
    case Lookup of
        {{ok, Entry}, {ok, EvidenceProjection}} ->
            verify_exact_reference_entry(
              Ref, ExpectedPhase, Entry, EvidenceProjection);
        {not_found, _} ->
            {error, retry};
        {_, error} ->
            {error, retry}
    end.

verify_exact_reference_entry(
  Ref, ExpectedPhase, Entry, Projection) ->
    trace_foreign_stage(exact_validate,
      fun() ->
          verify_exact_reference_entry_raw(Ref, ExpectedPhase, Entry, Projection)
      end).

verify_exact_reference_entry_raw(Ref, ExpectedPhase, Entry, Projection) ->
    #entry{data = Data} = quod_ledger:entry_view(Entry),
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
            #history{identity = Identity, cache_ns = CacheNs,
                     last_used = quod_time:mono_ms()}
    end.

load_history_dir(Root, Dir) ->
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
