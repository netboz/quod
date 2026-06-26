-module(quod_log).
-moduledoc """
Per-namespace **Raft** committee member: orders and replicates the ontology's
block list (the durable history), and drives committed blocks into `quod_prolog`.
One `gen_statem` per namespace; states `follower` | `candidate` | `leader`.

**Milestone M1 scope:** the single-voter degenerate case — committee `[self]`,
quorum 1, no networking. A node becomes leader immediately, commits each append on
its local `fsync`, and applies in order. The states, the durable-before-reply
ordering, the commit rule, and the apply loop are all real, so M2 adds the
RequestVote/AppendEntries wire path and multi-voter commit *without* changing the
commit/apply/persist core. See `doc/ordering-layer-spec.md` §1.

**Deadlock-free append→apply:** `append/2` replies `{ok, Index}` once the entry is
durable + committed, then a *deferred* internal event runs the apply loop — so a
`quod_prolog` blocked inside `append/2` is free to service the `apply_block/3`
call that follows.
""".
-behaviour(gen_statem).
-include("quod_log.hrl").

-export([start_link/2, append/2, rebuild/1, status/1, committee/1, stats/1, namespaces/0]).
-export([init/1, callback_mode/0, terminate/3]).
-export([follower/3, candidate/3, leader/3]).

-define(DEFAULTS, #{node_id => undefined, mode => create, data_dir => undefined}).

-record(d, {ns        :: binary(),
            self      :: server_id(),
            cfg       :: map(),
            store     :: quod_log_store:handle(),
            role      = follower :: follower | candidate | leader,
            %% persisted (reloaded on restart)
            cur_term  = 0    :: term_no(),
            voted_for = none :: server_id() | none,
            log       = []   :: [#entry{}],       %% indices snap_idx+1 .. N, the durable block list
            snap_idx  = 0    :: log_index(),
            snap_term = 0    :: term_no(),
            %% volatile
            commit_index = 0 :: log_index(),
            last_applied = 0 :: log_index(),
            leader_id    = none :: server_id() | none,
            %% counters
            elections = 0, appends = 0, commits = 0}).

callback_mode() -> state_functions.

%%%===================================================================
%%% API
%%%===================================================================

start_link(Ns, Config) ->
    gen_statem:start_link(quod_reg:via({quod_log, Ns}), ?MODULE, {Ns, Config}, []).

-doc "Submit a change. Returns once committed (verdict reaches the caller via `quod_prolog`).".
-spec append(binary(), #change{}) ->
        {ok, log_index()} | {error, not_in_charge, server_id() | none | unavailable}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_log, Ns}), {append, Change}, 5000)
    catch exit:_ -> {error, not_in_charge, unavailable} end.

-doc "Ask the log to (re)drive committed blocks into a freshly-started `quod_prolog`.".
-spec rebuild(binary()) -> ok.
rebuild(Ns) -> gen_statem:cast(quod_reg:via({quod_log, Ns}), rebuild).

status(Ns)    -> call(Ns, get_status, #{}).
committee(Ns) -> call(Ns, get_committee, []).
stats(Ns)     -> call(Ns, get_stats, undefined).

namespaces() -> gproc:select([{{{n, l, {quod_log, '$1'}}, '_', '_'}, [], ['$1']}]).

call(Ns, Req, Default) ->
    try gen_statem:call(quod_reg:via({quod_log, Ns}), Req, 1000) catch exit:_ -> Default end.

%%%===================================================================
%%% init
%%%===================================================================

init({Ns, Config}) ->
    Cfg     = maps:merge(?DEFAULTS, Config),
    Self    = maps:get(node_id, Cfg),
    DataDir = data_dir(Cfg),
    {ok, Store} = quod_log_store:open(Ns, DataDir),
    L = quod_log_store:load(Store),
    D = #d{ns = Ns, self = Self, cfg = Cfg, store = Store,
           cur_term  = maps:get(cur_term, L),
           voted_for = maps:get(voted_for, L),
           log       = maps:get(log, L),
           snap_idx  = maps:get(snap_idx, L),
           snap_term = maps:get(snap_term, L)},
    {ok, follower, D, [{next_event, internal, try_elect}]}.

%%%===================================================================
%%% states
%%%===================================================================

follower(internal, try_elect, D) ->
    %% M1: a 1-voter committee wins instantly; M2 arms a randomized election timer.
    case quorum(D) of
        1 -> become_leader(D);
        _ -> {keep_state, D}
    end;
follower({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, D#d.leader_id}}]};
follower(EventType, Event, D) -> common(EventType, Event, D).

candidate({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, none}}]};
candidate(EventType, Event, D) -> common(EventType, Event, D).

