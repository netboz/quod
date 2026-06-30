-module(quod_ledger).
-moduledoc """
Per-namespace lean **Raft** committee member: orders and replicates the ontology's
block list (the durable history) over the dedicated `{log, Ns}` `quod_link` channel,
and drives committed blocks into `quod_prolog`. One `gen_statem` per namespace;
states `follower` | `candidate` | `leader`. Hand-rolled Raft, **no Erlang
distribution** — every committee RPC rides a `quod_link` stream, exactly as Brahms
gossips. See `doc/ordering-layer-spec.md` §1–§2.

## Milestones

- **M1** — the single-voter degenerate case: a sole-member committee wins instantly,
  commits each append on its local `fsync`, applies in order. No networking.
- **M2** — a real N=3 committee over loopback QUIC: RequestVote +
  AppendEntries on the `{log, Ns}` channel, randomized elections, leader replication,
  and the multi-voter commit rule with the mandatory **Figure-8 current-term guard**.
  The commit/apply/persist core from M1 is unchanged (#18).
- **Join** (this layer) — a `mode=join` node grows the committee: it dials a contact
  (`#join_request{}`), the leader proves the `can_join` admission rule and admits it as a
  non-voting **learner** (`{add_learner}`), the existing AppendEntries back-up loop catches
  it up, and once it reaches its target the leader **promotes** it to a voter (`{promote}`)
  under the full single-server safety gate (one config change in flight + a current-term
  commit). Voters = the quorum/election set; learners receive entries but never vote.

## append → commit → apply is deadlock-free (load-bearing)

`quod_prolog:submit_write` calls `quod_ledger:append/2` synchronously, and this module's
apply step calls **back** into `quod_prolog:apply_block/3` synchronously. To avoid the
two blocking on each other, `append/2`'s `From` is parked in `pending` and replied
`{ok, Index}` the instant the entry **commits** (a majority holds it) — *not* at apply
time. That commit ack unblocks `quod_prolog`; the apply loop (a deferred internal
event) then re-enters it freely, and the OCC verdict reaches the prove-client through
`quod_prolog`'s own `tx_id`-keyed park/release path. On step-down or a truncation that
drops an uncommitted entry, the parked `From` is failed `{error, not_in_charge, Hint}`,
which `submit_write` already handles. (This deliberately keeps the M1 split rather than
the design doc's "reply the verdict from the log statem", which would re-introduce the
deadlock.)

## Channel-match hazard

Every receive/link clause guards on `Chan = term_to_binary({log, Ns}, [deterministic])`,
**never** on `Ns` — Brahms matches its own gossip on `Ns`, and a clause matching `Ns`
here would steal/own the wrong stream.
""".
-behaviour(gen_statem).
-include("quod_ledger.hrl").

%% API
-export([start_link/2, append/2, rebuild/1, status/1, committee/1, stats/1, namespaces/0]).
%% gen_statem
-export([init/1, callback_mode/0, terminate/3]).
%% states
-export([follower/3, candidate/3, leader/3]).

-ifdef(TEST).
-export([last_log_index/1, last_log_term/1, term_at/2, quorum/1, derive_committee/1,
         derive_learners/1, learner_target/2, voter_peers/1, repl_peers/1, cfg_uncommitted/1,
         has_current_term_commit/1, valid_node_id/1, committed_view/1, evict_one/1, up_to_date/4,
         advance_commit/1, truncate_append/2, encode/1, decode/1, mk_d/1, commit_index/1]).
-endif.

-define(DEFAULTS,
        #{node_id      => undefined,  %% own NodeId {Host,Port}; REQUIRED
          mode         => create,     %% create | join (join ⇒ a fresh node syncs via the join driver)
          role         => member,     %% member (voter joiner) | replica (permanent non-voting read-copy)
          committee    => [],         %% bootstrap committee; [] ⇒ self-only 1-voter (#18)
          seed_peers   => [],         %% contact endpoints a `join` node dials to join + sync
          heartbeat_ms => 150,        %% leader→peers AppendEntries cadence (<< election)
          election_ms  => 1000,       %% base election timeout; randomized to [T, 2T]
          election_jit => 1.0,
          join_ms      => 1000,       %% join-driver retry cadence (a joiner re-asks until admitted)
          max_batch    => 256,        %% max #entries per AppendEntries
          max_pending  => 1024,       %% backpressure cap on in-flight client appends
          data_dir     => undefined}).

-define(CHUNK_BYTES,        65536).        %% 64 KiB payload per quod_link frame
-define(MAX_RAFT_BYTES,     65536).        %% reassembled cap for non-snapshot msgs
-define(MAX_SNAPSHOT_BYTES, (64 bsl 20)).  %% reassembly hard cap (snapshots land in M3)
-define(AE_BATCH_BYTES,     (?CHUNK_BYTES - 8192)).  %% entry-bytes budget per AE (room for AE/envelope; keeps it single-frame)