leader({call, From}, {append, Change}, D) ->
    I  = last_log_index(D) + 1,
    E  = #entry{index = I, term = D#d.cur_term, kind = block, data = Change},
    {ok, Store1} = quod_log_store:append(D#d.store, [E]),   %% DURABLE before counting toward commit
    D1 = advance_commit(D#d{store = Store1, log = D#d.log ++ [E], appends = D#d.appends + 1}),
    {keep_state, D1, [{reply, From, {ok, I}}, {next_event, internal, run_apply}]};
leader(EventType, Event, D) -> common(EventType, Event, D).

%%%===================================================================
%%% shared
%%%===================================================================

common(internal, run_apply, D) ->
    {keep_state, apply_loop(D)};
common(cast, rebuild, D) ->
    %% a freshly-(re)started quod_prolog: re-drive committed blocks from the snapshot
    %% point, then signal it ready to serve proves. apply_block is idempotent and
    %% self-correcting (see apply_loop), so this needs no cross-process reset.
    D1 = apply_loop(D#d{last_applied = D#d.snap_idx}),
    _ = catch quod_prolog:mark_ready(D#d.ns),
    {keep_state, D1};
common({call, From}, get_status, D) ->
    {keep_state, D, [{reply, From, status_map(D)}]};
common({call, From}, get_committee, D) ->
    {keep_state, D, [{reply, From, members(D)}]};
common({call, From}, get_stats, D) ->
    {keep_state, D, [{reply, From, stats_map(D)}]};
common(_EventType, _Event, D) ->
    {keep_state, D}.

terminate(_Reason, _State, #d{store = Store}) when Store =/= undefined ->
    catch quod_log_store:close(Store), ok;
terminate(_, _, _) -> ok.

%%%===================================================================
%%% leader election (M1: self-elect)
%%%===================================================================

become_leader(D) ->
    T = D#d.cur_term + 1,
    ok = quod_log_store:write_meta(D#d.store, T, D#d.self),   %% DURABLE before leading
    %% 1-voter: every fsync'd entry was committed (quorum 1), so on restart the whole
    %% reloaded log is committed.
    CI = last_log_index(D),
    D1 = D#d{role = leader, cur_term = T, voted_for = D#d.self, leader_id = D#d.self,
             commit_index = CI, elections = D#d.elections + 1},
    logger:info("quod[~s]: leader at term ~p (committee ~p)", [D#d.ns, T, members(D1)]),
    %% Startup apply is driven solely by the rebuild handshake; new appends drive it
    %% from then on.
    %% REVIEW(M2): a multi-voter leader must append one current-term `noop` block here
    %% (the Figure-8 commit anchor). At 1-voter there are no prior-term uncommitted
    %% entries, so commit_index = last_log_index is sound and the noop is unnecessary.
    {next_state, leader, D1}.

%%%===================================================================
%%% commit + apply
%%%===================================================================

%% Advance commit_index to the highest N (> commit_index) replicated by a majority
%% AND of the current term (the Figure-8 guard). For 1-voter, self is the majority.
advance_commit(D = #d{commit_index = C}) ->
    LLI = last_log_index(D),
    Ns = [N || N <- lists:seq(C + 1, LLI),
               replicated_majority(N, D),
               term_at(N, D) =:= D#d.cur_term],
    case Ns of
        [] -> D;
        _  -> D#d{commit_index = lists:max(Ns)}
    end.

replicated_majority(_N, D) ->
    %% M1: peers = []; self counts as 1 >= quorum(1). M2: + peers with match_index >= N.
    1 >= quorum(D).

%% Apply committed-but-unapplied blocks into quod_prolog, in order. Guarded: if
%% quod_prolog is not up yet, apply nothing now (the rebuild handshake re-drives).
apply_loop(D = #d{last_applied = LA, commit_index = CI}) when LA >= CI -> D;
apply_loop(D = #d{ns = Ns, last_applied = LA}) ->
    case quod_reg:where({quod_prolog, Ns}) of
        undefined -> D;   %% quod_prolog not up yet; apply later via the rebuild handshake
        _ ->
            I = LA + 1,
            #entry{kind = Kind, data = Data} = entry_at(I, D),
            case Kind of
                config -> apply_loop(D#d{last_applied = I});   %% M1: no membership entries
                block  ->
                    case safe_apply_block(Ns, I, Data) of
                        ok                     -> apply_loop(D#d{last_applied = I, commits = D#d.commits + 1});
                        {reject, conflict}     -> apply_loop(D#d{last_applied = I}); %% consumed, no commit
                        {behind, A} when A < I -> apply_loop(D#d{last_applied = A}); %% resync, re-drive A+1..
                        {error, _R}            -> D    %% apply failed; retry on next append/rebuild
                    end
            end
    end.

safe_apply_block(Ns, I, Data) ->
    try quod_prolog:apply_block(Ns, I, Data)
    catch _:_ -> {error, apply_block_failed} end.

%%%===================================================================
%%% log helpers
%%%===================================================================

last_log_index(#d{log = [], snap_idx = S}) -> S;
last_log_index(#d{log = Log})              -> (lists:last(Log))#entry.index.

entry_at(I, #d{log = Log}) -> lists:keyfind(I, #entry.index, Log).

term_at(0, _D)                        -> 0;
term_at(I, #d{snap_idx = I, snap_term = T}) -> T;
term_at(I, D) ->
    case entry_at(I, D) of
        #entry{term = T} -> T;
        false            -> undefined
    end.

members(#d{self = Self}) -> [Self].   %% M1: single voter. M2 derives from config entries.
quorum(D) -> (length(members(D)) div 2) + 1.

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
      committee_size => length(members(D)),
      is_leader => (D#d.role =:= leader), role => D#d.role,
      elections => D#d.elections, appends => D#d.appends, commits => D#d.commits}.