%% Hostile-network resource caps on the join path (an unadmitted node can flood these).
-define(MAX_CONTACTS,        64).   %% joiner: cap on the contact list (redirects can't grow it unbounded)
-define(MAX_PENDING_JOINERS, 256).  %% leader/follower: cap on remembered joiners — REFUSE beyond, never evict
-define(MAX_ADMITTING,       16).   %% leader: cap on concurrent can_join proofs in flight

%% per-peer chunk reassembly (at most one in-flight message per peer; in-order channel)
-record(rx, {msg_id :: reference(),
             total  :: pos_integer(),
             got    :: #{pos_integer() => binary()},
             bytes  :: non_neg_integer()}).

-record(d, {ns      :: binary(),
            self    :: node_id(),
            cfg     :: map(),
            chan    :: binary(),                 %% term_to_binary({log, Ns}, [deterministic])
            %% keyed by the SEND TARGET: a member's node_id (pubkey) or a bootstrap seed's endpoint.
            conns   = #{} :: #{node_id() | endpoint() => {pid(), reference()}},  %% our OUTBOUND links
            outbox  = #{} :: #{node_id() | endpoint() => [binary()]},   %% per-peer FIFO while a link opens
            rx      = #{} :: #{node_id() => #rx{}},   %% reassembly is per-member (only members chunk)
            store   :: quod_ledger_store:handle() | undefined,
            role    = follower :: follower | candidate | leader,

            %% ---- PERSISTED (fsync via quod_ledger_store before reply) ----
            cur_term  = 0    :: term_no(),
            voted_for = none :: node_id() | none,
            log       = []   :: [#entry{}],       %% indices snap_idx+1 .. N — the durable block list
            snap_idx  = 0    :: log_index(),
            snap_term = 0    :: term_no(),
            snap_cfg  = []   :: [node_id()],    %% committee as of the snapshot / bootstrap

            %% ---- VOLATILE (reconstructed on restart) ----
            last_idx  = 0    :: log_index(),      %% cached tail of `log` (= snap_idx if empty): keeps
            last_term = 0    :: term_no(),        %% last_log_index/term O(1) instead of lists:last per call
            commit_index = 0    :: log_index(),
            last_applied = 0    :: log_index(),
            next_index   = #{}  :: #{node_id() => log_index()},   %% leader only
            match_index  = #{}  :: #{node_id() => log_index()},   %% leader only
            votes        = #{}  :: #{node_id() => boolean()},     %% candidate: votes this term
            leader_id    = none :: node_id() | none,
            pending      = #{}  :: #{log_index() => gen_statem:from()},  %% client appends awaiting commit
            prolog_ready = false :: boolean(),   %% have we told quod_prolog its kb is caught up?

            %% ---- membership growth (join path) ----
            contacts        = []  :: [endpoint()],  %% seed endpoints a `join` node dials to join+sync
            pending_joiners = #{}  :: #{node_id() => map()},  %% leader: joiners seen, so we can dial them back
            admitting       = #{}  :: #{node_id() => reference()},  %% leader: joiner => monitor ref of its in-flight admission proof
            %% (the promote target is DERIVED from the log by learner_target/2 — never a
            %% volatile note, so a restarted/newly-elected leader never strands a learner.)

            %% ---- counters ----
            elections = 0, appends = 0, commits = 0,
            msgs_sent = 0, msgs_recv = 0, bytes_sent = 0, chunks_sent = 0, rx_dropped = 0}).

callback_mode() -> [state_functions].

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_ledger, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Submit a change. Blocks until the entry commits ({ok, Index}) or this node loses leadership.".
-spec append(binary(), #transaction{}) ->
        {ok, log_index()} | {error, busy}
      | {error, not_in_charge, node_id() | none | unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), {append, Change}, 5000)
    catch exit:_ -> {error, not_in_charge, unavailable} end.

-doc "Ask the log to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_ledger, Ns}), rebuild).

status(Ns)    -> call(Ns, get_status, #{}).
committee(Ns) -> call(Ns, get_committee, []).
stats(Ns)     -> call(Ns, get_stats, undefined).

namespaces() -> gproc:select([{{{n, l, {quod_ledger, '$1'}}, '_', '_'}, [], ['$1']}]).

call(Ns, Req, Default) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), Req, 1000) catch exit:_ -> Default end.

%%%===================================================================
%%% init
%%%===================================================================

init({Ns, Config}) ->
    Cfg = maps:merge(?DEFAULTS, Config),
    case valid_cfg(Config, Cfg) of
        {error, Reason} -> {stop, {bad_config, Reason}};
        ok ->
            Self    = maps:get(node_id, Cfg),
            Chan    = term_to_binary({log, Ns}, [deterministic]),
            DataDir = data_dir(Cfg),
            quod_reg:subscribe({channel, Chan}),
            {ok, Store} = quod_ledger_store:open(Ns, DataDir),
            D0 = #d{ns = Ns, self = Self, cfg = Cfg, chan = Chan, store = Store},
            %% A bad/missing genesis `.pl` on create is fatal — fail-fast, the app stops.
            try load_or_bootstrap(D0, Cfg, Store) of
                D1 -> init_ready(D1)
            catch
                throw:{genesis_failed, _} = Reason -> {stop, Reason}
            end
    end.

init_ready(D1) ->
    D2 = D1#d{commit_index = D1#d.snap_idx, last_applied = D1#d.snap_idx},
    %% Links form on demand: a node dials a peer the first time it sends to it
    %% (send_raft) and replies on its OWN outbound link, never on the peer's inbound
    %% stream. So every committee member can reach every other — any node can win an
    %% election and lead (full Raft symmetry).
    Actions = case derive_committee(D2) of
                  []  -> maybe_join_driver(D2);               %% no voters yet: a fresh joiner asks to join
                  [_] -> [{next_event, internal, bootstrap}]; %% sole voter: lead now (M1 parity)
                  _   -> [election_timeout(D2)]               %% contest the election
              end,
    {ok, follower, D2, Actions}.

%% A `join`-mode node with no durable state and a contact list drives the join handshake:
%% it (re)asks a contact to be admitted, on a timer, until it appears in its own committee.
%% Anything else (a founder, a restart with state) returns no action here.
maybe_join_driver(D) ->
    case maps:get(mode, D#d.cfg) =:= join andalso D#d.contacts =/= [] of
        true  -> [join_timeout(D)];
        false -> []
    end.

%% Restart reloads durable state; a brand-new namespace seeds its committee from
%% Config (create) — `[]` ⇒ self-only 1-voter, a list ⇒ multi-member bootstrap.
load_or_bootstrap(D0, Cfg, Store) ->
    L = quod_ledger_store:load(Store),
    Log     = maps:get(log, L),
    SnapCfg = maps:get(snap_cfg, L),
    Term    = maps:get(cur_term, L),
    SnapIdx = maps:get(snap_idx, L),
    D = with_log(Log, D0#d{cur_term  = Term,
                           voted_for = maps:get(voted_for, L),
                           snap_idx  = SnapIdx,
                           snap_term = maps:get(snap_term, L),
                           snap_cfg  = SnapCfg,
                           contacts  = maps:get(seed_peers, Cfg, [])}),
    HasDurable = (Log =/= []) orelse (Term =/= 0) orelse (SnapIdx =/= 0) orelse (SnapCfg =/= []),
    case HasDurable of
        true  -> D;   %% restart: committee derived from snap_cfg + log; replay catches the rest up
        false ->
            case maps:get(mode, Cfg) of
                join -> D;   %% fresh joiner: empty committee, join driver armed in init_ready
                _    ->
                    Committee = case maps:get(committee, Cfg) of
                                    []   -> [D#d.self];                         %% founding 1-voter
                                    List -> lists:usort([D#d.self | List])      %% multi-member bootstrap
                                end,
                    D1 = bootstrap_committee(Committee, D),
                    bootstrap_genesis(Cfg, D1)
            end
    end.

%% Durably seed the founding committee as a deterministic run of genesis `{add, M}`
%% config entries (term 0, indices 1..K). Every founding member produces the SAME
%% entries (`lists:usort` ⇒ shared order), so their initial logs are byte-identical and
%% replicate consistently; `derive_committee/1` reconstructs the committee from them on
%% restart. (snap_cfg has no standalone durable form below the snapshot layer, so the
%% committee lives in the log, exactly as later membership changes will — §3.5.)
bootstrap_committee(Committee, D = #d{store = Store}) ->
    Entries = [#entry{index = I, term = 0, kind = config, data = {add, M}}
               || {I, M} <- lists:zip(lists:seq(1, length(Committee)), Committee)],
    {ok, Store1} = quod_ledger_store:append(Store, Entries),
    with_log(Entries, D#d{store = Store1}).

%% On create only, the founder commits the genesis ontology content (read ONCE from the
%% configured `.pl`) as a block right after the committee config — so it lives in the
%% replicated ledger and joiners sync it (they never read the `.pl`). No `genesis_file`
%% ⇒ no-op (M1/M2 tests, or a namespace whose content arrives by sync). A bad/missing
%% file is FATAL: throw ⇒ `init/1` returns `{stop, _}` ⇒ the app stops (a node with no
%% root is useless). The genesis tx_id is deterministic so multi-founder logs stay
%% byte-identical.
bootstrap_genesis(Cfg, D = #d{ns = Ns, self = Self, store = Store}) ->
    case maps:get(genesis_file, Cfg, undefined) of
        undefined -> D;
        <<>>      -> D;
        ""        -> D;
        File ->
            %% quod_prolog compiles the .pl into write-set ops in the on-disk clause
            %% form (erlog's body compilation); a bad file throws {genesis_failed,_}.
            Tx = #transaction{tx_id = <<"genesis:", Ns/binary>>, caller_ns = Ns,
                              diff = quod_prolog:genesis_diff(File), read_check = #{},
                              author = Self, sig = none},
            I  = last_log_index(D) + 1,
            E  = #entry{index = I, term = 0, kind = block, data = Tx},
            {ok, Store1} = quod_ledger_store:append(Store, [E]),
            with_log(D#d.log ++ [E], D#d{store = Store1})
    end.

valid_cfg(Config, Cfg) ->
    HB        = maps:get(heartbeat_ms, Cfg),
    EL        = maps:get(election_ms, Cfg),
    Committee = maps:get(committee, Cfg),
    NodeId    = maps:get(node_id, Config, undefined),
    if NodeId =:= undefined                  -> {error, missing_node_id};
       not is_list(Committee)                -> {error, {bad_committee, Committee}};
       not (is_integer(HB) andalso HB > 0)   -> {error, {bad_heartbeat, HB}};
       not (is_integer(EL) andalso EL > 0)   -> {error, {bad_election, EL}};
       HB >= EL                              -> {error, {heartbeat_ge_election, HB, EL}};
       true                                  -> ok
    end.

%%%===================================================================
%%% timers
%%%===================================================================

election_ms(Cfg) ->
    T = maps:get(election_ms, Cfg), J = maps:get(election_jit, Cfg),
    T + round(rand:uniform() * J * T).
election_timeout(#d{cfg = Cfg})  -> {state_timeout, election_ms(Cfg), election}.
heartbeat_timeout(#d{cfg = Cfg}) -> {state_timeout, maps:get(heartbeat_ms, Cfg), heartbeat}.
%% A NAMED generic timeout (independent of the election state_timeout, and not cancelled
%% by state changes) so the join driver can keep retrying while the node is a follower.
join_timeout(#d{cfg = Cfg}) -> {{timeout, join}, maps:get(join_ms, Cfg, 1000), join_tick}.

%%%===================================================================
%%% states
%%%===================================================================

follower(state_timeout, election, D) -> start_election(D);
follower(internal, bootstrap, D)     -> start_election(D);   %% 1-voter: lead now
follower({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, D#d.leader_id}}]};
follower(info, {quod_message, {{Peer, _Addr}, _InLink}, Chan, Payload}, D = #d{chan = Chan}) ->
    inbound(follower, Peer, Payload, D);   %% Peer = the sender's node_id (header pubkey); addr ignored
follower(EventType, Event, D) -> common(EventType, Event, D).

candidate(state_timeout, election, D) -> start_election(D);   %% no majority yet: retry
candidate({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, none}}]};
candidate(info, {quod_message, {{Peer, _Addr}, _InLink}, Chan, Payload}, D = #d{chan = Chan}) ->
    inbound(candidate, Peer, Payload, D);
candidate(EventType, Event, D) -> common(EventType, Event, D).

leader(state_timeout, heartbeat, D) ->
    {keep_state, replicate(D), [heartbeat_timeout(D)]};
leader(internal, replicate, D) ->
    {keep_state, replicate(D)};
leader({call, From}, {append, Change}, D) ->
    handle_client_append(From, Change, D);
leader(info, {quod_message, {{Peer, _Addr}, _InLink}, Chan, Payload}, D = #d{chan = Chan}) ->
    inbound(leader, Peer, Payload, D);
leader(EventType, Event, D) -> common(EventType, Event, D).

%%%===================================================================
%%% shared
%%%===================================================================

common(internal, run_apply, D) ->
    {keep_state, maybe_mark_ready(apply_committed(D))};
common({timeout, join}, join_tick, D) ->
    %% joiner: ask every known contact to admit us, until we are a COMMITTED member (then stop —
    %% the leader drives catch-up + promotion from here via AppendEntries). The committed view is
    %% load-bearing: stopping on a merely-tentative {add_learner,Self} that a new leader later
    %% truncates would strand us (we'd have stopped asking). Committed entries are never undone.
    case is_member(D#d.self, committed_view(D)) of
        true  -> {keep_state, D};
        false -> {keep_state, send_join_requests(D), [join_timeout(D)]}
    end;
common(cast, rebuild, D) ->
    %% a freshly-(re)started quod_prolog: re-drive committed blocks (async apply_block casts,
    %% in log order) from the snapshot point, then mark it ready ONLY once its kb is caught
    %% up to a re-learned commit point (maybe_mark_ready). The mark_ready cast rides the SAME
    %% FIFO channel as the apply_block casts, so it lands after them — quod_prolog is never
    %% marked ready over a half-built kb. On a multi-voter restart commit_index resets to
    %% snap_idx and is re-learned from the first AppendEntries/election, so readiness is
    %% correctly deferred until then (m2-review #3).
    D1 = apply_committed(D#d{last_applied = D#d.snap_idx, prolog_ready = false}),
    {keep_state, maybe_mark_ready(D1)};
common(info, {link_up, Peer, Chan, LinkPid}, D = #d{chan = Chan}) ->
    case (not maps:is_key(Peer, D#d.conns)) andalso link_allowed(Peer, D) of
        true  -> Ref = erlang:monitor(process, LinkPid),
                 D1 = D#d{conns = (D#d.conns)#{Peer => {LinkPid, Ref}}},
                 {keep_state, flush_outbox(Peer, LinkPid, D1)};
        false -> _ = quod_link:close(LinkPid),   %% not a member/contact/joiner, or already linked
                 {keep_state, D}
    end;
common(info, {join_decision, J, Allowed}, D) ->
    handle_join_decision(J, Allowed, D);   %% an admission helper reported its verdict
common(info, {link_error, Peer, Chan}, D = #d{chan = Chan}) ->
    %% a failed open: drop the buffered frames; Raft re-sends fresh on the next heartbeat.
    {keep_state, D#d{outbox = maps:remove(Peer, D#d.outbox)}};
common(info, {'DOWN', Ref, process, LinkPid, _Reason}, D) ->
    %% either a tracked link pid died (drop the conn) or an admission helper died without
    %% reporting (free its marker so the joiner can retry). Both are by-ref / by-pid no-ops if
    %% it's the other kind, so we apply both.
    {keep_state, drop_admitting_by_ref(Ref, drop_conn_by_pid(LinkPid, D))};
common(info, {quod_message, _, _OtherChan, _}, D) ->
    {keep_state, D};   %% another channel (Brahms / another namespace's log)
common({call, From}, get_status, D)    -> {keep_state, D, [{reply, From, status_map(D)}]};
common({call, From}, get_committee, D) -> {keep_state, D, [{reply, From, derive_committee(D)}]};
common({call, From}, get_stats, D)     -> {keep_state, D, [{reply, From, stats_map(D)}]};
common(_EventType, _Event, D) -> {keep_state, D}.

terminate(_Reason, _State, #d{chan = Chan, store = Store}) ->
    _ = try quod_reg:unsubscribe({channel, Chan}) catch _:_ -> ok end,
    _ = case Store of
            undefined -> ok;
            _         -> try quod_ledger_store:close(Store) catch _:_ -> ok end
        end,
    ok.

%%%===================================================================
%%% election: follower/candidate → candidate → leader
%%%===================================================================

start_election(D = #d{store = Store}) ->
    case lists:member(D#d.self, derive_committee(D)) of
        false -> {keep_state, D};   %% removed member (M4): don't contest, stay passive
        true ->
            T1 = D#d.cur_term + 1,
            ok = quod_ledger_store:write_meta(Store, T1, D#d.self),   %% DURABLE before any RPC
            D1 = D#d{cur_term = T1, voted_for = D#d.self, votes = #{D#d.self => true},
                     role = candidate, leader_id = none, elections = D#d.elections + 1,
                     next_index = #{}, match_index = #{}},
            logger:info("quod[~s]: election at term ~p", [D#d.ns, T1]),
            D2 = broadcast_request_vote(D1),
            case votes_count(D2) >= quorum(D2) of
                true  -> become_leader(D2);   %% quorum 1: self-vote suffices
                false -> {next_state, candidate, D2, [election_timeout(D2)]}
            end
    end.

become_leader(D) ->
    LLI   = last_log_index(D),
    Next  = maps:from_list([{P, LLI + 1} || P <- repl_peers(D)]),
    Match = maps:from_list([{P, 0}       || P <- repl_peers(D)]),
    D1 = D#d{role = leader, leader_id = D#d.self, next_index = Next, match_index = Match, votes = #{}},
    logger:info("quod[~s]: leader at term ~p (committee ~p)", [D#d.ns, D#d.cur_term, derive_committee(D1)]),
    case quorum(D1) of
        1 ->
            %% 1-voter: no contest, no prior-term uncommitted entries — commit the whole
            %% reloaded log directly (M1 parity; the Figure-8 noop is unnecessary, review #11).
            D2 = D1#d{commit_index = LLI},
            {next_state, leader, D2, [{next_event, internal, run_apply}, heartbeat_timeout(D2)]};
        _ ->
            %% multi-voter: append a current-term noop so prior-term entries a majority
            %% holds can commit indirectly, and followers advance commit with no client
            %% write (Figure-8). It commits via the same advance_commit rule.
            I  = LLI + 1,
            E  = #entry{index = I, term = D#d.cur_term, kind = block, data = noop},
            {ok, Store1} = quod_ledger_store:append(D1#d.store, [E]),
            D2 = with_log(D1#d.log ++ [E], D1#d{store = Store1}),
            {next_state, leader, D2, [{next_event, internal, replicate}, heartbeat_timeout(D2)]}
    end.

%% Lost authority (saw a higher term): persist the new term with no vote, drop volatile
%% leader state, and fail any in-flight client appends so their callers can retry.
step_down(NewTerm, D) ->
    ok = quod_ledger_store:write_meta(D#d.store, NewTerm, none),
    D1 = fail_pending(D, none),
    D1#d{cur_term = NewTerm, voted_for = none, role = follower, leader_id = none,
         votes = #{}, next_index = #{}, match_index = #{}}.

votes_count(#d{votes = V}) -> length([1 || {_, true} <- maps:to_list(V)]).

%%%===================================================================
%%% RequestVote
%%%===================================================================

broadcast_request_vote(D) ->
    RV = #request_vote{term = D#d.cur_term, candidate_id = D#d.self,
                       last_log_index = last_log_index(D), last_log_term = last_log_term(D)},
    lists:foldl(fun(P, A) -> send_raft(P, RV, A) end, D, voter_peers(D)).

handle_request_vote(Peer, #request_vote{term = RvT}, _State, D = #d{cur_term = CT}) when RvT < CT ->
    {keep_state, send_raft(Peer, #request_vote_reply{term = CT, vote_granted = false}, D)};
handle_request_vote(Peer, RV = #request_vote{term = RvT}, _State, D = #d{cur_term = CT}) when RvT > CT ->
    %% Higher term ⇒ step down to FOLLOWER, then decide the vote at the new term. The
    %% result MUST end in the follower state regardless of grant/deny: a denied vote that
    %% returned {keep_state} would leave a deposed leader in the `leader` state (role says
    %% follower) — a split-brain zombie that keeps heartbeating and ignores the real
    %% leader's AppendEntries (M2 bug found via traces).
    D1 = step_down(RvT, D),
    {Granted, D2} = decide_vote(RV, D1),
    D3 = send_raft(Peer, #request_vote_reply{term = D2#d.cur_term, vote_granted = Granted}, D2),
    {next_state, follower, D3, [election_timeout(D3)]};
handle_request_vote(Peer, RV, _State, D) ->   %% RvT == cur_term
    {Granted, D1} = decide_vote(RV, D),
    D2 = send_raft(Peer, #request_vote_reply{term = D1#d.cur_term, vote_granted = Granted}, D1),
    case Granted of
        %% Only an un-voted follower can grant at its own term (a leader/candidate already
        %% voted for itself ⇒ denies); granting re-arms its election timer.
        true  -> {next_state, follower, D2, [election_timeout(D2)]};
        %% Denied: we already voted this term — stay exactly as we are (a candidate keeps
        %% campaigning, a leader keeps leading) and do NOT reset the timer.
        false -> {keep_state, D2}
    end.

%% Decide a vote at the CURRENT term: grant iff we haven't voted for someone else and the
%% candidate's log is at least as up to date. Persists (durable) before granting.
decide_vote(#request_vote{candidate_id = Cand, last_log_index = CLI, last_log_term = CLT}, D) ->
    case (D#d.voted_for =:= none orelse D#d.voted_for =:= Cand)
         andalso up_to_date(CLT, CLI, last_log_term(D), last_log_index(D)) of
        true  -> ok = quod_ledger_store:write_meta(D#d.store, D#d.cur_term, Cand),
                 {true, D#d{voted_for = Cand}};
        false -> {false, D}
    end.

%% A candidate's vote reply. Higher term ⇒ step down. Equal term + granted ⇒ tally.
handle_vote_reply(_Peer, #request_vote_reply{term = RT}, _State, D = #d{cur_term = CT}) when RT > CT ->
    {next_state, follower, step_down(RT, D), [election_timeout(D)]};
handle_vote_reply(Peer, #request_vote_reply{term = RT, vote_granted = true}, candidate, D = #d{cur_term = CT})
  when RT =:= CT ->
    D1 = D#d{votes = (D#d.votes)#{Peer => true}},
    case votes_count(D1) >= quorum(D1) of
        true  -> become_leader(D1);
        false -> {keep_state, D1}
    end;
handle_vote_reply(_Peer, _Reply, _State, D) -> {keep_state, D}.   %% stale / not candidate / denied

%%%===================================================================
%%% AppendEntries
%%%===================================================================

handle_append_entries(Peer, #append_entries{term = AeT}, _State, D = #d{cur_term = CT}) when AeT < CT ->
    {keep_state, send_raft(Peer, #append_entries_reply{term = CT, success = false, match_index = 0}, D)};
handle_append_entries(_Peer, #append_entries{term = AeT}, leader, D = #d{cur_term = CT}) when AeT =:= CT ->
    {keep_state, D};   %% two leaders at one term is impossible — ignore the spurious AE
handle_append_entries(Peer, AE = #append_entries{term = AeT}, _State, D = #d{cur_term = CT}) ->
    %% AeT > CT, or AeT == CT and we are follower/candidate: recognize this leader.
    D0 = case AeT > CT of true -> step_down(AeT, D); false -> D end,
    D1 = D0#d{leader_id = AE#append_entries.leader_id, role = follower, votes = #{}},
    case ae_consistent(AE, D1) of
        ok ->
            D2 = apply_ae_entries(AE, D1),
            D3 = advance_follower_commit(AE, D2),
            MI = AE#append_entries.prev_log_index + length(AE#append_entries.entries),
            D4 = send_raft(Peer, #append_entries_reply{term = D3#d.cur_term, success = true,
                                                       match_index = MI}, D3),
            {next_state, follower, D4, [election_timeout(D4), {next_event, internal, run_apply}]};
        {fail, Hint} ->
            D2 = send_raft(Peer, #append_entries_reply{term = D1#d.cur_term, success = false,
                                                       match_index = Hint}, D1),
            {next_state, follower, D2, [election_timeout(D2)]}
    end.

%% Log-consistency check on (prev_log_index, prev_log_term). On failure the hint is
%% where the leader should back up to.
ae_consistent(#append_entries{prev_log_index = PLI, prev_log_term = PLT}, D) ->
    LLI = last_log_index(D),
    if PLI =:= 0            -> ok;
       PLI > LLI            -> {fail, LLI};
       PLI =:= D#d.snap_idx -> case PLT =:= D#d.snap_term of true -> ok; false -> {fail, max(0, PLI - 1)} end;
       true -> case term_at(PLI, D) =:= PLT of true -> ok; false -> {fail, PLI - 1} end
    end.

%% Merge incoming entries: same-index-same-term ⇒ skip (idempotent, NEVER truncate on a
%% match); same-index-different-term ⇒ truncate from there and append the suffix; new ⇒
%% append. Durable (fsync) before the caller replies success.
apply_ae_entries(#append_entries{entries = []}, D) -> D;   %% heartbeat
apply_ae_entries(#append_entries{entries = Entries}, D) ->
    {NewLog, Action} = truncate_append(D, Entries),
    case Action of
        noop -> D;
        {append, New} ->
            {ok, Store1} = quod_ledger_store:append(D#d.store, New),
            with_log(NewLog, D#d{store = Store1});
        {truncate_append, I, New} ->
            {ok, Store1} = quod_ledger_store:truncate_from(D#d.store, I),
            {ok, Store2} = quod_ledger_store:append(Store1, New),
            %% truncation dropped an uncommitted tail: fail any client append parked there.
            fail_pending_above(D#d.commit_index, with_log(NewLog, D#d{store = Store2}))
    end.

%% PURE: decide how to merge `Entries` into D's log. Returns {NewLog, Action}.
truncate_append(D, Entries) ->
    case split_point(Entries, D) of
        none ->
            {D#d.log, noop};
        {append_from, I} ->
            New = [E || E <- Entries, E#entry.index >= I],
            {D#d.log ++ New, {append, New}};
        {conflict_from, I} ->
            New  = [E || E <- Entries, E#entry.index >= I],
            Kept = [E || E <- D#d.log, E#entry.index < I],
            {Kept ++ New, {truncate_append, I, New}}
    end.

%% First incoming index that is new (> our log) or conflicting (different term).
split_point([], _D) -> none;
split_point([#entry{index = I, term = T} | Rest], D) ->
    case I > last_log_index(D) of
        true  -> {append_from, I};
        false -> case term_at(I, D) =:= T of
                     true  -> split_point(Rest, D);
                     false -> {conflict_from, I}
                 end
    end.

advance_follower_commit(#append_entries{leader_commit = LC}, D) when LC > D#d.commit_index ->
    D#d{commit_index = min(LC, last_log_index(D))};
advance_follower_commit(_AE, D) -> D.

%% A leader's AppendEntries reply.
handle_ae_reply(_Peer, #append_entries_reply{term = RT}, _State, D = #d{cur_term = CT}) when RT > CT ->
    {next_state, follower, step_down(RT, D), [election_timeout(D)]};
handle_ae_reply(Peer, Reply = #append_entries_reply{term = RT}, leader, D = #d{cur_term = CT})
  when RT =:= CT ->
    case Reply#append_entries_reply.success of
        true ->
            MI = Reply#append_entries_reply.match_index,
            Match1 = (D#d.match_index)#{Peer => max(maps:get(Peer, D#d.match_index, 0), MI)},
            D1   = ack_pending(advance_commit(D#d{match_index = Match1,
                                                  next_index = (D#d.next_index)#{Peer => MI + 1}})),
            LLI0 = last_log_index(D1),
            D2   = maybe_promote_learner(Peer, D1),       %% a caught-up learner ⇒ append {promote}
            %% read next_index from D2 (post-promote), not a pre-promote snapshot: append_promote
            %% doesn't touch next_index today, but reading the live map is the honest source.
            D3   = case maps:get(Peer, D2#d.next_index) =< last_log_index(D2) of
                       true  -> replicate_to(Peer, D2);   %% pipeline the next batch
                       false -> D2
                   end,
            %% a promote just appended a config entry: fan the new voter set out at once
            %% (so the joiner adopts its vote) rather than waiting for the next heartbeat.
            Extra = case last_log_index(D3) > LLI0 of true -> [{next_event, internal, replicate}]; false -> [] end,
            {keep_state, D3, [{next_event, internal, run_apply} | Extra]};
        false ->
            NextV = max(D#d.snap_idx + 1, Reply#append_entries_reply.match_index + 1),
            D1 = D#d{next_index = (D#d.next_index)#{Peer => NextV}},
            {keep_state, replicate_to(Peer, D1)}   %% back up and retry
    end;
handle_ae_reply(_Peer, _Reply, _State, D) -> {keep_state, D}.   %% stale / not leader

%%%===================================================================
%%% join / membership growth (learner → catch-up → promote)
%%%===================================================================

%% Joiner side: ask every known contact to admit us. send_raft dials a contact on demand;
%% link_allowed/2 permits the link because the contact is in #d.contacts.
send_join_requests(D = #d{self = Self, cfg = Cfg}) ->
    %% `joiner = Self` (our node_id/pubkey); the leader binds it to our TLS-authenticated pubkey.
    %% advertise our role so the leader admits us on the right track (voter joiner vs read-replica).
    Req = #join_request{joiner = Self, args = #{as => maps:get(role, Cfg, member)}},
    lists:foldl(fun(C, A) -> send_raft(C, Req, A) end, D, D#d.contacts).

%% A join_request arrives from a node the network has NOT accepted yet — an outsider. Two guards
%% before anything trusts it: (1) `joiner` is a well-formed node_id (a malformed id would otherwise
%% function_clause in the admission path — a one-packet leader DoS); (2) **possession** — the claimed
%% `joiner` MUST equal `Peer`, the connection's TLS-authenticated sender pubkey, so a node can only
%% ask to join AS ITSELF (closes deferred §1). Bad request ⇒ silently dropped.
handle_join_request(State, Peer, Req = #join_request{joiner = J}, D) ->
    case valid_node_id(J) andalso J =:= Peer of
        true  -> dispatch_join_request(State, Peer, Req, D);
        false -> {keep_state, D}
    end.

%% Leader: admit a new joiner as a non-voting learner (after proving the admission rule),
%% unless it is already a member. Remembering it in pending_joiners lets us dial it back.
%% The admission proof runs in a HELPER process (start_admission), NOT inline: a scoped prove
%% may legitimately be slow (backtracking, cross-ontology reads), and this gen_statem also
%% owns the heartbeat — it must never block on unbounded work or it would stop heartbeating
%% and be voted out. The verdict returns as a {join_decision, ...} message.
dispatch_join_request(leader, _Peer, #join_request{joiner = J, args = Args}, D) ->
    case is_member(J, D) of
        true  -> {keep_state, send_raft(J, #join_reply{result = already_member}, D)};
        false ->
            %% REFUSE-beyond-cap (never evict): evicting would let a flood push a real in-progress
            %% joiner out of pending_joiners → out of link_allowed → the leader can't dial it back
            %% → its promotion stalls. Refusing new strangers pins every in-progress joiner.
            case maps:is_key(J, D#d.pending_joiners)
                 orelse maps:size(D#d.pending_joiners) < ?MAX_PENDING_JOINERS of
                false -> {keep_state, D};   %% table full of strangers: drop — no state, no link-allow
                true  ->
                    %% store ONLY the validated role tag (member|replica) — NOT arbitrary args;
                    %% never retain attacker terms. The tag decides voter-track vs read-replica.
                    D1 = D#d{pending_joiners = (D#d.pending_joiners)#{J => #{as => join_as(Args)}}},
                    case maps:is_key(J, D1#d.admitting) of
                        true  -> {keep_state, D1};   %% a proof for J is already running
                        false ->
                            %% cap concurrent proofs (each spawns a process + a can_join prove);
                            %% past the cap J retries next tick and gets a slot as the ≤N drain.
                            case maps:size(D1#d.admitting) < ?MAX_ADMITTING of
                                true  -> {keep_state, start_admission(J, D1)};
                                false -> {keep_state, D1}
                            end
                    end
            end
    end;
%% Not the leader: point the joiner at the leader we know (it retries there next tick). The
%% redirect reply dials J back, which needs J in pending_joiners for link_allowed. Unlike the
%% leader branch, a follower has nothing to PIN here (it doesn't admit) — its pending_joiners is
%% only transient permission to dial a redirect. So EVICT-to-make-room when full (memory still
%% bounded by the cap; an evicted entry's joiner simply re-asks), rather than refuse — else a
%% flood would silently stop the follower from redirecting any new (legit) joiner to the leader.
dispatch_join_request(_State, _Peer, #join_request{joiner = J}, D) ->
    PJ0 = D#d.pending_joiners,
    PJ1 = case maps:is_key(J, PJ0) orelse maps:size(PJ0) < ?MAX_PENDING_JOINERS of
              true  -> PJ0;
              false -> evict_one(PJ0)
          end,
    D1 = D#d{pending_joiners = PJ1#{J => #{}}},
    %% the joiner dials an ENDPOINT, so resolve the leader's node_id → its address (or `none`
    %% if we don't know the leader / its address yet — the joiner keeps asking on its timer).
    {keep_state, send_raft(J, #join_reply{result = {redirect, leader_endpoint(D)}}, D1)}.

%% Resolve the known leader's node_id to a dialable endpoint for a redirect (none if unknown).
leader_endpoint(#d{leader_id = none}) -> none;
leader_endpoint(#d{leader_id = L}) ->
    case quod_quic:resolve(L) of {ok, Ep} -> Ep; error -> none end.

%% Drop one (arbitrary) entry to make room — only for the follower's transient redirect table.
%% maps:iterator/next picks one without materialising all keys.
evict_one(M) ->
    case maps:next(maps:iterator(M)) of
        none          -> M;
        {K, _V, _Itr} -> maps:remove(K, M)
    end.

%% Hand the (possibly slow) admission proof to a throwaway helper and return at once, so the
%% leader keeps heartbeating. The helper proves can_join and messages the yes/no verdict back;
%% `admitting` marks J in-flight (by the helper's MONITOR ref) so a retrying joiner doesn't spawn
%% a second proof. spawn_monitor (not bare spawn) so that if the helper is KILLED before it
%% reports, the `DOWN` frees the marker — else a dead helper would wedge J out forever.
start_admission(J, D = #d{ns = Ns}) ->
    Self = self(),
    {_Pid, Ref} = spawn_monitor(fun() -> Self ! {join_decision, J, allowed_to_join(J, Ns)} end),
    D#d{admitting = (D#d.admitting)#{J => Ref}}.

%% The helper's verdict arrived. Clear the marker (demonitor with flush — eats the helper's
%% impending normal-exit DOWN), then admit/refuse — but only if we are STILL the leader and J
%% hasn't become a member meanwhile (a stale verdict after step-down or a duplicate is dropped).
handle_join_decision(J, Allowed, D0) ->
    _ = case maps:get(J, D0#d.admitting, undefined) of
            R when is_reference(R) -> erlang:demonitor(R, [flush]);
            _                      -> ok
        end,
    D = D0#d{admitting = maps:remove(J, D0#d.admitting)},
    case D#d.role =:= leader andalso not is_member(J, D) of
        false -> {keep_state, D};
        true  ->
            case Allowed of
                true  -> admit(J, D);
                false ->
                    %% Send a best-effort denial, then DROP J from pending_joiners: a denied node
                    %% never becomes a member, so it would otherwise sit there forever — a flood of
                    %% distinct denied ids would fill the cap and block real joiners. The reply is
                    %% informational only (the joiner retries on its own timer regardless).
                    D1 = send_raft(J, #join_reply{result = {denied, can_join_failed}}, D),
                    {keep_state, D1#d{pending_joiners = maps:remove(J, D1#d.pending_joiners)}}
            end
    end.

%% An admission helper died WITHOUT reporting (killed mid-proof): drop its `admitting` marker so
%% the joiner can retry. A normal completion never reaches here — handle_join_decision demonitors
%% with [flush] first. (A normal-exit DOWN that races ahead is harmless: it only clears a marker
%% the imminent join_decision would clear anyway.)
drop_admitting_by_ref(Ref, D = #d{admitting = A}) ->
    D#d{admitting = maps:filter(fun(_J, R) -> R =/= Ref end, A)}.

%% A well-formed node id: a 32-byte Ed25519 pubkey, OR (the no-identity/test path, transitional)
%% a dialable endpoint. Guards the join path so a malformed id can't crash the leader.
valid_node_id(Id) when is_binary(Id), byte_size(Id) =:= 32 -> true;
valid_node_id(Id) -> valid_endpoint(Id).

%% A dialable endpoint: a {Host, Port} with a string/binary host and an in-range port.
valid_endpoint({Host, Port}) when is_integer(Port), Port > 0, Port =< 65535 ->
    is_list(Host) orelse is_binary(Host);
valid_endpoint(_) -> false.

%% Route an approved joiner to the voter-track (learner→promote) or the read-replica track,
%% per the role tag we recorded (validated to member|replica) when its request arrived.
admit(J, D) ->
    case maps:get(as, maps:get(J, D#d.pending_joiners, #{}), member) of
        replica -> admit_replica(J, D);
        _       -> admit_learner(J, D)
    end.

%% The validated role tag from a join_request's args — ONLY the atom `replica` or `member`,
%% never any other attacker-supplied key/term. `args` is typed map() but arrives over a
%% non-[safe] decode, so a hostile message could carry a non-map — maps:get throws, we default.
join_as(Args) ->
    try maps:get(as, Args, member) of
        replica -> replica;
        _       -> member
    catch _:_ -> member end.

%% Joiner side: react to the leader's disposition — but ONLY while we are still joining (not yet a
%% COMMITTED member). An established voter/learner/leader ignores join_replies entirely: it must
%% never take a stranger's word for who the leader is (a leader trusting a forged redirect about
%% its own leadership is the hostile-net hole). The real membership state arrives via the
%% replicated config entries; replies only steer who a *joining* node asks next.
%% (Authenticating a redirect — vs. merely bounding it — is the signing layer's job; until then a
%% redirect is bounded only by the MAX_CONTACTS cap below.)
handle_join_reply(Peer, Reply, D) ->
    case is_member(D#d.self, committed_view(D)) of
        true  -> {keep_state, D};   %% already a committed member: the join handshake is over
        false -> handle_join_reply_active(Peer, Reply, D)
    end.

handle_join_reply_active(_Peer, #join_reply{result = {redirect, none}}, D) ->
    {keep_state, D};   %% contact has no leader yet — keep asking on the join timer
handle_join_reply_active(_Peer, #join_reply{result = {redirect, Leader}}, D) ->
    %% `Leader` is an ENDPOINT (the leader's resolved address). Follow the hint, but
    %% REFUSE-beyond-cap so a redirect flood can't grow contacts unbounded (contacts feeds both the
    %% dial fan-out and link_allowed/2). Config seeds are never evicted.
    Known = lists:member(Leader, D#d.contacts),
    %% Add the leader's endpoint to `contacts` so the joiner dials it next tick. We do NOT set
    %% `leader_id` (that is a node_id/pubkey, learned from the committed config once admitted) —
    %% the redirect only tells us WHERE to ask, not the leader's identity.
    case valid_endpoint(Leader) andalso (Known orelse length(D#d.contacts) < ?MAX_CONTACTS) of
        true  -> {keep_state, D#d{contacts = lists:usort([Leader | D#d.contacts])}};
        false -> {keep_state, D}
    end;
handle_join_reply_active(_Peer, #join_reply{result = {denied, Reason}}, D) ->
    logger:warning("quod[~s]: join denied (~p) — will retry", [D#d.ns, Reason]),
    {keep_state, D};   %% the admission rule may change; the join timer keeps retrying
handle_join_reply_active(_Peer, #join_reply{result = _Admitted}, D) ->
    {keep_state, D}.   %% learner_admitted / already_member: AppendEntries drives catch-up + promote

%% Admit a non-voting member J. `{add_learner, J}` = a joiner to be promoted once caught up;
%% `{add_replica, J}` = a permanent read-replica that is never promoted (learner_target/2 returns
%% `none` for it). Both: adopt-on-append (J enters the replication set at once, caught up from the
%% start of the log via the existing back-up loop). A sole founder (quorum 1) commits the entry
%% here, which also gives the leader the current-term commit the promote gate later requires.
admit_learner(J, D) -> admit_nonvoter(J, {add_learner, J}, D).
admit_replica(J, D) -> admit_nonvoter(J, {add_replica, J}, D).

admit_nonvoter(J, Op, D) ->
    I  = last_log_index(D) + 1,
    E  = #entry{index = I, term = D#d.cur_term, kind = config, data = Op},
    {ok, Store1} = quod_ledger_store:append(D#d.store, [E]),
    D1 = with_log(D#d.log ++ [E],
                  D#d{store = Store1,
                      %% J is now a member ⇒ covered by membership in link_allowed; drop it from
                      %% pending_joiners so the anti-flood table only holds not-yet-admitted joiners.
                      pending_joiners = maps:remove(J, D#d.pending_joiners),
                      next_index  = (D#d.next_index)#{J => D#d.snap_idx + 1},  %% fresh log ⇒ send from the start
                      match_index = (D#d.match_index)#{J => 0}}),
    D2 = case quorum(D1) of 1 -> ack_pending(advance_commit(D1)); _ -> D1 end,
    logger:info("quod[~s]: admitted ~p as ~p (index ~p)", [D#d.ns, J, element(1, Op), I]),
    D3 = send_raft(J, #join_reply{result = learner_admitted}, D2),
    {keep_state, D3, [{next_event, internal, replicate}, {next_event, internal, run_apply}]}.

%% A learner that has caught up to its target is promoted to a voter — but only under the
%% full single-server safety gate: no config change already in flight, AND a current-term
%% commit exists (else the published cross-term membership bug can lose a committed entry).
%% The target is DERIVED from the log (learner_target/2), so a restarted or newly-elected
%% leader recovers it and never strands a half-admitted learner.
maybe_promote_learner(Peer, D) ->
    case learner_target(Peer, D) of
        none   -> D;   %% not a pending learner (a voter, or already promoted/removed)
        Target ->
            Reached = maps:get(Peer, D#d.match_index, 0) >= Target,
            case Reached andalso (not cfg_uncommitted(D)) andalso has_current_term_commit(D) of
                true  -> append_promote(Peer, D);
                false -> D
            end
    end.

append_promote(Peer, D) ->
    I  = last_log_index(D) + 1,
    E  = #entry{index = I, term = D#d.cur_term, kind = config, data = {promote, Peer}},
    {ok, Store1} = quod_ledger_store:append(D#d.store, [E]),
    D1 = with_log(D#d.log ++ [E],
                  D#d{store = Store1,
                      pending_joiners = maps:remove(Peer, D#d.pending_joiners)}),
    logger:info("quod[~s]: promoted ~p to voter (committee ~p)", [D#d.ns, Peer, derive_committee(D1)]),
    %% Now a voter: quorum may grow, so the promote commits once the new voter acks it (a
    %% 2-node committee needs both). The 1-voter branch only fires if the set didn't grow.
    case quorum(D1) of 1 -> ack_pending(advance_commit(D1)); _ -> D1 end.

%% The ontology's admission rule, proved against the committed kb. Default-open `can_join`
%% lives in the root genesis; a false/unknown rule (or an engine not yet ready) denies and
%% the joiner retries. `Joiner` is the joiner's node_id (its pubkey — already proven via the
%% possession bind), so an ontology can narrow `can_join` to a pubkey allowlist.
%% Runs in the helper process (start_admission), so a long prove never blocks the leader.
allowed_to_join(Joiner, Ns) ->
    Goal = {can_join, Ns, joiner_term(Joiner), none},
    case quod_prolog:prove(Ns, Goal, Ns) of   %% prove catches exits itself, returning fail
        {ok, [_ | _], _} -> true;
        _                -> false
    end.

%% Make the joiner id a Prolog-safe term: a pubkey is a binary (fine); an endpoint id is
%% passed as the LIST `[Host, Port]`, never the `{Host, Port}` tuple — erlog reads a tuple as
%% a compound term whose functor must be a callable atom, and a string host is not (crash).
joiner_term({Host, Port}) -> [Host, Port];
joiner_term(Pubkey)       -> Pubkey.

%%%===================================================================
%%% client append + commit + apply
%%%===================================================================

handle_client_append(From, Change, D) ->
    case maps:size(D#d.pending) >= maps:get(max_pending, D#d.cfg) of
        true -> {keep_state, D, [{reply, From, {error, busy}}]};
        false ->
            I = last_log_index(D) + 1,
            E = #entry{index = I, term = D#d.cur_term, kind = block, data = Change},
            {ok, Store1} = quod_ledger_store:append(D#d.store, [E]),   %% DURABLE before counting own log
            D1 = with_log(D#d.log ++ [E],
                          D#d{store = Store1, appends = D#d.appends + 1,
                              pending = (D#d.pending)#{I => From}}),
            %% From is replied {ok, I} from the commit step (1-voter commits here; multi-voter
            %% on a majority AE reply), never here — see the module doc.
            D2 = case quorum(D1) of 1 -> ack_pending(advance_commit(D1)); _ -> D1 end,
            {keep_state, D2, [{next_event, internal, replicate}, {next_event, internal, run_apply}]}
    end.

%% PURE: advance commit_index to the highest N a majority replicated AND of the current
%% term (the Figure-8 guard — a prior-term entry commits only indirectly, once a
%% current-term entry above it commits). Self always counts toward the majority.
advance_commit(D = #d{commit_index = C, cur_term = CT, match_index = MI}) ->
    LLI    = last_log_index(D),
    Peers  = voter_peers(D),  %% commit majority is over VOTERS only (a learner's match_index
    Quorum = quorum(D),       %% never counts); invariant within the call — derive once
    Ns = [N || N <- lists:seq(C + 1, LLI),
               (1 + length([P || P <- Peers, maps:get(P, MI, 0) >= N])) >= Quorum,
               term_at(N, D) =:= CT],
    case Ns of [] -> D; _ -> D#d{commit_index = lists:max(Ns)} end.

%% Reply {ok, I} to every client append now committed; the OCC verdict still arrives via
%% quod_prolog's park/release. The ack unblocks a quod_prolog waiting in append/2.
ack_pending(D = #d{pending = P, commit_index = CI}) ->
    {Ack, Keep} = maps:fold(fun(I, From, {A, K}) ->
                                case I =< CI of true -> {[{I, From} | A], K}; false -> {A, K#{I => From}} end
                            end, {[], #{}}, P),
    _ = [gen_statem:reply(From, {ok, I}) || {I, From} <- Ack],
    D#d{pending = Keep}.

fail_pending(D = #d{pending = P}, Hint) ->
    _ = [gen_statem:reply(From, {error, not_in_charge, Hint}) || {_I, From} <- maps:to_list(P)],
    D#d{pending = #{}}.

fail_pending_above(CI, D = #d{pending = P, leader_id = L}) ->
    {Fail, Keep} = maps:fold(fun(I, From, {F, K}) ->
                                 case I > CI of true -> {[From | F], K}; false -> {F, K#{I => From}} end
                             end, {[], #{}}, P),
    _ = [gen_statem:reply(From, {error, not_in_charge, L}) || From <- Fail],
    D#d{pending = Keep}.

%% Apply committed-but-unapplied blocks into quod_prolog, in order. Guarded: if there is
%% nothing to apply, or quod_prolog is not up yet (defer; the rebuild handshake re-drives),
%% return unchanged. The registry lookup is done ONCE here, not once per entry in the loop.
apply_committed(D = #d{last_applied = LA, commit_index = CI}) when LA >= CI -> D;
apply_committed(D = #d{ns = Ns}) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> D;
        _         -> apply_loop(D)
    end.

%% Hand EVERY committed entry (block / noop / config) to quod_prolog — config/noop are
%% no-ops there but must still advance its cursor, else a skipped index reads as a gap.
%% apply_block is an ASYNC cast (see quod_prolog: breaks the append<->apply deadlock),
%% delivered in log order on the FIFO cast channel; we advance last_applied optimistically
%% and quod_prolog asks for a rebuild if it ever falls behind. Start above the snapshot
%% point (max/2): a post-rebuild reset can leave last_applied below snap_idx and entry_at
%% only holds the live tail (snap_idx+1..), so without max/2 the keyfind would badmatch.
apply_loop(D = #d{last_applied = LA, commit_index = CI}) when LA >= CI -> D;
apply_loop(D = #d{ns = Ns, last_applied = LA, snap_idx = SI}) ->
    I = max(LA, SI) + 1,
    #entry{data = Data} = entry_at(I, D),
    _ = safe_apply_block(Ns, I, Data),
    apply_loop(D#d{last_applied = I, commits = D#d.commits + 1}).

safe_apply_block(Ns, I, Data) ->
    try quod_prolog:apply_block(Ns, I, Data) catch _:_ -> ok end.

%% Tell quod_prolog its kb is rebuilt and it may serve proves — but only ONCE the
%% committed prefix is actually applied, so a (re)started member never answers from a
%% half-built kb (design §4.6). "Caught up" = applied up to commit_index, AND either the
%% durable log is empty (nothing to rebuild) or commit_index has advanced past the
%% snapshot point (a real commit point was re-learned post-restart, not the reset-to-0).
maybe_mark_ready(D = #d{ns = Ns, prolog_ready = false}) ->
    case (quod_reg:where({quod_prolog, Ns}) =/= undefined) andalso caught_up(D) of
        true  -> _ = try quod_prolog:mark_ready(Ns) catch _:_ -> ok end,
                 D#d{prolog_ready = true};
        false -> D
    end;
maybe_mark_ready(D) -> D.   %% already marked ready

caught_up(D) ->
    D#d.last_applied >= D#d.commit_index
        andalso (D#d.commit_index > D#d.snap_idx orelse last_log_index(D) =:= D#d.snap_idx).

%%%===================================================================
%%% replication loop (leader)
%%%===================================================================

replicate(D) -> lists:foldl(fun replicate_to/2, D, repl_peers(D)).

replicate_to(P, D) ->
    NextI   = maps:get(P, D#d.next_index, last_log_index(D) + 1),
    PrevI   = NextI - 1,
    PrevT   = term_at_or_zero(PrevI, D),
    Entries = log_from(NextI, maps:get(max_batch, D#d.cfg), D),
    AE = #append_entries{term = D#d.cur_term, leader_id = D#d.self,
                         prev_log_index = PrevI, prev_log_term = PrevT,
                         entries = Entries, leader_commit = D#d.commit_index},
    send_raft(P, AE, D).

%% Entries for one AppendEntries, capped by BOTH a count (max_batch) AND encoded BYTES.
%% The byte cap keeps every AE a SINGLE quod_link frame (< ?CHUNK_BYTES): replication
%% never exercises the chunk path (which is reserved for M3 snapshots), so a catch-up of
%% many entries — or a steady stream of fact-bearing blocks — can't build an oversized
%% AE that would otherwise be chunked and dropped at the receiver (stalling replication).
log_from(From, Max, D = #d{log = Log, snap_idx = SI}) ->
    case From > last_log_index(D) of
        true  -> [];   %% caught-up peer / heartbeat: no entries, no traversal (the common case)
        false ->
            %% the log is contiguous snap_idx+1..N, so skip straight to From rather than
            %% scanning from the head, then cap by count and by encoded bytes.
            Window = lists:sublist(nthtail_safe(From - (SI + 1), Log), Max),
            take_under_bytes(Window, ?AE_BATCH_BYTES)
    end.

%% lists:nthtail that returns [] instead of crashing if N exceeds the list length.
nthtail_safe(N, L) when N =< 0 -> L;
nthtail_safe(_, [])            -> [];
nthtail_safe(N, [_ | T])       -> nthtail_safe(N - 1, T).

%% Always take at least one entry (progress even if a single entry exceeds the budget),
%% then add while the cumulative encoded size stays under Budget.
take_under_bytes([], _Budget)         -> [];
take_under_bytes([E | Rest], Budget)  -> take_under_bytes(Rest, Budget - esize(E), [E]).
take_under_bytes([], _Budget, Acc)        -> lists:reverse(Acc);
take_under_bytes([E | Rest], Budget, Acc) ->
    Sz = esize(E),
    case Sz =< Budget of
        true  -> take_under_bytes(Rest, Budget - Sz, [E | Acc]);
        false -> lists:reverse(Acc)
    end.

esize(E) -> byte_size(term_to_binary(E)).

%%%===================================================================
%%% transport / wire (over quod_link, channel = D#d.chan)
%%%===================================================================

inbound(State, Peer, Payload, D0) ->
    D = bump_recv(D0),
    %% A single quod_link frame is at most one ?CHUNK_BYTES chunk part plus its envelope
    %% ({raft|raft_chunk, Ns, …} — the Ns and a make_ref() push the wrapper well past 64);
    %% the headroom must cover the envelope or a full chunk frame (and even a single frame
    %% with a long Ns) is dropped before decode. The real per-message caps are enforced
    %% downstream (?MAX_RAFT_BYTES single-frame, ?MAX_SNAPSHOT_BYTES reassembled).
    case byte_size(Payload) > ?CHUNK_BYTES + 1024 of
        true -> {keep_state, D};
        false ->
            case decode(Payload) of
                {raft, Ns, Bin} when Ns =:= D#d.ns ->
                    dispatch_record(State, Peer, Bin, ?MAX_RAFT_BYTES, D);
                {raft_chunk, Ns, MsgId, Seq, Total, Part} when Ns =:= D#d.ns ->
                    reassemble(State, Peer, MsgId, Seq, Total, Part, D);
                _ -> {keep_state, D}
            end
    end.

%% Decode + route one record. Cap differs by source: a single frame is bounded by
%% ?MAX_RAFT_BYTES; a REASSEMBLED multi-chunk message is legitimately larger (a big AE, or
%% an M3 snapshot) and is bounded only by ?MAX_SNAPSHOT_BYTES (already enforced in reassemble).
dispatch_record(State, Peer, Bin, Max, D) ->
    case byte_size(Bin) =< Max of
        false -> {keep_state, D#d{rx_dropped = D#d.rx_dropped + 1}};
        true  ->
            case decode_record(Bin) of
                error  -> {keep_state, D#d{rx_dropped = D#d.rx_dropped + 1}};
                Record -> route(State, Peer, Record, D)
            end
    end.

route(State, Peer, #request_vote{} = M, D)         -> handle_request_vote(Peer, M, State, D);
route(State, Peer, #request_vote_reply{} = M, D)   -> handle_vote_reply(Peer, M, State, D);
route(State, Peer, #append_entries{} = M, D)       -> handle_append_entries(Peer, M, State, D);
route(State, Peer, #append_entries_reply{} = M, D) -> handle_ae_reply(Peer, M, State, D);
route(State, Peer, #join_request{} = M, D)         -> handle_join_request(State, Peer, M, D);
route(_State, Peer, #join_reply{} = M, D)          -> handle_join_reply(Peer, M, D);
route(_State, _Peer, _Other, D)                    -> {keep_state, D}.   %% install_snapshot etc: M3

%% A corrupt/hostile peer can send Seq/Total that pass framing but are out of range; reject
%% them up front so the completion path (which assumes keys are exactly 1..Total) can never
%% maps:get a missing key and crash the statem (#9).
reassemble(_State, Peer, _MsgId, Seq, Total, _Part, D = #d{rx = Rx})
  when not (is_integer(Total) andalso Total >= 1
            andalso is_integer(Seq) andalso Seq >= 1 andalso Seq =< Total) ->
    {keep_state, D#d{rx = maps:remove(Peer, Rx), rx_dropped = D#d.rx_dropped + 1}};
reassemble(State, Peer, MsgId, Seq, Total, Part, D = #d{rx = Rx}) ->
    Cur = case maps:get(Peer, Rx, undefined) of
              #rx{msg_id = MsgId, total = Total} = R -> R;   %% same in-flight msg (Total must match)
              _ -> #rx{msg_id = MsgId, total = Total, got = #{}, bytes = 0}   %% new msg replaces in-flight
          end,
    %% Count a part's bytes only the FIRST time its Seq is seen — a duplicate Seq (a
    %% link-layer retransmit) overwrites in `got` (map_size unchanged) but would otherwise
    %% double-count toward the size cap and spuriously drop a valid message (#7).
    Bytes1 = case maps:is_key(Seq, Cur#rx.got) of
                 true  -> Cur#rx.bytes;
                 false -> Cur#rx.bytes + byte_size(Part)
             end,
    Got1   = (Cur#rx.got)#{Seq => Part},
    case Bytes1 > ?MAX_SNAPSHOT_BYTES of
        true -> {keep_state, D#d{rx = maps:remove(Peer, Rx), rx_dropped = D#d.rx_dropped + 1}};
        false ->
            case map_size(Got1) =:= Total of
                true ->
                    Bin = iolist_to_binary([maps:get(S, Got1) || S <- lists:seq(1, Total)]),
                    D1  = D#d{rx = maps:remove(Peer, Rx)},
                    dispatch_record(State, Peer, Bin, ?MAX_SNAPSHOT_BYTES, D1);
                false ->
                    {keep_state, D#d{rx = Rx#{Peer => Cur#rx{got = Got1, bytes = Bytes1}}}}
            end
    end.

%% Send to one member on OUR OWN outbound link (dialing if we have none yet). We never
%% transmit on a link a peer opened to us — that "reply backwards on the peer's stream"
%% path is the one that silently goes dead with no DOWN (the phantom). Using only our
%% own outbound stream keeps every directed pair reachable and symmetric, so any node
%% can lead. Until the outbound link's `link_up` flushes it, frames buffer in the outbox —
%% COALESCED to the latest message per peer (not appended): each Raft RPC carries the full
%% current state, so a newer one supersedes any older buffered one, and against a peer that
%% is down (link never comes up) the outbox stays bounded instead of growing every heartbeat.
send_raft(M, Record, D = #d{ns = Ns, conns = Conns, outbox = Outbox}) ->
    Frames = frames(Ns, Record),
    case maps:get(M, Conns, undefined) of
        {LinkPid, _Ref} ->
            _ = [quod_link:send(LinkPid, F) || F <- Frames],
            bump_sent(Frames, D);
        undefined ->
            %% Dial only if no open is already in flight for M. An outbox entry means a
            %% prior send already called open_link and is awaiting link_up; re-dialing
            %% would register a SECOND waiter in quod_conn, which then notifies BOTH with
            %% the same LinkPid — and the duplicate link_up falls into the "already linked"
            %% branch and closes the live link (a self-inflicted DOWN, replication stall).
            %% link_error clears the outbox, so a genuinely-down peer is re-dialed next send.
            _ = case maps:is_key(M, Outbox) of
                    true  -> ok;
                    false -> quod_quic:open_link(M, D#d.chan)
                end,
            bump_sent(Frames, D#d{outbox = Outbox#{M => Frames}})
    end.

frames(Ns, Record) ->
    Bin = encode(Record),
    case byte_size(Bin) =< ?CHUNK_BYTES of
        true  -> [encode({raft, Ns, Bin})];
        false ->
            Parts = chunkify(Bin, ?CHUNK_BYTES),
            Total = length(Parts),
            MsgId = make_ref(),
            [encode({raft_chunk, Ns, MsgId, Seq, Total, P})
             || {Seq, P} <- lists:zip(lists:seq(1, Total), Parts)]
    end.

chunkify(Bin, Size) when byte_size(Bin) =< Size -> [Bin];
chunkify(Bin, Size) ->
    <<Chunk:Size/binary, Rest/binary>> = Bin,
    [Chunk | chunkify(Rest, Size)].

encode(Msg) -> term_to_binary(Msg).

%% The wire ENVELOPE ({raft|raft_chunk, Ns, ...}) carries only known atoms + binaries,
%% so `[safe]` guards it (refuses unknown atoms / fun / pid). The inner RECORD, though,
%% is an `#append_entries{}` carrying a `#transaction{}` whose diff holds arbitrary Prolog
%% clauses — i.e. atoms the receiver has not seen yet (the fact's own functor/args). With
%% `[safe]` those legitimately-new atoms are refused and every fact-bearing AppendEntries
%% is dropped, so a follower can never apply a new fact (it only learns the atom by
%% applying). The payload therefore decodes WITHOUT `[safe]`. That is safe for M2's trusted
%% single-operator committee; the size cap (?MAX_RAFT_BYTES) still bounds it, and a real
%% identity/BFT layer (later) re-tightens this with signed, validated changes.
decode(Bin)        -> try binary_to_term(Bin, [safe]) of T -> T catch _:_ -> error end.
decode_record(Bin) -> try binary_to_term(Bin) of T -> T catch _:_ -> error end.

bump_sent(Frames, D) ->
    Bytes = lists:sum([byte_size(F) || F <- Frames]),
    D#d{msgs_sent = D#d.msgs_sent + 1, chunks_sent = D#d.chunks_sent + length(Frames),
        bytes_sent = D#d.bytes_sent + Bytes}.

bump_recv(D) -> D#d{msgs_recv = D#d.msgs_recv + 1}.

flush_outbox(Peer, LinkPid, D = #d{outbox = Outbox}) ->
    case maps:get(Peer, Outbox, []) of
        []     -> D;
        Frames -> _ = [quod_link:send(LinkPid, F) || F <- Frames],
                  D#d{outbox = maps:remove(Peer, Outbox)}   %% sent; heartbeat re-sends if the link dies
    end.

drop_conn_by_pid(LinkPid, D = #d{conns = Conns}) ->
    case [P || {P, {Pid, _}} <- maps:to_list(Conns), Pid =:= LinkPid] of
        [Peer | _] ->
            {_Pid, Ref} = maps:get(Peer, Conns),
            _ = erlang:demonitor(Ref, [flush]),
            D#d{conns = maps:remove(Peer, Conns)};
        [] -> D
    end.

%%%===================================================================
%%% log + committee helpers
%%%===================================================================

%% Replace #d.log and refresh the cached tail (index/term) in one place, so every
%% last_log_index/last_log_term read is O(1). All log mutations MUST go through this.
with_log(Log, D) ->
    {LI, LT} = case Log of
                   []  -> {D#d.snap_idx, D#d.snap_term};
                   _   -> E = lists:last(Log), {E#entry.index, E#entry.term}
               end,
    D#d{log = Log, last_idx = LI, last_term = LT}.

last_log_index(#d{last_idx = LI})  -> LI.

last_log_term(#d{last_term = LT}) -> LT.

entry_at(I, #d{log = Log}) -> lists:keyfind(I, #entry.index, Log).

term_at(0, _D)                              -> 0;
term_at(I, #d{snap_idx = I, snap_term = T}) -> T;
term_at(I, D) ->
    case entry_at(I, D) of
        #entry{term = T} -> T;
        false            -> undefined
    end.

term_at_or_zero(I, D) -> case term_at(I, D) of undefined -> 0; T -> T end.

up_to_date(CandT, CandI, MyT, MyI) ->
    CandT > MyT orelse (CandT =:= MyT andalso CandI >= MyI).

%% The VOTERS — the consensus quorum + election set. `{add}` seeds a founding voter,
%% `{promote}` turns a learner into one, `{remove}` drops a member. `{add_learner}` does
%% NOT add a voter. snap_cfg (the committee as of a snapshot) is voters-only.
derive_committee(#d{snap_cfg = Base, log = Log}) ->
    lists:foldl(fun(#entry{kind = config, data = {add, S}}, Acc)     -> [S | Acc -- [S]];
                   (#entry{kind = config, data = {promote, S}}, Acc) -> [S | Acc -- [S]];
                   (#entry{kind = config, data = {remove, S}}, Acc)  -> Acc -- [S];
                   (_, Acc) -> Acc
                end, Base, Log).

%% The LEARNERS — non-voting members the leader replicates to so they can catch up
%% before promotion. `{add_learner}` admits one; `{promote}`/`{remove}` removes it from
%% the learner set. Learners live only in the live log (snapshotting them is M3).
%% Learners AND read-replicas — both are non-voting members the leader replicates to (so
%% repl_peers feeds them + link_allowed admits them). The difference is only promotion:
%% an {add_learner} has a learner_target and is promoted once caught up; an {add_replica} has
%% none and stays a non-voting full-copy replica forever (learner_target/2 returns `none` for
%% it, so maybe_promote_learner no-ops — no change to the promote gate).
derive_learners(#d{log = Log}) ->
    lists:foldl(fun(#entry{kind = config, data = {add_learner, S}}, Acc) -> [S | Acc -- [S]];
                   (#entry{kind = config, data = {add_replica, S}}, Acc) -> [S | Acc -- [S]];
                   (#entry{kind = config, data = {promote, S}}, Acc)     -> Acc -- [S];
                   (#entry{kind = config, data = {remove, S}}, Acc)      -> Acc -- [S];
                   (_, Acc) -> Acc
                end, [], Log).

%% A #d view whose log is only the COMMITTED (locked-in) prefix — entries at or below
%% commit_index. snap_cfg is committed by construction, so derive_committee/derive_learners over
%% this view yield the COMMITTED voter/learner sets. A committed membership entry is never
%% truncated, so a joiner that appears here is permanently in — the safe point to stop asking
%% (join_tick) and the boundary past which it ignores join_replies.
committed_view(D = #d{log = Log, commit_index = CI}) ->
    D#d{log = [E || E <- Log, E#entry.index =< CI]}.

%% The catch-up index a pending learner must reach before it can be promoted = the index of
%% its {add_learner} entry, cleared by a later {promote}/{remove}. DERIVED from the log (not
%% a volatile per-leader note) so a new or restarted leader recomputes every pending
%% learner's target and never strands one. `none` ⇒ Peer is not a pending learner (an
%% ordinary voter, or already promoted/removed).
learner_target(Peer, #d{log = Log}) ->
    lists:foldl(fun(#entry{kind = config, data = {add_learner, S}, index = I}, _) when S =:= Peer -> I;
                   (#entry{kind = config, data = {promote, S}}, _) when S =:= Peer -> none;
                   (#entry{kind = config, data = {remove, S}}, _)  when S =:= Peer -> none;
                   (_, Acc) -> Acc
                end, none, Log).

%% Replication targets (AppendEntries / next_index) = voters ∪ learners, minus self.
repl_peers(D)  -> (derive_committee(D) ++ derive_learners(D)) -- [D#d.self].
%% Vote + commit-majority peers = voters only, minus self. A learner never votes and its
%% match_index never counts toward the commit majority (that is what "non-voting" means).
voter_peers(D) -> derive_committee(D) -- [D#d.self].
quorum(D)      -> (length(derive_committee(D)) div 2) + 1.

is_voter(Node, D)  -> lists:member(Node, derive_committee(D)).
is_member(Node, D) -> is_voter(Node, D) orelse lists:member(Node, derive_learners(D)).

%% A node may keep an inbound/outbound {log,Ns} link iff it is a current member (voter or
%% learner), a configured contact (a joiner reaching its seed), or a pending joiner (so the
%% leader can dial it back to admit/redirect). Anyone else is closed — links are scoped.
link_allowed(Peer, D) ->
    is_member(Peer, D)
        orelse lists:member(Peer, D#d.contacts)
        orelse maps:is_key(Peer, D#d.pending_joiners).

%% A config change is "uncommitted / in flight" iff some config entry sits above the
%% commit index. Derived (not a flag) so it is always exact: one membership change at a
%% time, and the gate below can never read a stale value.
cfg_uncommitted(#d{log = Log, commit_index = CI}) ->
    lists:any(fun(#entry{kind = config, index = I}) -> I > CI; (_) -> false end, Log).

%% The leader has committed an entry in its CURRENT term (its election no-op, or — for a
%% sole founder that skipped the no-op — the just-committed {add_learner}). Mandatory gate
%% before any voting-set change (promote/remove): the published single-server membership
%% bug needs both this AND one-change-at-a-time. (Adding a non-voting learner needs neither.)
has_current_term_commit(D) -> term_at_or_zero(D#d.commit_index, D) =:= D#d.cur_term.

%%%===================================================================
%%% misc
%%%===================================================================

data_dir(Cfg) ->
    case maps:get(data_dir, Cfg) of
        undefined -> filename:join(filename:basedir(user_cache, "quod"), "data");
        Dir       -> Dir
    end.

status_map(D) ->
    #{role => D#d.role, term => D#d.cur_term, leader => D#d.leader_id,
      commit_index => D#d.commit_index, last_applied => D#d.last_applied}.

stats_map(D) ->
    #{cur_term => D#d.cur_term, commit_index => D#d.commit_index,
      last_applied => D#d.last_applied, log_len => length(D#d.log),
      committee_size => length(derive_committee(D)),
      is_leader => (D#d.role =:= leader), role => D#d.role,
      elections => D#d.elections, appends => D#d.appends, commits => D#d.commits,
      pending_appends => maps:size(D#d.pending), snapshots_installed => 0,
      msgs_sent => D#d.msgs_sent, msgs_recv => D#d.msgs_recv,
      bytes_sent => D#d.bytes_sent, chunks_sent => D#d.chunks_sent, rx_dropped => D#d.rx_dropped}.

-ifdef(TEST).
%% Build a #d{} for unit-testing the pure helpers (the record is private). Only the
%% fields the pure functions read are settable; the rest take their record defaults.
mk_d(Opts) ->
    Self = maps:get(self, Opts, {"h", 0}),
    D = #d{ns = <<"t">>, self = Self, cfg = ?DEFAULTS, chan = <<>>, store = undefined,
           cur_term     = maps:get(cur_term, Opts, 0),
           snap_idx     = maps:get(snap_idx, Opts, 0),
           snap_term    = maps:get(snap_term, Opts, 0),
           snap_cfg     = maps:get(snap_cfg, Opts, []),
           commit_index = maps:get(commit_index, Opts, 0),
           match_index  = maps:get(match_index, Opts, #{})},
    with_log(maps:get(log, Opts, []), D).   %% sets log + the cached tail (last_idx/last_term)

commit_index(#d{commit_index = C}) -> C.
-endif.
