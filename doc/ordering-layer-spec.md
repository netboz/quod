# Ordering layer — Phase 1 build spec (`quod_ledger` / `quod_prolog`)

This document is the single, unified Phase-1 build spec for quod's ordering/content layer, realizing
`doc/content-layer-design.md` §13. The decisions it fixes: a **hand-rolled lean Raft** over `quod_link`
streams (channel `{log, Ns}`), with **no Erlang distribution**; **one committee (one Raft group) per
namespace**; a **full, durable, browsable block list** kept committee-only in this first cut; and an MVP
scope of **own-namespace writes + cross-namespace reads** (foreign writes, BFT, and read-copy fan-out are
out of scope). `quod_ledger` is the per-namespace Raft `gen_statem` that orders and replicates blocks;
`quod_prolog` is its sibling `gen_server` that deterministically applies committed blocks and serves
proofs. Both live under a two-level supervision tree (`quod_ns_sup` → `quod_ns` → `{quod_ledger, quod_prolog}`).

## Module map

```
quod_sup (one_for_one)
├── quod_quic                         (transport, existing)
├── quod_brahms_sup (simple_one_for_one)    membership, unchanged — discovery only
│   └── quod_brahms (per Ns)
├── quod_ns_sup     (simple_one_for_one)    THIS spec — subtree root, {quod_ns_sup, node}
│   └── quod_ns     (per Ns, rest_for_one)  {quod_ns, Ns}
│       ├── quod_ledger    (Ns)                {quod_ledger, Ns}     Raft committee member
│       └── quod_prolog (Ns)                {quod_prolog, Ns}  fact store + prove engine
└── quod_metrics
```

- **`quod_ledger`** — `gen_statem`, one per namespace; orders + agrees on blocks; owns the durable log.
- **`quod_prolog`** — `gen_server`, one per namespace; applies committed blocks; serves `prove`.
- **`quod_ledger_store`** — library module (no process); on-disk persistence for `quod_ledger`.
- **`quod_diff`** — pure library; differ write-set (op-log) + per-functor read-set hashes.
- **`quod_ns`** — per-Ns `rest_for_one` sub-supervisor over `{quod_ledger, quod_prolog}`.
- **`quod_ns_sup`** — `simple_one_for_one` parent of `quod_ns` instances.

**Channel:** `term_to_binary({log, Ns}, [deterministic])` everywhere (the single wire channel, distinct
from Brahms's `{channel, Ns}`).

**Reg keys:** `{quod_ns_sup, node}`, `{quod_ns, Ns}`, `{quod_ledger, Ns}`, `{quod_prolog, Ns}`, plus the
channel property `{channel, term_to_binary({log, Ns}, [deterministic])}`.

**Shared header `include/quod_ledger.hrl`** is the single source of truth for `term_no()`, `log_index()`,
`server_id()`, `clause()`, `op()`, `read_check()`, `#entry{}`, `#transaction{}`, and the six Raft RPC records.
`include/quod_ledger_store.hrl` `-include`s it and defines only the private `#store{}`/`handle()`.

## Table of contents

1. [`quod_ledger` state machine](#1-quod_ledger-state-machine)
2. [Wire protocol over `quod_link`](#2-wire-protocol-over-quod_link)
3. [Persistence (`quod_ledger_store`)](#3-persistence-quod_ledger_store)
4. [`quod_prolog` apply + prove](#4-quod_prolog-apply--prove)
5. [`quod_ns_sup` lifecycle + membership](#5-quod_ns_sup-lifecycle--membership)
6. [Build order + test plan](#6-build-order--test-plan)
7. [Open questions / out of scope for Phase 1](#7-open-questions--out-of-scope-for-phase-1)

---

## Shared header `include/quod_ledger.hrl` (canonical types + records)

Every type and record below is defined **once**, here, and `-include`d by `quod_ledger`, `quod_ledger_store`
(transitively), `quod_prolog`, and tests. Field names are snake_case throughout.

```erlang
%% include/quod_ledger.hrl
-type term_no()   :: non_neg_integer().      %% Raft Term, starts 0
-type log_index() :: non_neg_integer().      %% 0 = empty-log / snapshot sentinel; entries 1..N
-type server_id() :: {inet:hostname(), inet:port_number()}.   %% == Brahms NodeId == {Host,Port}
-type pubkey()    :: binary().               %% Ed25519 public key — the REAL identity (later; see below)

%% a Prolog clause; identity is content only (#1)
-type clause() :: {Head :: term(), Body :: term()}.   %% Body == true for a plain fact

%% the differ's write-set: ordered op-log of asserts/retracts (#3)
-type op() :: {assert, clause()} | {retract, clause()}.

%% read-set: per-functor content hash, per-predicate (#4)
-type read_check() :: #{ {Functor :: atom(), Arity :: non_neg_integer()} => integer() }.

%% the committed change record — FIXED shape (#24).
%% `author`/`sig` are RESERVED for signing (identity readiness, see below): Phase 1
%% sets author = self node id, sig = none, and verification is a pass-through stub.
%% Reserving them now keeps the wire + on-disk format stable when signing turns on.
-record(transaction, {tx_id      :: binary(),            %% unique per transaction (ulid)
                 caller_ns  :: binary(),            %% CallerNs (#5), first-class (#2)
                 diff       :: [op()],              %% concrete asserts/retracts (#25)
                 read_check :: read_check(),        %% what the proof relied on (#24)
                 author     :: server_id(),         %% who submitted it (Phase 1: node id; later: pubkey())
                 sig = none :: binary() | none}).   %% Ed25519 sig over canonical bytes; none in Phase 1

%% Raft log entry (§E.0). `data` is a #transaction{} for blocks (or `noop` for the election marker).
-record(entry, {index :: log_index(),
                term  :: term_no(),
                kind  :: block | config,
                data  :: #transaction{} | noop | {add, server_id()} | {remove, server_id()}}).

%% the six Raft RPC records — exact fields (snake_case)
-record(request_vote,        {term           :: term_no(),
                              candidate_id   :: server_id(),
                              last_log_index :: log_index(),
                              last_log_term  :: term_no()}).
-record(request_vote_reply,  {term         :: term_no(),
                              vote_granted :: boolean()}).
-record(append_entries,      {term           :: term_no(),
                              leader_id      :: server_id(),
                              prev_log_index :: log_index(),
                              prev_log_term  :: term_no(),
                              entries        :: [#entry{}],   %% [] for heartbeat
                              leader_commit  :: log_index()}).
-record(append_entries_reply,{term        :: term_no(),
                              success     :: boolean(),
                              match_index :: log_index()}).   %% success: matched idx; fail: conflict hint
-record(install_snapshot,    {term                :: term_no(),
                              leader_id           :: server_id(),
                              last_included_index :: log_index(),
                              last_included_term  :: term_no(),
                              config              :: [server_id()],   %% committee as of snapshot
                              data                :: binary()}).      %% already term_to_binary'd state
-record(install_snapshot_reply, {term :: term_no()}).
```

`read_check()` values are `erlang:phash2`-style **integers** (one hash per `{Functor, Arity}`), produced by
`quod_diff:functor_hash/3` and compared by `quod_prolog`'s OCC re-check. Producer and validator use the
same integer representation.

### Identity & signing readiness (reserved, stubbed in Phase 1)

Today a committee member's identity *is* its address (`server_id() = {Host, Port}`). That is fine inside one
trusted operator's cluster, but it cannot prove who a computer is, make the history tamper-evident, or
survive a lying member. The real identity will be a **keypair** (a public key as the name, a secret to sign
with), exactly as onbrater did. To avoid a painful format migration, Phase 1 **reserves the slots and leaves
them empty**:

- **`#transaction.author` / `#transaction.sig`** — every change will eventually be signed by its submitter over its
  canonical bytes (`term_to_binary({tx_id, caller_ns, diff, read_check}, [deterministic])`). Phase 1 sets
  `author = self` (the node id), `sig = none`, and `verify_change/2` is a pass-through stub that always
  succeeds. Each `#transaction{}` build site (e.g. §4.5) sets `author = self`; `sig` defaults to `none`. The
  byte-size guard and `tx_id` correlation are unaffected.
- **Identity vs. address.** Later, `server_id()` becomes a **`pubkey()`**, and `{Host, Port}` is demoted to
  "where you dial it," bound to the key by a signed **admission record** (onbrater's `peer_admitted(NodeId,
  Host, Port, Pubkey)`). Committee config entries (`{add, ServerId}`) and `voted_for`/`leader_id` then carry
  the key, not the address. This is a `server_id()`-type swap plus an address-lookup table — not a record
  reshape, because the slots already exist.
- **Block-level proof (BFT only).** Surviving lies *additionally* needs each committed block to carry the
  quorum's signatures (a commit certificate). That is a later `#entry{}` field, **not** reserved now: plain
  crash-fault Raft never uses it, and it appears only with the Byzantine protocol.

**What Phase 1 builds:** a node keypair is generated at boot and persisted, but **not used** — `sign/2` and
`verify_change/2` are pass-through stubs. This keeps the single-operator build simple while making the wire
and disk formats forward-compatible: turning signing on later changes the stubs and the `server_id()` type,
not the record shapes.

---

## 1. `quod_ledger` state machine

> **Module:** `/home/yan/src/quod/src/quod_ledger.erl` — one `gen_statem` per ontology namespace, the committee
> member that orders and agrees on blocks. Hand-rolled lean Raft over `quod_link` streams on channel
> `term_to_binary({log, Ns}, [deterministic])`, no Erlang distribution. It is the `append`/replicate side;
> `quod_prolog` is the `apply`/prove side, driven by this module's commit→apply loop.

### 1.1 Assumptions

1. **`server_id() = NodeId = {Host, Port}`** is the committee-member id used as `voted_for`/`leader_id`/
   `candidate_id` and as map keys — the `quod_quic` NodeId, the only stable channel-addressable id.
2. **Durability is delegated to `quod_ledger_store`** (§3). Every fsync-ordering rule is expressed as "call
   `quod_ledger_store:*` and only on its `ok`/`{ok, Store1}` return send the network reply / count toward
   commit." The handle is threaded through `#d.store`.
3. **`Block` payload is opaque to `quod_ledger`.** The application command is a `#transaction{}` (§ shared header);
   `quod_ledger` carries it as `#entry.data` for `kind=block` and never inspects it. The election no-op is the
   one `block` entry whose `data` is the atom `noop`.
4. **`config` re-derivation is a whole-log fold** (`derive_committee/1`) on every append/truncate touching a
   config entry. Cheap at committee sizes 1/3/5.
5. **InstallSnapshot + compaction arrive in M3**, not M1/M2. Until M3 no compaction occurs and `snap_idx=0`,
   so the §8 "prev_log_index < snap_idx" overlap case never triggers. The `#install_snapshot{}` records are
   defined from the start (harmless) but only sent/received from M3.
6. **Channel binary** `term_to_binary({log, Ns}, [deterministic])` is computed once in `init/1` and cached
   in `#d.chan`.

### 1.2 Behaviour, exports, callback_mode

```erlang
-module(quod_ledger).
-moduledoc """
Per-namespace lean **Raft** committee member: orders and replicates the
ontology's block list over the dedicated `{log, Ns}` `quod_link` channel.
One `gen_statem` per ontology. States `follower` | `candidate` | `leader`.
""".
-behaviour(gen_statem).
-include("quod_ledger.hrl").

%% API
-export([start_link/2,
         append/2, add_member/2, remove_member/2,
         status/1, committee/1, stats/1, namespaces/0,
         replay/1, snapshot/1, history/3]).
%% gen_statem
-export([init/1, callback_mode/0, terminate/3]).
%% states
-export([follower/3, candidate/3, leader/3]).

-ifdef(TEST).
-export([last_log_index/1, last_log_term/1, term_at/2, quorum/1,
         derive_committee/1, up_to_date/4, advance_commit/1,
         truncate_append/2, encode/1, decode/1]).
-endif.

callback_mode() -> [state_functions].
```

`start_namespace/2` does **not** live on `quod_ledger` — it lives on `quod_ns_sup` (§5). `quod_ledger:start_link/2`
is invoked by `quod_ns`.

Each state is `Name(EventType, Event, D)` with a catch-all delegating to a shared `common/3`:

```erlang
follower(EventType, Event, D)  -> common(EventType, Event, D).
candidate(EventType, Event, D) -> common(EventType, Event, D).
leader(EventType, Event, D)    -> common(EventType, Event, D).
```

### 1.3 The `#d{}` record — PERSISTED vs VOLATILE

```erlang
-record(d, {
    %% ---- scaffolding (mirrors quod_brahms #d{}) ----
    ns      :: binary(),
    self    :: server_id(),                    %% own NodeId {Host,Port} (= server_id)
    cfg     :: map(),                          %% maps:merge(?DEFAULTS, Config)
    chan    :: binary(),                       %% term_to_binary({log, Ns}, [deterministic])
    conns   = #{} :: #{server_id() => {pid(), reference(), out | in}}, %% NodeId => {LinkPid,Mon,Origin}
    outbox  = #{} :: #{server_id() => [binary()]},   %% per-peer FIFO queued while a link opens
    rx      = #{} :: #{server_id() => #rx{}},        %% per-peer chunk reassembly (§2)

    %% ================= PERSISTED (fsync via quod_ledger_store before reply) =======
    cur_term  = 0    :: term_no(),
    voted_for = none :: server_id() | none,
    log       = []   :: [#entry{}],            %% index 1..N, no gaps — IS the durable block list
    snap_idx  = 0    :: log_index(),
    snap_term = 0    :: term_no(),
    snap_cfg  = []   :: [server_id()],         %% committee as of snapshot

    %% ================= VOLATILE (reconstructed on restart) =====================
    commit_index = 0 :: log_index(),
    last_applied = 0 :: log_index(),
    next_index   = #{} :: #{server_id() => log_index()},   %% leader only
    match_index  = #{} :: #{server_id() => log_index()},   %% leader only
    votes        = #{} :: #{server_id() => boolean()},     %% candidate: votes this term
    leader_id    = none :: server_id() | none,
    cfg_uncommitted = false :: boolean(),      %% one membership change in flight (#9.1)
    pending      = #{} :: #{log_index() => gen_statem:from()}, %% client appends awaiting commit

    %% ---- handle + metrics ----
    store     :: quod_ledger_store:handle(),
    elections = 0 :: non_neg_integer(),
    appends   = 0 :: non_neg_integer(),
    commits   = 0 :: non_neg_integer(),
    snapshots_installed = 0 :: non_neg_integer(),
    %% transport counters
    msgs_sent   = 0 :: non_neg_integer(),
    msgs_recv   = 0 :: non_neg_integer(),
    bytes_sent  = 0 :: non_neg_integer(),
    chunks_sent = 0 :: non_neg_integer(),
    rx_dropped  = 0 :: non_neg_integer()}).
```

**Persistence contract.** `cur_term`, `voted_for`, `log`, and the snapshot fields are durable, reloaded in
`init/1`. Everything else is rebuilt (`commit_index`/`last_applied` reset to `snap_idx` on restart, then
re-advance from heartbeats / re-application).

```erlang
-define(DEFAULTS,
        #{node_id       => undefined, %% own NodeId; REQUIRED (valid_cfg rejects undefined)
          mode          => create,    %% create | join (§5)
          committee     => [],        %% bootstrap committee; [] ⇒ self-only 1-voter (#18)
          heartbeat_ms  => 150,       %% leader→peers AppendEntries cadence (<< election)
          election_ms   => 1000,      %% base election timeout; randomized to [T, 2T]
          election_jit  => 1.0,
          max_batch     => 256,       %% max #entries per AppendEntries (kept under ?CHUNK_BYTES)
          max_pending   => 1024,      %% backpressure cap on in-flight client appends (M5)
          snapshot_every => 10000,    %% compaction cadence (M3); local policy
          max_snapshot_bytes => (64 bsl 20), %% reassembled snapshot cap (§2)
          data_dir      => undefined}). %% threaded from application:get_env(quod, data_dir)
-define(MAX_FRAME_BYTES, (1 bsl 20)).  %% quod_link hard cap
-define(MAX_RAFT_BYTES,  65536).       %% reassembled cap for non-snapshot msgs (§2)
-define(CHUNK_BYTES,     65536).       %% per-frame chunk payload (§2)
```

### 1.4 `init/1` — load durable state + 1-voter self-bootstrap

```erlang
init({Ns, Config}) ->
    Cfg = maps:merge(?DEFAULTS, Config),
    case valid_cfg(Config, Cfg) of
        {error, Reason} -> {stop, {bad_config, Reason}};
        ok ->
            Self    = maps:get(node_id, Cfg),
            Chan    = term_to_binary({log, Ns}, [deterministic]),
            DataDir = maps:get(data_dir, Cfg),
            quod_reg:subscribe({channel, Chan}),
            {ok, Store} = quod_ledger_store:open(Ns, DataDir),
            D0 = #d{ns = Ns, self = Self, cfg = Cfg, chan = Chan, store = Store},
            D1 = load_or_bootstrap(D0, Cfg),          %% durable reload OR founding config
            D2 = open_committee_links(D1),
            D3 = D2#d{commit_index = D2#d.snap_idx, last_applied = D2#d.snap_idx},
            {ok, follower, D3, [election_timeout(D3)]}
    end.
```

`load_or_bootstrap/2`:

- **Restart path (#29):** `quod_ledger_store:load(Store)` returns `#{cur_term, voted_for, log, snap_idx,
  snap_term, snap_cfg, snap_data}` → populate the PERSISTED fields. Committee is `derive_committee/1`.
- **Founding path (`mode=create`, 1-voter, #18):** store empty AND `committee ∈ {[], [Self]}`. Seed a
  committed `kind=config {add, Self}` (equivalently `snap_cfg = [Self]` with empty log), durable. Yields
  `committee() = [Self]`, `quorum() = 1`. It wins its first election uncontested.
- **`mode=join`:** store empty, **no genesis config**, election timer **not** armed — passive learner until
  it observes the committed `{add, self}` config entry (§5).
- **Multi-member bootstrap:** non-empty `committee` seeds `snap_cfg` to that list, empty log, term 0.

`valid_cfg(RawConfig, MergedCfg) -> ok | {error, Reason}`: rejects `node_id == undefined`, non-binary `Ns`,
non-list `committee`, non-positive timers, `heartbeat_ms >= election_ms`.

### 1.5 Timers

```erlang
election_ms(Cfg) ->
    T = maps:get(election_ms, Cfg), J = maps:get(election_jit, Cfg),
    T + round(rand:uniform() * J * T).
election_timeout(#d{cfg = Cfg})  -> {state_timeout, election_ms(Cfg), election}.
heartbeat_timeout(#d{cfg = Cfg}) -> {state_timeout, maps:get(heartbeat_ms, Cfg), heartbeat}.
```

`follower`/`candidate` arm `{state_timeout, _, election}` (firing → start election; reset on valid
AppendEntries for current term or granting a vote). `leader` arms `{state_timeout, heartbeat_ms, heartbeat}`
and never an election timer. `state_timeout` auto-cancels on any state transition.

### 1.6 RequestVote — request & reply

**Receiver** `handle_request_vote(Peer, #request_vote{} = RV, State, D)`:

1. `RV.term < cur_term` → reply `#request_vote_reply{term=cur_term, vote_granted=false}`, `{keep_state, D}`.
2. `RV.term > cur_term` → `step_down/2` (persist `{cur_term := RV.term, voted_for := none}`), continue at new
   term; resulting transition is to `follower`.
3. Grant iff `voted_for ∈ {none, RV.candidate_id}` **and**
   `up_to_date(RV.last_log_term, RV.last_log_index, last_log_term(D), last_log_index(D))`:
   ```erlang
   up_to_date(CandT, CandI, MyT, MyI) -> CandT > MyT orelse (CandT =:= MyT andalso CandI >= MyI).
   ```
4. **If granting:** `D1 = D#d{voted_for = RV.candidate_id}`, `quod_ledger_store:write_meta(Store, cur_term,
   candidate_id)` — durable — then reply `vote_granted=true`, re-arm election timer, `{next_state, follower,
   D1', [election_timeout(D1')]}`.
5. Else reply `vote_granted=false`.

**Candidate receiving `#request_vote_reply{}`:** ignore if `Reply.term < cur_term` or no longer candidate.
`Reply.term > cur_term` → `step_down`, `{next_state, follower, ...}`. If `vote_granted` → `votes#{Peer =>
true}`; if `count(true votes incl. self) >= quorum(D)` → **become leader** (§1.9).

### 1.7 AppendEntries — request & reply

**Receiver** `handle_append_entries(Peer, #append_entries{} = AE, State, D)`:

1. `AE.term < cur_term` → reply `#append_entries_reply{term=cur_term, success=false, match_index=0}`,
   `{keep_state, D}`.
2. `AE.term > cur_term` → `step_down/2` (persist).
3. Record `leader_id = AE.leader_id` and **transition to follower** (`{next_state, follower, ...}` from any
   prior state — a candidate at equal term steps down to this valid leader), re-arming the election timer.
4. **Consistency check** on `AE.prev_log_index`/`prev_log_term`:
   - `prev_log_index == 0` → OK.
   - `prev_log_index > last_log_index(D)` → fail, reply `match_index = last_log_index(D)`.
   - `prev_log_index == snap_idx` → require `prev_log_term == snap_term`.
   - else `term_at(prev_log_index, D) /= prev_log_term` → fail, reply `match_index = prev_log_index - 1`.
   - On failure: `success=false`, re-arm election timer, stay `follower`.
5. **Truncate + append** (`truncate_append/2`, pure): same-index-different-term existing entry → drop it and
   the tail, append the suffix; same-index-same-term → skip (idempotent, **never truncate on a match**); no
   entry → append. If any touched entry is `kind=config` → re-derive committee, set/clear `cfg_uncommitted`.
   `quod_ledger_store:append(Store, NewEntries)` — durable — before replying `success=true`. On a truncation,
   **fail any `pending` From at an index > commit_index** with `{error, not_in_charge, leader_id}`.
6. **Advance commit:** if `AE.leader_commit > commit_index`, set `commit_index := min(leader_commit,
   index_of_last_NEW_entry)`, then drive apply (§1.10).
7. Reply `#append_entries_reply{term=cur_term, success=true, match_index = prev_log_index +
   length(AE.entries)}`, `{next_state, follower, D', [election_timeout(D')]}`.

**Leader receiving `#append_entries_reply{}`:**
- `Reply.term > cur_term` → `step_down`, `{next_state, follower, ...}`.
- Ignore if not `leader` or `Reply.term < cur_term`.
- **On `success`:** `match_index#{Peer => max(old, Reply.match_index)}`, `next_index#{Peer =>
  Reply.match_index + 1}`. Run `advance_commit/1` (§1.10); if `next_index[Peer] <= last_log_index`, send the
  next batch (pipelining).
- **On failure:** `next_index#{Peer => max(1, Reply.match_index + 1)}` (never below `snap_idx+1`), re-send
  AppendEntries with the lower `prev_log_index`. If it would drop to `<= snap_idx`, that is the
  InstallSnapshot trigger (M3).

### 1.8 The replication loop (`leader`)

`replicate/1` runs on (a) heartbeat timeout, (b) just after a local `append`, (c) after a successful AE
reply that left a peer behind. For each peer `P ∈ committee() \ {self}`:

```erlang
PrevI   = next_index[P] - 1,
PrevT   = term_at(PrevI, D),
Entries = log_from(next_index[P], max_batch, D),   %% [] ⇒ pure heartbeat
AE = #append_entries{term=cur_term, leader_id=self,
                     prev_log_index=PrevI, prev_log_term=PrevT,
                     entries=Entries, leader_commit=commit_index},
send_raft(P, AE, D)
```

Heartbeats are sent unconditionally on the heartbeat timer, including with no peers (1-voter: the loop is
over `[]`). Each batch is capped at `max_batch` entries, kept under `?CHUNK_BYTES` so single-frame AE stays
unchunked in the common case.

### 1.9 Becoming candidate → becoming leader

**`start_election/1`** (election timeout in `follower`/`candidate`) — guarded by `lists:member(self,
derive_committee(D))` (a removed server does not start elections):

```erlang
T1 = cur_term + 1,
D1 = D#d{cur_term = T1, voted_for = self, votes = #{self => true}, leader_id = none},
ok = quod_ledger_store:write_meta(Store, T1, self),     %% DURABLE before any RPC
broadcast RequestVote{term=T1, candidate_id=self,
                      last_log_index=last_log_index(D1), last_log_term=last_log_term(D1)},
{next_state, candidate, D1#d{elections = elections+1}, [election_timeout(D1)]}
```

If `quorum(D1) == 1`, the self-vote satisfies quorum → fall straight through to `become_leader/1`.

**`become_leader/1`** (on reaching quorum of granted votes):

```erlang
LLI   = last_log_index(D),
Next  = maps:from_list([{P, LLI + 1} || P <- peers(D)]),
Match = maps:from_list([{P, 0}       || P <- peers(D)]),
D1 = D#d{next_index = Next, match_index = Match, leader_id = self, votes = #{}},
%% MANDATORY current-term no-op (#7, Figure 8): append a no-op kind=block of the new term so
%% prior-term entries a majority holds can commit (indirectly), and followers can advance commit
%% even with no client write. Commits via the SAME advance_commit/1 rule; fsync'd before counting.
I  = LLI + 1,
E  = #entry{index = I, term = cur_term, kind = block, data = noop},
D2 = D1#d{log = D1#d.log ++ [E]},
{ok, Store1} = quod_ledger_store:append(D2#d.store, [E]),
D3 = case quorum(D2) of 1 -> advance_commit(D2#d{store=Store1}); _ -> D2#d{store=Store1} end,
{next_state, leader, D3, [replicate_now, heartbeat_timeout(D3)]}
```

### 1.10 Commit rule + in-order apply into `quod_prolog`

**Commit rule (leader, `advance_commit/1`)** — mandatory current-term guard:

```erlang
advance_commit(D = #d{commit_index = C}) ->
    LLI = last_log_index(D),
    Ns = [N || N <- lists:seq(C+1, LLI),
               replicated_majority(N, D),
               term_at(N, D) =:= D#d.cur_term],
    case Ns of [] -> D; _ -> apply_committed(D#d{commit_index = lists:max(Ns)}) end.

replicated_majority(N, D) ->
    Count = 1 + length([P || P <- peers(D), maps:get(P, D#d.match_index, 0) >= N]),
    Count >= quorum(D).
```

A prior-term entry commits only *indirectly* — when a current-term entry above it commits (the §1.9 no-op
guarantees one). Counting a prior-term entry committed by replica count alone is the Raft Figure-8 bug and
is never done.

**Apply loop (all servers, `apply_committed/1`)** — drives `quod_prolog`:

```erlang
apply_committed(D = #d{last_applied = LA, commit_index = CI}) when LA >= CI -> D;
apply_committed(D = #d{last_applied = LA}) ->
    I = LA + 1,
    #entry{kind = Kind, data = Data} = entry_at(I, D),
    D1 = case Kind of
             block ->
                 Verdict = quod_prolog:apply_block(D#d.ns, I, Data),  %% ok | {reject, conflict}
                 D2 = reply_pending(I, Verdict, D),                   %% see below
                 D2#d{commits = D2#d.commits + 1};
             config ->
                 drop_departed(Data, clear_cfg_gate(Data, D))
         end,
    apply_committed(D1#d{last_applied = I}).
```

`apply_block/3` is a **synchronous `gen_server:call`** into `quod_prolog`, returning `ok | {reject,
conflict}`. The OCC read-set re-check happens at apply on **every** member; because every member re-checks
deterministically against the same converged KB at the same index, the verdict is identical everywhere.
`quod_ledger` surfaces the verdict to the parked client:

```erlang
reply_pending(I, Verdict, D) ->
    case maps:take(I, D#d.pending) of
        {From, Pending1} ->
            Reply = case Verdict of ok -> {ok, I}; {reject, conflict} -> {error, conflict_retry} end,
            gen_statem:reply(From, Reply),
            D#d{pending = Pending1};
        error -> D
    end.
```

A rejected block stays committed in the log as a no-op (it changed no facts), preserving identical
prefixes. The `noop` election marker applies as nothing. `config` apply clears the one-change gate and, on
the leader, drops a removed peer's volatile `next_index`/`match_index` slots:

```erlang
drop_departed({remove, Node}, D) ->
    D#d{next_index = maps:remove(Node, D#d.next_index),
        match_index = maps:remove(Node, D#d.match_index)};
drop_departed(_, D) -> D.
```

### 1.11 The `append` API + membership-change entries

```erlang
-spec append(binary(), #transaction{}) ->
    {ok, BlockIndex :: log_index()} | {error, not_in_charge, Hint :: server_id() | none}
  | {error, conflict_retry} | {error, busy}.
append(Ns, Change) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), {append, Change}, 5000)
    catch exit:_ -> {error, not_in_charge, unavailable} end.
```

Served only in **`leader`**:

```erlang
leader({call, From}, {append, Change}, D) ->
    case maps:size(D#d.pending) >= maps:get(max_pending, D#d.cfg) of
        true  -> {keep_state, D, [{reply, From, {error, busy}}]};
        false ->
            I  = last_log_index(D) + 1,
            E  = #entry{index = I, term = D#d.cur_term, kind = block, data = Change},
            {ok, Store1} = quod_ledger_store:append(D#d.store, [E]),   %% DURABLE before counting own log
            D1 = D#d{log = D#d.log ++ [E], store = Store1,
                     appends = D#d.appends + 1,
                     pending = (D#d.pending)#{I => From}},          %% From replied from apply step
            D2 = case quorum(D1) of 1 -> advance_commit(D1); _ -> D1 end,
            {keep_state, D2, [replicate_now]}
    end;

follower({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, D#d.leader_id}}]};
candidate({call, From}, {append, _}, D) ->
    {keep_state, D, [{reply, From, {error, not_in_charge, none}}]}.
```

`From` is **not** replied here — it is parked in `pending` keyed by `log_index` and replied from the apply
step (§1.10) so the reply reflects the OCC verdict. On leader step-down, fail all `pending` above
`commit_index` with `{error, not_in_charge, leader_id}`. `replicate_now` is an internal event
(`{next_event, internal, replicate}`).

**Membership change** (`kind=config`, one at a time):

```erlang
add_member(Ns, Node)    -> gen_statem:call(quod_reg:via({quod_ledger, Ns}), {add_member, Node}, 5000).
remove_member(Ns, Node) -> gen_statem:call(quod_reg:via({quod_ledger, Ns}), {remove_member, Node}, 5000).

leader({call, From}, {Op, Node}, D) when Op =:= add_member; Op =:= remove_member ->
    case D#d.cfg_uncommitted of
        true  -> {keep_state, D, [{reply, From, {error, config_in_flight}}]};
        false ->
            Data = case Op of add_member -> {add, Node}; remove_member -> {remove, Node} end,
            I  = last_log_index(D) + 1,
            E  = #entry{index = I, term = D#d.cur_term, kind = config, data = Data},
            {ok, Store1} = quod_ledger_store:append(D#d.store, [E]),
            D1 = D#d{log = D#d.log ++ [E], store = Store1, cfg_uncommitted = true},
            D2 = D1#d{next_index = ensure_peer(Node, D1)},   %% adopt-on-append
            D3 = open_committee_links(D2),
            D4 = case quorum(D3) of 1 -> advance_commit(D3); _ -> D3 end,
            {keep_state, D4, [{reply, From, {ok, I}}, replicate_now]}
    end.
```

- **Adopt-on-append:** `committee/1` derives from the log, so a new member counts in `quorum()`/commit math
  the instant the entry is appended. Never wait for commit to adopt.
- **One in flight:** `cfg_uncommitted=true` blocks the next change until the apply loop clears it.
- **Leader removing itself** (`{remove, SelfNodeId}`): stays leader until the entry commits (under the new
  config excluding it), then steps down. `start_election/1` is guarded by `lists:member(self,
  derive_committee(D))`.

```erlang
committee(Ns) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), get_committee, 1000) catch exit:_ -> [] end.

derive_committee(#d{snap_cfg = Base, log = Log}) ->
    lists:foldl(fun(#entry{kind = config, data = {add, S}}, Acc)    -> [S | Acc -- [S]];
                   (#entry{kind = config, data = {remove, S}}, Acc) -> Acc -- [S];
                   (_, Acc) -> Acc
                end, Base, Log).
quorum(D) -> (length(derive_committee(D)) div 2) + 1.
peers(D)  -> derive_committee(D) -- [D#d.self].
```

`get_committee`/`status`/`stats` are served in `common/3` (any state). `replay/1` (§4) resets `last_applied
:= snap_idx` and re-drives `apply_block/3` over `snap_idx+1 .. commit_index` for a freshly-restarted
`quod_prolog`. `snapshot/1` returns `{ok, snap_idx, snap_data} | none` for KB seeding. `history/3` (§3)
serves paged browsing.

### 1.12 Edge cases

- **Stale replies** (old term / wrong state): validated against `cur_term`/state; ignored.
- **Duplicate/delayed AppendEntries:** same-index-same-term entries skipped (never truncate on a match).
- **Foreign-channel / undecodable:** dropped in `common/3` / pre-decode (§2).
- **Link death** (`{'DOWN', ...}` / `{link_error, ...}`): drop the cached conn; next heartbeat re-opens.
- **CP under partition (#16):** a minority leader cannot reach quorum → `advance_commit` never advances →
  writes hang (caller times out → `{error, not_in_charge, unavailable}`). Deliberate CP choice.
- **Restart mid-term:** `init/1` reloads durable state; `commit_index`/`last_applied` reset to `snap_idx`.
  Re-application into `quod_prolog` must be idempotent on `quod_prolog`'s side.

### 1.13 Conventions

`logger:info("quod[~s]: <msg>", [Ns | Args])`; `catch exit:_` around `gen_statem:call`; `[safe]`
size-capped decode; side-effect returns ignored with `_ =`; `stats/1` returns one snake_case key set (§1.14);
`terminate/3` does `quod_reg:unsubscribe({channel, Chan})` in a `catch` plus `quod_ledger_store:close(Store)`.

### 1.14 `stats/1`

One snake_case key set (the union; consumed by `quod_metrics` via **partial** map match so adding keys is
safe):

```erlang
stats(Ns) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), get_stats, 1000) catch exit:_ -> undefined end.

%% get_stats reply:
#{cur_term => T, commit_index => C, last_applied => A, log_len => L,
  committee_size => CS, is_leader => IL, role => follower|candidate|leader,
  elections => E, appends => AP, commits => CM, snapshots_installed => SI,
  pending_appends => PA,
  msgs_sent => MS, msgs_recv => MR, bytes_sent => BS, chunks_sent => CHS, rx_dropped => RD}
```

---

## 2. Wire protocol over `quod_link`

This is the transport/codec layer of `quod_ledger`: record shapes (shared header), encoding, chunking, link
bookkeeping, and the three transport operations.

### 2.1 Channel

```erlang
Chan = term_to_binary({log, Ns}, [deterministic]),
quod_reg:subscribe({channel, Chan}),
```

`[deterministic]` is mandatory: `quod_quic:open_link/2` and `quod_reg:subscribe/1` key on the binary; a
non-deterministic encoding would split the channel across nodes/OTP versions. `terminate/3` mirrors with
`quod_reg:unsubscribe({channel, Chan})` in `catch _:_ -> ok`. `{channel, Chan}` (a binary-keyed gproc
property) and `{quod_ledger, Ns}` (a gproc name) do not collide.

### 2.2 Records & types

`server_id()`, `term_no()`, `log_index()`, `clause()`, `op()`, `read_check()`, `#entry{}`, `#transaction{}`, and
the six RPC records live in `include/quod_ledger.hrl` (§ shared header), `-include`d at the top of `quod_ledger.erl`
**before** `#d{}`/`#rx{}` so `server_id()`/`#entry{}` are in scope. `install_snapshot.data` is an
already-serialized `binary()`; the whole record is `encode/1`'d once like any other record (no separate
re-wrap of `data`; the concatenation of its chunk parts is exactly `encode(#install_snapshot{})`).

### 2.3 `#rx{}` reassembly record (defined before `#d{}`)

```erlang
-record(rx, {msg_id :: reference(),
             total  :: pos_integer(),
             got    :: #{pos_integer() => binary()},
             bytes  :: non_neg_integer()}).
```

### 2.4 Encoding / decoding

```erlang
encode(Msg)        -> term_to_binary(Msg).
decode(Bin)        -> try binary_to_term(Bin, [safe]) of T -> T catch _:_ -> error end.
decode_record(Bin) -> try binary_to_term(Bin)        of T -> T catch _:_ -> error end.
```

The wire **envelope** (`{raft|raft_chunk, Ns, ...}`) holds only known atoms + binaries, so it decodes with
**`[safe]`** (`decode/1`) — refusing unknown atoms / fun / pid / port. But the **inner record** is an
`#append_entries{}` carrying a `#transaction{}` whose diff is arbitrary Prolog clauses — i.e. atoms the receiver
*has not seen yet* (the fact's own functor/args). `[safe]` would refuse those legitimately-new atoms and drop
every fact-bearing block, so a follower could never learn a new fact (it only learns the atom by applying it
— chicken-and-egg). The inner record therefore decodes **without `[safe]`** (`decode_record/1`), bounded by
the `?MAX_RAFT_BYTES` size cap. This is sound for Phase 1's **trusted single-operator committee**; the later
identity/BFT layer re-tightens it with signed, schema-validated changes. (Original spec said `[safe]` was
mandatory everywhere — corrected here: it cannot be, for the application payload.) Every record is a tagged
tuple; dispatch is a pattern match with a final `_ -> D` drop clause.

### 2.5 Max payload, chunking & reassembly

```erlang
-define(MAX_RAFT_BYTES, 65536).   %% reassembled cap for NON-snapshot msgs
-define(CHUNK_BYTES,    65536).   %% 64 KiB payload per quod_link frame — << 1 MiB ceiling
%% max_snapshot_bytes is the cfg knob (default 64 MiB), read from D#d.cfg — NOT a macro.
```

**Why `?CHUNK_BYTES == ?MAX_RAFT_BYTES`:** if `?CHUNK_BYTES` were larger, a non-snapshot message between the
two would pass the single-frame test, be sent as one `{raft, ...}`, then be silently dropped at the receiver
by the `?MAX_RAFT_BYTES` cap. Keeping them equal means any non-snapshot message exceeding its reassembled
cap is chunked, and the reassembled result is re-checked against `?MAX_RAFT_BYTES` (dropping, not
mis-sending, anything genuinely oversized). Snapshots are the one record allowed past `?MAX_RAFT_BYTES`,
bounded by `max_snapshot_bytes`.

**Envelope** (the unit handed to `quod_link:send/2`):

```erlang
{raft, Ns, Bin}                              %% single-frame: Bin = encode(Record)
{raft_chunk, Ns, MsgId, Seq, Total, Part}    %% one slice of a multi-frame message
```

```erlang
frames(Ns, Record) ->
    Bin = encode(Record),
    case byte_size(Bin) =< ?CHUNK_BYTES of
        true  -> [encode({raft, Ns, Bin})];
        false ->
            Parts = chunkify(Bin, ?CHUNK_BYTES),
            Total = length(Parts),
            MsgId = make_ref(),
            [ encode({raft_chunk, Ns, MsgId, Seq, Total, P})
              || {Seq, P} <- lists:zip(lists:seq(1, Total), Parts) ]
    end.
```

**Reassembly:** `#d.rx` holds at most one `#rx{}` per peer; a new `MsgId` replaces any in-flight one
(channel is in-order per peer-pair). Memory cap: if `bytes` would exceed `max_snapshot_bytes`, drop and bump
`rx_dropped`. Non-snapshot messages re-check `?MAX_RAFT_BYTES` after reassembly. Reassembly keyed `{Peer,
MsgId}`.

### 2.6 The three transport operations

**(a) Open links.** For each committee member `M` not in `conns`: `quod_quic:open_link(M, Chan)`. On
`{link_up, M, Chan, LinkPid}` cache `conns#{M => {LinkPid, monitor(process, LinkPid), out}}` and **flush the
per-peer outbox FIFO in order**. On `{link_error, M, Chan}` drop the queued frames (Raft re-sends fresh on
the next heartbeat). On `{'DOWN', Ref, ...}` drop the conn. All in `common/3`, matching on `Chan`.

> **Outbox divergence from Brahms (load-bearing):** Brahms's outbox is last-wins single-payload. Raft RPCs
> are not last-wins, so `quod_ledger`'s outbox is a **per-peer FIFO list** flushed in order on `link_up`.

**(b) Send to ONE member (unicast)** — the only natural primitive:

```erlang
send_raft(M, Record, D = #d{ns = Ns, conns = Conns, outbox = Outbox}) ->
    Frames = frames(Ns, Record),
    case maps:get(M, Conns, undefined) of
        {LinkPid, _Ref, _Origin} ->
            [ _ = quod_link:send(LinkPid, F) || F <- Frames ],
            bump_sent(Frames, D);
        undefined ->
            _ = quod_quic:open_link(M, D#d.chan),
            Q = maps:get(M, Outbox, []),
            bump_sent(Frames, D#d{outbox = Outbox#{M => Q ++ Frames}})
    end.

bump_sent(Frames, D) ->
    Bytes = lists:sum([byte_size(F) || F <- Frames]),
    D#d{msgs_sent = D#d.msgs_sent + 1, chunks_sent = D#d.chunks_sent + length(Frames),
        bytes_sent = D#d.bytes_sent + Bytes}.
```

**Broadcast** (RequestVote / heartbeat) is a fold over `committee() \ {self}`, encoding per-peer (per-peer
`prev_log_index`/`entries` differ — no shared-bytes fan-out):

```erlang
broadcast(MakeMsg, Committee, D) ->
    lists:foldl(fun(M, A) -> send_raft(M, MakeMsg(M, A), A) end, D, Committee -- [D#d.self]).
```

**(c) Receive.** Inbound shape `{quod_message, {Peer, LinkPid}, Chan, Payload}`; `Peer` is the sending
`server_id()`. Handled per role-state guarded on own `Chan`, foreign channels dropped in `common/3`:

```erlang
follower(info, {quod_message, {Peer, _LinkPid}, Chan, Payload}, D = #d{chan = Chan}) ->
    {keep_state, handle_inbound(Peer, Payload, D)};
common(info, {quod_message, _, _OtherChan, _}, D) -> {keep_state, D}.

handle_inbound(_Peer, Payload, D) when byte_size(Payload) > ?CHUNK_BYTES + 64 -> D;
handle_inbound(Peer, Payload, D0) ->
    D = bump_recv(Payload, D0),
    case decode(Payload) of
        {raft, Ns, Bin} when Ns =:= D#d.ns               -> dispatch_record(Peer, Bin, D);
        {raft_chunk, Ns, MsgId, Seq, Total, Part} when Ns =:= D#d.ns ->
            reassemble(Peer, MsgId, Seq, Total, Part, D);
        _ -> D
    end.

bump_recv(_Payload, D) -> D#d{msgs_recv = D#d.msgs_recv + 1}.

dispatch_record(Peer, Bin, D) ->
    case decode(Bin) of
        #install_snapshot{}       = M -> raft_event(Peer, M, D);   %% bypasses ?MAX_RAFT_BYTES
        #install_snapshot_reply{} = M -> raft_event(Peer, M, D);
        Other when byte_size(Bin) =< ?MAX_RAFT_BYTES ->
            case Other of
                #request_vote{}         = M -> raft_event(Peer, M, D);
                #request_vote_reply{}   = M -> raft_event(Peer, M, D);
                #append_entries{}       = M -> raft_event(Peer, M, D);
                #append_entries_reply{} = M -> raft_event(Peer, M, D);
                _                           -> D
            end;
        _ -> D#d{rx_dropped = D#d.rx_dropped + 1}
    end.
```

`raft_event/3` is the only bridge into the §1 state-machine logic.

### 2.7 Separation from Brahms

Distinct channel (`{channel, term_to_binary({log, Ns}, [deterministic])}` vs `{channel, Ns}`), distinct reg
name (`{quod_ledger, Ns}` vs `{quod_brahms, Ns}`), distinct envelope tags (`{raft, ...}`/`{raft_chunk, ...}` vs
gossip tuples). One `quod_link` per channel per connection → the `{log, Ns}` and Brahms streams are
independent on the same QUIC connection.

---

## 3. Persistence (`quod_ledger_store`)

`quod_ledger_store` is the only quod code that touches disk. A **plain library module** (no process, no reg, no
supervisor child), called synchronously in-line from inside the `quod_ledger` `gen_statem` callbacks so an
fsync provably completes before the triggering network reply leaves. It holds no state beyond an opaque
handle threaded through `#d.store`.

> **Assumption (flagged):** the data-dir convention (`QUOD_DATA` env + `application:get_env(quod, data_dir,
> …)`) is wired through `quod_app:apply_env/0` exactly like `QUOD_PORT`. Default `data_dir` and per-namespace
> base64url encoding flagged for review.

### 3.1 Directory layout

```
$QUOD_DATA/                         (default: filename:basedir(user_data,"quod") ++ "/data")
  <nstoken>/                        nstoken = base64url(Ns)
    meta.term                       cur_term + voted_for (atomic tmp+rename, fsync'd)
    log.0001                        append-only log segment (entries = the block list)
    log.0001.idx                    {Index, Term, ByteOffset, ByteLen} per entry
    snapshot.<Idx>.<Term>           materialized snapshot (atomic via tmp+rename)
    snapshot.<Idx>.<Term>.cfg       committee config as of that snapshot
```

The first cut writes one growing segment `log.0001`; the segment number is reserved so rollover needs no
format change.

### 3.2 The store handle

`include/quod_ledger_store.hrl` `-include`s `quod_ledger.hrl` (so `#entry{}` is the shared definition — **not**
redefined here) and defines only the private store record + opaque handle type:

```erlang
%% include/quod_ledger_store.hrl
-include("quod_ledger.hrl").

-record(store, {dir         :: file:filename_all(),
                ns          :: binary(),
                log_fd      :: file:io_device(),     %% [read,write,raw,binary]
                idx_fd      :: file:io_device(),     %% [read,write,raw,binary]
                seg         :: pos_integer(),
                last_index  :: non_neg_integer(),
                last_term   :: non_neg_integer(),
                base_offset :: non_neg_integer(),    %% next append offset
                snap_index  :: non_neg_integer(),
                snap_term   :: non_neg_integer()}).
-opaque handle() :: #store{}.
-export_type([handle/0]).
```

The log/idx fds are opened `[read, write, raw, binary]` (**not** `[append, …]`): in append mode every write
is forced to EOF regardless of `file:position/2`, breaking conflict truncation and post-truncation
re-append. The handle tracks `base_offset` as the next write position; each `append` seeks there, writes,
then advances it.

### 3.3 On-disk encoding (per file)

```
frame  = <<Magic:32, Len:32, CRC:32, Payload:Len/binary>>
Magic  = 16#9151_06AA
CRC    = erlang:crc32(Payload)
Payload = term_to_binary(Term, [deterministic])
```

- **`meta.term`** — single frame of `#{cur_term => Term, voted_for => ServerId | none}`. **Always** written
  atomically: write `meta.term.tmp`, `file:datasync/1` it, `file:rename/2` over `meta.term`, then
  `file:datasync/1` the **containing directory** (rename is durable only after a dir fsync on POSIX). There
  is **no** in-place truncate-and-rewrite path (it would expose a torn-write window that could let a
  restarted node double-vote in one term).
- **`log.NNNN`** — append-only at the Raft level (never rewritten in place). The only byte mutation is tail
  truncation (follower conflict / torn-tail recovery): seek to a recorded offset, `file:truncate/1`,
  `file:datasync/1`.
- **`log.NNNN.idx`** — fixed-width `<<Index:64, Term:64, Offset:64, Len:32>>` per entry. A **derived cache**:
  no fsync on the critical path; only the log frame must be durable before `append/2` returns. Rebuilt by a
  forward frame-scan if inconsistent on boot. The log is the source of truth.
- **`snapshot.<Idx>.<Term>`** + `.cfg` — tmp+datasync+rename+dir-fsync.

### 3.4 Public API (handle-threaded)

All functions are synchronous and complete their required fsync before returning. A write that cannot fsync
raises (crashing the `quod_ledger` statem → supervisor restart → clean cold boot) — the one place the
"never crash on transient failure" convention is deliberately inverted.

```erlang
-spec open(Ns :: binary(), DataDir :: file:filename_all()) -> {ok, handle()}.
-spec close(handle()) -> ok.

-spec read_meta(handle()) -> {Term :: non_neg_integer(), VotedFor :: server_id() | none}.
%%   {0, none} if meta.term absent (fresh namespace).
-spec write_meta(handle(), Term :: non_neg_integer(), VotedFor :: server_id() | none) -> ok.
%%   Atomic tmp+datasync+rename+dir-fsync. Called BEFORE a vote-granted / term-bump reply (§E.10.1/10.4).

-spec append(handle(), [#entry{}]) -> {ok, handle()}.
%%   Contiguous indices == last_index+1.. ; seek to base_offset, write frames+idx, single LOG datasync
%%   per batch, advance last_index/last_term/base_offset. Returns before quod_ledger counts own log (§10.2/10.3).
-spec truncate_from(handle(), Index :: pos_integer()) -> {ok, handle()}.
%%   Delete entry Index and after; file:truncate log+idx, datasync, recompute. Never <= snap_index.

-spec read_at(handle(), Index :: pos_integer()) -> {ok, #entry{}} | not_found.
-spec read_range(handle(), From :: pos_integer(), To :: pos_integer()) -> {ok, [#entry{}]}.
-spec last(handle()) -> {Index :: non_neg_integer(), Term :: non_neg_integer()}.
-spec term_at(handle(), Index :: non_neg_integer()) -> non_neg_integer() | undefined.

-spec write_snapshot(handle(), LastIdx, LastTerm, Config :: [server_id()], Data :: term()) -> {ok, handle()}.
%%   Requires LastIdx =< commit_index. tmp+datasync+rename+dir-fsync. Compaction is a SEPARATE step —
%%   write_snapshot never deletes log entries, so a crash mid-compaction still has both copies.
-spec read_snapshot(handle()) -> none | {ok, LastIdx, LastTerm, Config :: [server_id()], Data :: term()}.
-spec install_snapshot(handle(), LastIdx, LastTerm, Config, Data) -> {ok, handle()}.
%%   write_snapshot (durable) FIRST, then replace the live log; caller jumps commit_index/last_applied.
```

`load/1` is a convenience over `read_meta`/`read_snapshot`/scan returning `#{cur_term, voted_for, log,
snap_idx, snap_term, snap_cfg, snap_data}` for `quod_ledger:init/1`.

### 3.5 Cold-boot reload sequence

Called once from `quod_ledger:init({Ns, Config})`:

1. `DataDir = maps:get(data_dir, Cfg)`; `{ok, Store0} = quod_ledger_store:open(Ns, DataDir)`. Inside `open/2`:
   a. `filelib:ensure_path/1` the namespace dir.
   b. Open `log.NNNN`/`.idx` `[read, write, raw, binary]`; scan the idx; `base_offset` = log file size.
   c. **Torn-tail recovery:** if the final frame's `Len`+`CRC` don't fully fit/check, seek to the last good
      boundary, `file:truncate/1` log+idx, `file:datasync/1`, set `base_offset`. Safe: an un-fsync'd append
      was never acked / counted toward commit.
   d. Rebuild idx by frame-scan if missing/short/inconsistent.
   e. `read_snapshot/1` → set `snap_index`/`snap_term`; set `last_index`/`last_term` from the last idx record
      or from `snap_*` if the log is empty.
2. `{Term, VotedFor} = read_meta(Store0)` → seed `cur_term`, `voted_for` (`{0, none}` if absent).
3. If a snapshot exists, seed the materialized KB (handed to `quod_prolog`) from `snap_data`,
   `last_applied := commit_index := snap_index`; else both `:= 0`.
4. Recompute volatile state: committee derived (`snap_cfg` overlaid with in-log `kind=config` entries in
   index order, *appended* not just committed); `next_index`/`match_index` empty until an election win.
5. Enter `follower` with a randomized election timeout. A 1-member committee self-elects on the first
   timeout.
6. Brand-new namespace: no files → empty store, `read_meta` gives `{0, none}`, `quod_ledger` appends the
   genesis `{add, self}` config (create mode).

### 3.6 Browsability (full-history read path)

```erlang
-spec history(Ns :: binary(), From :: pos_integer(), Count :: pos_integer())
        -> {ok, [#entry{}], NextFrom :: pos_integer() | done} | {error, term()}.
history(Ns, From, Count) ->
    try gen_statem:call(quod_reg:via({quod_ledger, Ns}), {history, From, Count}, 1000)
    catch exit:_ -> {error, unavailable} end.
```

Served by `read_range(Store, From, min(From+Count-1, LastIndex))`, `Count` clamped to `?HISTORY_PAGE_MAX`.
Entries already compacted into a snapshot (`Index =< snap_index`) return `{error, compacted, snap_index}`.
History is committee-only in the first cut; read-copies hold current facts only.

### 3.7 Edge cases

- **Torn tail write** — CRC/Len check at `open/2`, truncate to last intact frame.
- **`meta.term` torn rewrite** — impossible (tmp+rename only).
- **idx out of sync** — rebuilt by frame-scan; log is source of truth.
- **Truncate below snapshot** — `truncate_from/2` refuses `Index =< snap_index` (crashing assertion).
- **Append with gap/backward index** — `append/2` asserts contiguity; violation crashes the statem.
- **Crash mid-compaction** — both snapshot and full log on disk; boot restores from the snapshot + suffix.
- **fsync failure / disk full** — propagated as a crash; restart → clean cold boot.
- **`quod_app` env wiring** — add `data_dir` to `apply_env/0` (default `filename:basedir(user_data, "quod")
  ++ "/data"`, overridable by `QUOD_DATA`).

---

## 4. `quod_prolog` apply + prove

`quod_prolog` is the per-namespace fact engine: it owns the committed erlog KB for one ontology, applies
committed blocks from `quod_ledger` in log order, and serves proofs. It **serialises writes**; read-only proofs
run on copy-on-write overlays alongside, never blocking the writer (#22, #26). One per ontology.

### 4.1 Module, records

```erlang
-module(quod_prolog).
-behaviour(gen_server).   %% one writer-serialiser per Ns; no protocol states (those live in quod_ledger)
-include("quod_ledger.hrl").
```

erlog stack reused from bbsvx: `quod_erlog_db_differ → quod_erlog_db_local_prove → quod_erlog_db_ets`
(ported from the bbsvx modules, dropping the `db_federated` and `set_acl` layers — deferred with foreign
writes, #10).

```erlang
-record(kb, {est        :: erlog_state(),          %% #est{} over differ->ets, committed facts
             applied = 0 :: non_neg_integer()}).   %% highest log index folded in

-record(s, {ns        :: binary(),
            self      :: server_id(),
            cfg       :: map(),
            kb        :: #kb{},
            prove_pending = #{} :: #{reference() => prove_ctx()}, %% in-flight prove workers, by Ref
            parked    = #{} :: #{binary() => write_ctx()},        %% writes awaiting commit, by tx_id
            applies   = 0 :: non_neg_integer(),
            rejects   = 0 :: non_neg_integer(),
            proves    = 0 :: non_neg_integer(),
            conflicts = 0 :: non_neg_integer()}).

-type bindings()  :: [map()] | fail.
-type prove_ctx() :: {From :: gen_server:from(), CallerNs :: binary(),
                      HeightRead :: non_neg_integer(), MonRef :: reference(), TimerRef :: reference()}.
-type write_ctx() :: {From :: gen_server:from(), Effects :: [term()]}.
```

`#transaction{}` and the `op()`/`read_check()`/`clause()` types come from the shared header. `read_check` values
are `phash2` integers per `{Functor, Arity}` (per-predicate granularity — same-functor different-fact
changes cause accepted false conflicts; per-fact granularity deferred).

### 4.2 Start / register / supervise

```erlang
start_link(Ns, Config) ->
    gen_server:start_link(quod_reg:via({quod_prolog, Ns}), ?MODULE, {Ns, Config}, []).

namespaces() -> gproc:select([{{{n, l, {quod_prolog, '$1'}}, '_', '_'}, [], ['$1']}]).

-define(DEFAULTS, #{node_id     => undefined,
                    prove_ms    => 30000,     %% read-proof worker watchdog (server-side)
                    call_ms     => 35000,     %% client call timeout in prove/3; MUST exceed prove_ms
                    max_diff_bytes => 1048576}).
```

Child of `quod_ns` (`rest_for_one`, after `quod_ledger`). `init({Ns, Config})` merges `?DEFAULTS`, validates,
and rebuilds the KB (§4.6) before answering proves. `quod_prolog` does not subscribe to any channel; it
receives committed blocks via direct call from `quod_ledger`.

### 4.3 Serving `prove` — copy-on-write overlays, no writer blocking

```erlang
-spec prove(TargetNs :: binary(), Goal :: term(), CallerNs :: binary())
        -> {ok, Bindings :: [map()], ReadHeight :: non_neg_integer()}
         | {error, no_such_namespace} | fail.
prove(TargetNs, Goal, CallerNs) ->
    case quod_reg:where({quod_prolog, TargetNs}) of
        undefined -> {error, no_such_namespace};
        Pid -> try gen_server:call(Pid, {prove, Goal, CallerNs}, maps:get(call_ms, ?DEFAULTS))
               catch exit:_ -> fail end
    end.
```

`fail` is goal-failure; `{error, no_such_namespace}` is routing failure — distinct. The writer never blocks:
`handle_call({prove, ...})` parks `From` and returns `{noreply, S}`; the reply is sent later (from
`handle_cast({prove_result, ...})` for a read, or after commit for a write).

`handle_call({prove, Goal, CallerNs}, From, S)`:

1. **Wrap the committed KB in a per-proof overlay:**
   ```erlang
   #kb{est = Committed, applied = HeightRead} = S#s.kb,
   Wrapped = quod_erlog_db_local_prove:wrap_state(Committed, #{read_set => true}),
   ```
   `local_prove` shadows asserts/retracts per functor in its own overlay; committed facts untouched.
2. **Record `HeightRead = #kb.applied`** into the parked `prove_ctx()` (#7 — record height read).
3. **Spawn + monitor the worker, arm a `prove_ms` watchdog**, stash `{From, CallerNs, HeightRead, MonRef,
   TimerRef}` in `prove_pending` under the worker `Ref`, return `{noreply, S1}`:
   ```erlang
   try erlog_int:prove_goal(Goal, Wrapped) of
       {succeed, #est{bs = Bs} = Final} ->
           Bindings = extract_bindings(Goal, Bs),
           Db       = Final#est.db,
           Changes  = quod_erlog_db_local_prove:get_local_changes(Db),
           ReadSet  = quod_erlog_db_local_prove:get_read_set(Db),
           Effects  = quod_erlog_db_local_prove:get_effects(Db),
           gen_server:cast(Self, {prove_result, Ref, {ok, Bindings, Changes, ReadSet, Effects}});
       {fail, _} -> gen_server:cast(Self, {prove_result, Ref, fail})
   catch Class:Err -> gen_server:cast(Self, {prove_result, Ref, {error, {Class, Err}}})
   after quod_erlog_db_local_prove:cleanup_read_set(Wrapped) end
   ```
4. **Classify after execution (#8)** in `handle_cast({prove_result, Ref, Result}, S)` — remove the
   `prove_ctx()`, cancel timer, demonitor:
   - `fail` / `{error, _}` → reply `fail` (resp. `{error, prove_failed}`).
   - `{ok, Bindings, [], _, _}` → **read** (empty write-set, #6). Reply `{ok, Bindings, HeightRead}`. Nothing
     asserted, nothing committed. Bump `proves`.
   - `{ok, Bindings, Changes, ReadSet, Effects}` with `Changes =/= []` → touched facts. **MVP: legal only if
     `CallerNs == TargetNs == S#s.ns`** (#10). If so, hand off to the writer path (§4.5), keep `From` parked.
     Else reject `{error, foreign_write_unsupported}`.

**Concurrency:** multiple workers run on independent overlays; `apply` (§4.4) mutates the committed cell on
the gen_server mailbox between proofs, but a wrapped worker sees its own copy-on-write view. The single
serialisation point is the mailbox; `apply` is the only mutator of the committed cell.

### 4.4 `apply_block` — deterministic OCC apply (#23, #25)

`quod_ledger`, once a block is committed, calls `quod_prolog` **in log-index order**:

```erlang
-spec apply_block(Ns :: binary(), Index :: pos_integer(), Change :: #transaction{} | noop)
        -> ok | {reject, conflict}.
apply_block(Ns, Index, Change) ->
    gen_server:call(quod_reg:via({quod_prolog, Ns}), {apply_block, Index, Change}, infinity).
```

`apply_block/3` is a **synchronous call**. To avoid the `quod_prolog`↔`quod_ledger` deadlock, `quod_ledger:append`
from `quod_prolog` returns at **append/replication-accept** (not commit); the final OCC/commit verdict
reaches the original prove caller via `quod_prolog`'s own `apply_block` handler correlating by `tx_id`. So
`quod_prolog` is never blocked in `gen_server:call(quod_ledger, append)` while needing to service
`apply_block`.

`handle_call({apply_block, Index, Change}, _From, S)` runs the pure engine step, replies the verdict
synchronously, updates `kb`, releases any parked write for the `tx_id`, bumps metrics:

```erlang
%% apply(Index, Change, KB) -> {ok, KB'} | {reject, conflict, KB'}
apply(Index, noop, #kb{applied = A} = KB) ->
    Index =:= A + 1 orelse error({apply_out_of_order, Index, A}),
    {ok, KB#kb{applied = Index}};
apply(Index, #transaction{read_check = ReadCheck, diff = Diff}, #kb{est = Est, applied = A} = KB) ->
    Index =:= A + 1 orelse error({apply_out_of_order, Index, A}),   %% log order is the contract (#13)
    case validate_read_set(ReadCheck, Est) of
        ok ->
            {ok, Est1} = quod_diff:apply_ops(Est, Diff),            %% deterministic (#25)
            {ok, KB#kb{est = Est1, applied = Index}};
        {conflict, _Functor} ->
            {reject, conflict, KB#kb{applied = Index}}             %% block committed; effect is no-op
    end.
```

- **OCC re-check** (`validate_read_set/2`, ported): for each `{Functor, Arity} => ExpectedHash`, recompute
  `quod_diff:functor_hash/3` against the committed KB at index `A`, compare. Any mismatch → `{conflict, _}`.
- **On `ok`:** `quod_diff:apply_ops/2` replays the concrete ops (asserts dedup by content, retracts by
  content, #1). Deterministic; does not re-run Prolog. Bump `applied := Index`, `applies++`.
- **On `{reject, conflict}`:** do not apply the diff but still advance `applied := Index` (the block is
  consumed; effect is a no-op due to stale read). `rejects++`. The submitting node turns the reject into a
  retry (§4.5); other members no-op. Because every member runs `apply` over the same committed prefix, the
  verdict is identical everywhere — accept/reject is itself part of the replicated state machine.

### 4.5 Building a `#transaction{}` and submitting it (effects-after-commit)

A would-be writer (own-ns `prove` whose worker produced `Changes =/= []`) becomes a transaction. `From`
stays parked; nothing is replied until the block applies on this node.

1. Proof already ran on the staging overlay, capturing `Changes`, `ReadSet`, `Effects`.
2. Build a `#transaction{}`:
   ```erlang
   Change = #transaction{tx_id      = ulid:generate(),
                    caller_ns  = CallerNs,
                    diff       = normalize_ops(Changes),   %% local_prove ops -> [op()] by content
                    read_check = ReadSet}
   ```
   `normalize_ops/1` strips clause Tags so the diff is content-only/node-portable (#1, #2). Guard
   `byte_size(term_to_binary(Change)) =< max_diff_bytes`; over-size → `{error, change_too_large}`, drop.
3. **Park `{From, Effects}` in `parked` under `tx_id`, then submit:**
   ```erlang
   case quod_ledger:append(S#s.ns, Change) of
       {ok, _BlockIndex}            -> ok;   %% accepted into the log (replication-accept)
       {error, not_in_charge, Hint} -> {error, {not_leader, Hint}};  %% reply now, unpark
       {error, conflict_retry}      -> {retry, conflict};            %% leader fast-fail (optional)
       {error, busy}                -> {error, busy}
   end
   ```
   `quod_prolog` does not apply its own write directly — it waits for the block via `apply_block/3` in
   committed order, applying via the same deterministic path as every member.
4. **Release on apply (effects-after-commit, #11).** When `apply_block` processes the block carrying this
   `tx_id`, look up `parked`:
   - applied → reply `{ok, Bindings, HeightRead}` to the parked `From` **and** fire the deferred `Effects`.
   - rejected → reply `{retry, conflict}`; discard `Effects`.
   Remove the `tx_id` entry either way. On other members the block has no parked entry, so `apply_block` just
   mutates the KB. `quod_ledger` tags each applied block with its `#transaction.tx_id` for the correlation.

### 4.6 Rebuild on start — replay the log / snapshot (#20, #29, #13)

`init/1` builds the committed KB **from the log**, never from a separately-persisted fact store, via the
`quod_ledger:replay/1` handshake (the safe direction: the log is authoritative; prolog rebuilds from it, never
vice-versa):

```erlang
build_kb(Ns) ->
    {ok, Base} = erlog_int:new(quod_erlog_db_differ, {fresh_ets(Ns), quod_erlog_db_ets}),
    Est0 = load_builtins(Base),
    case quod_ledger:snapshot(Ns) of
        {ok, SnapIndex, SnapData} -> {SnapIndex, seed_from_snapshot(SnapData, Est0)};
        none                      -> {0, Est0}
    end.
```

Then, on `init`, `quod_prolog` synchronously calls `quod_ledger:replay(Ns)`, which resets `quod_ledger`'s
`last_applied := snap_idx` (and hands snapshot data if any) and **re-drives `apply_block/3` over `snap_idx+1
.. commit_index`** into the fresh prolog, before any prove is answered. This is what makes a **lone
`quod_prolog` crash** recover: without the reset, the surviving log (already at `last_applied =
commit_index`) would push only future blocks and the fresh KB would stay empty.

Replay uses the **same `apply/3`** as the live path, so the OCC accept/reject sequence and the final
`applied` counter are reproduced bit-for-bit — the rebuilt `#kb{}` (facts **and** `applied`) is identical to
a continuously-running member's. `#kb.applied` is seeded to `snap_idx` so the `Index =:= applied+1`
assertion holds from the first replayed block. No deferred effects fire on replay (committed-already).

### 4.7 Sync query API + metrics

```erlang
stats(Ns) -> try gen_server:call(quod_reg:via({quod_prolog, Ns}), get_stats, 1000) catch exit:_ -> #{} end.

handle_call(get_stats, _From, S) ->
    {reply, #{applies => S#s.applies, rejects => S#s.rejects, proves => S#s.proves,
              conflicts => S#s.conflicts, applied => (S#s.kb)#kb.applied}, S}.
```

`quod_metrics:declare/0` gains `quod_prolog_applied_index`, `quod_prolog_apply_rejects_total`,
`quod_prolog_proves_total`, labelled `[namespace]`, set in a `refresh_ns`-style loop driven off
`quod_prolog:namespaces/0`.

### 4.8 Edge cases

| Case | Handling |
|---|---|
| `prove` on unknown `TargetNs` | `quod_reg:where` → `undefined` → `{error, no_such_namespace}`. |
| Goal fails | worker reports `fail`; reply `fail`; overlay dropped (not a conflict). |
| Worker crashes / times out | `DOWN` or `prove_ms` watchdog → look up `prove_pending` by `Ref`, reply `{error, prove_failed}`. `call_ms > prove_ms` so the watchdog fires first. |
| Foreign-ns write (`CallerNs =/= TargetNs`, `Changes =/= []`) | `{error, foreign_write_unsupported}` (#10). |
| `apply_block` out of order | `error({apply_out_of_order, ...})`, sub-sup restarts and rebuilds from the log. |
| OCC conflict at apply | `{reject, conflict}`: facts unchanged, `applied` advances, `rejects++`; submitter gets `{retry, conflict}`; effects discarded. |
| Over-size `#transaction{}` | reject before `quod_ledger:append`, `{error, change_too_large}`. |
| Not the leader on submit | `{error, not_in_charge, Hint}` → `{error, {not_leader, Hint}}`, unpark. |
| 1-voter committee | transparent: `quod_ledger` commits on local fsync, then `apply_block` fires as in N-voter. |
| Restart mid-flight write | a parked write whose block had not committed is lost; caller times out (`call_ms`) and re-proves. A committed block is replayed in §4.6; only the deferred external effect is lost (at-most-once). |

---

## 5. `quod_ns_sup` lifecycle + membership

### 5.1 `quod_ns_sup` — subtree root (`src/quod_ns_sup.erl`)

Copy of `quod_brahms_sup` except the key and child module. `simple_one_for_one`; namespaces are created via
`start_namespace/2`; the child is a per-Ns `quod_ns` **sub-supervisor** (not a worker), because a namespace
owns two fate-shared workers.

```erlang
-module(quod_ns_sup).
-behaviour(supervisor).
-export([start_link/0, start_namespace/2, stop_namespace/1, namespaces/0]).
-export([init/1]).

start_link() -> supervisor:start_link(quod_reg:via({quod_ns_sup, node}), ?MODULE, []).

-spec start_namespace(binary(), map()) -> supervisor:startchild_ret().
start_namespace(Ns, Config) ->
    supervisor:start_child(quod_reg:via({quod_ns_sup, node}), [Ns, Config]).

-spec stop_namespace(binary()) -> ok | {error, not_found}.
stop_namespace(Ns) ->
    case quod_reg:where({quod_ns, Ns}) of
        undefined -> {error, not_found};
        Pid -> supervisor:terminate_child(quod_reg:via({quod_ns_sup, node}), Pid)
    end.

namespaces() -> gproc:select([{{{n, l, {quod_ns, '$1'}}, '_', '_'}, [], ['$1']}]).

init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{id => quod_ns, start => {quod_ns, start_link, []},
              restart => transient, type => supervisor},
    {ok, {Flags, [Child]}}.
```

`start_namespace/2`'s `[Ns, Config]` are appended to the empty child MFA. `namespaces/0` keys on `{quod_ns,
'$1'}`. `stop_namespace/1` addresses the `simple_one_for_one` child by pid via `quod_reg:where/1`.

### 5.2 `quod_ns` — per-namespace sub-supervisor (`src/quod_ns.erl`)

The unit of **fate-sharing**. Registers `{quod_ns, Ns}`, supervises `quod_ledger` then `quod_prolog` with
**`rest_for_one`**.

**Authoritative direction:** the durable log rebuilds the kb; the kb never rebuilds the log. If `quod_ledger`
crashes, `rest_for_one` restarts it **and then** `quod_prolog`, which rebuilds from the disk-reloaded log; if
`quod_prolog` crashes alone, only it restarts and rebuilds from the log's committed prefix via the §4.6
replay handshake.

```erlang
-module(quod_ns).
-behaviour(supervisor).
-export([start_link/2]).
-export([init/1]).

start_link(Ns, Config) -> supervisor:start_link(quod_reg:via({quod_ns, Ns}), ?MODULE, {Ns, Config}).

init({Ns, Config}) ->
    Flags = #{strategy => rest_for_one, intensity => 10, period => 10},
    Children =
        [#{id => quod_ledger,    start => {quod_ledger, start_link, [Ns, Config]},
           restart => permanent, type => worker},
         #{id => quod_prolog, start => {quod_prolog, start_link, [Ns, Config]},
           restart => permanent, type => worker}],
    {ok, {Flags, Children}}.
```

Children are `permanent` within the sub-sup; the sub-sup is `transient` under `quod_ns_sup` (a clean
`stop_namespace` is not auto-restarted; a crash is).

### 5.3 `quod_ledger` ⇄ `quod_prolog` apply coupling

The coupling is the Raft apply loop (§1.10): for each committed `kind=block`, `quod_ledger` calls
`quod_prolog:apply_block(Ns, Index, Change) -> ok | {reject, conflict}` **strictly in index order**. It is a
synchronous call; the OCC read-set re-check runs at apply on every member (§4.4) — the verdict is
deterministic and identical everywhere, so this reconciles "apply re-checks" (#23) with determinism (#25).
`kind=config` entries carry **no `read_check`** and are not read-validated.

**Rebuild handshake:** on `quod_prolog:init/1` (empty kb), it calls `quod_ledger:replay(Ns) -> {ok, AppliedUpTo}`
which resets `last_applied := snap_idx` (seeding from snapshot data if present) and re-drives `apply_block/3`
over `snap_idx+1 .. commit_index` before any prove is answered (§4.6). The same handshake covers the
`quod_ledger`-crash path (prolog restarts after it).

### 5.4 Routing `prove(TargetNs, Goal, CallerNs)`

Reads do not go through the committee (#22). Routing is a gproc name lookup on `{quod_prolog, TargetNs}` (see
§4.3 `prove/3`). `TargetNs == CallerNs` is own-namespace; `TargetNs /= CallerNs` is a cross-namespace read
(MVP allows exactly these two, #10). Foreign writes are rejected at routing/classification time. The fact
store is CP (#16): a node that cannot confirm `commit_index` is current cannot serve a guaranteed-latest
read or any write.

### 5.5 Committee write path: `append` / `apply`

`quod_ledger:append(Ns, #transaction{}) -> {ok, BlockIndex} | {error, not_in_charge, Hint} | {error, conflict_retry}
| {error, busy}` (§1.11). A non-leader replies `{error, not_in_charge, Hint}` (last-known leader). On the
leader: append a `kind=block` entry, replicate, commit once a majority holds it, then the apply loop pushes
it into every member's `quod_prolog` (which runs the OCC re-check at apply, surfacing `{error,
conflict_retry}` to the client if the read-set changed). All committee RPCs ride the `{log, Ns}` channel
(§2).

### 5.6 Namespace creation (genesis, 1-voter) vs join

Both enter through `quod_ns_sup:start_namespace(Ns, Config)`; `Config.mode ∈ {create, join}` selects the
path. The distinction is safety-critical: `create` bootstraps a 1-voter committee and may self-elect; `join`
must **never** bootstrap a committee, **never** arm an election timer, and **never** self-elect until a real
committee's leader has added it.

**Create (genesis, 1-voter, #18):** `quod_ledger` finds no durable state and `mode=create` → bootstraps a single
committed `kind=config {add, self}` (1-voter committee), fsync'd. On election timeout it self-elects (quorum
1), becomes leader, is immediately writable — same code paths. Growth to 3/5 is the same code, one config
change at a time (#19, §1.11).

**Join:** `quod_ledger` finds no durable state and `mode=join` → passive learner (empty log, no genesis config,
election timer **not** armed). Then:

1. **Discover via Brahms** (discovery only, #28): `quod_brahms:view(Ns)` / `quod_brahms:sample(Ns)` (both
   exported, degrade to `[]` on `exit:_`). Brahms returns candidates, filtered against the in-log committee.
2. **Request join:** open `{log, Ns}` links to candidates, unicast `{join_request, self, JoinArgs}`; a
   non-leader replies `{not_in_charge, LeaderHint}`.
3. **Leader evaluates the join-predicate** against its own committed facts at its `commit_index`
   (`quod_prolog:prove(Ns, JoinPredicateGoal, Ns)`). Not proved → `{join_denied, Reason}`.
4. **Append a single `{add, JoinerId}` config entry**, refused if `cfg_uncommitted` (one-at-a-time, §1.11).
   Membership is adopted on append by every member that has the entry.
5. **Catch up + activate:** the leader brings the joiner's empty log up via AppendEntries back-up (or
   InstallSnapshot, M3). When the joiner receives the `{add, self}` config entry it adopts membership (now a
   voter) and **arms its election timer**.

### 5.7 Leaving / removal (#19, §1.11)

Voluntary leave submits a `kind=config {remove, ServerId}` to the leader (same one-at-a-time rule). A leader
removing itself stays leader until the removal commits (under the new config excluding it), then steps down
and its `quod_ns` subtree is torn down via `stop_namespace/1` (clean terminate, not auto-restarted). A
removed server stops/disarms its election timer once it observes its own committed removal. A crash (not a
removal) is fine (#29): the committee continues at reduced size; the crashed node's `quod_ns` restarts
(transient → on crash), `quod_ledger` reloads and catches up; membership is unchanged.

### 5.8 `quod_reg` keys

Add four rows to the `quod_reg` moduledoc key table (no code change):

| `Key` | identifies |
| ----- | ---------- |
| `{quod_ns_sup, node}` | per-namespace content subtree root supervisor (singleton) |
| `{quod_ns, Ns}` | a namespace's content sub-supervisor |
| `{quod_ledger, Ns}` | a namespace's Raft committee member / log statem |
| `{quod_prolog, Ns}` | a namespace's Prolog fact store + prove engine |

Channel property: `{channel, term_to_binary({log, Ns}, [deterministic])}` — distinct from Brahms's
`{channel, Ns}`.

### 5.9 Integration with `quod_brahms` and `quod_app` boot

**`quod_brahms` — discovery only (#28).** Never started/stopped/restarted or read on the create path; only
`quod_ledger`'s join path reads `quod_brahms:view/1` / `sample/1`, then filters against the in-log committee.

**`quod_sup` wiring:** replace the `%% TODO` line (`quod_sup.erl:31`) with:

```erlang
#{id => quod_ns_sup, start => {quod_ns_sup, start_link, []}, type => supervisor}
```

placed after `quod_brahms_sup` under the unchanged `one_for_one` flags.

**`quod_app` boot:** a `maybe_start_ns/0` after `maybe_join/0`, mirroring its env reads (including `node_id`
/ `default_node_id()`); add `QUOD_NS_MODE` (`create`|`join`, default `create`):

```erlang
maybe_start_ns() ->
    case os:getenv("QUOD_NAMESPACE") of
        false -> ok; "" -> ok;
        NsStr ->
            Ns   = list_to_binary(NsStr),
            Self = application:get_env(quod, node_id, default_node_id()),
            Mode = case os:getenv("QUOD_NS_MODE") of "join" -> join; _ -> create end,
            Cfg  = #{node_id => Self, mode => Mode,
                     seed_peers => parse_seeds(os:getenv("QUOD_SEEDS")), join_ns => Ns},
            case quod_ns_sup:start_namespace(Ns, Cfg) of
                {ok, _} -> logger:info("quod[~s]: content namespace up (~p)", [Ns, Mode]);
                Error   -> logger:error("quod[~s]: content namespace failed: ~p", [Ns, Error])
            end, ok
    end.
```

Called from `start/2` after `ok = maybe_join()` so Brahms is up first for the join path.

### 5.10 House-style conformance

Supervisors copy `quod_brahms_sup`; workers register via `quod_reg:via/1`, `init/1` takes `{Ns, Config}`,
merges `?DEFAULTS`, `valid_cfg/2`, `{stop, {bad_config, Reason}}`; `quod[~s]` logging; `catch exit:_` /
`catch _:_ -> ok` degradation; `encode/decode` with `[safe]` + size cap; OTP 27+ `-moduledoc`/`-doc`
Markdown; metrics via `get_stats`-style maps + `quod_metrics` gauges driven off the `namespaces/0`
enumerators.

---

## 6. Build order + test plan

The Raft mechanics follow §1; integration follows the `quod_brahms` house style and §5 supervision. Each
milestone is demonstrable on its own and depends only on earlier ones.

### 6.1 Modules added

| module | role | reg key | started by |
| ------ | ---- | ------- | ---------- |
| `quod_ledger` | per-Ns Raft committee member; owns the durable log | `{quod_ledger, Ns}` | `quod_ns` |
| `quod_prolog` | per-Ns facts engine: `apply`/`prove` | `{quod_prolog, Ns}` | `quod_ns` |
| `quod_ledger_store` | on-disk persistence helper (library) | — | — |
| `quod_diff` | pure differ: write-set op-log + read-set hashes | — | — |
| `quod_ns` | per-Ns `rest_for_one` sub-sup | `{quod_ns, Ns}` | `quod_ns_sup` |
| `quod_ns_sup` | `simple_one_for_one` parent of `quod_ns` | `{quod_ns_sup, node}` | `quod_sup` |

Shared types/records live in `include/quod_ledger.hrl` (§ shared header) and `include/quod_ledger_store.hrl`
(§3.2). `#d{}` (§1.3) is the Raft `gen_statem` state.

> **Channel-match hazard (mandatory).** Brahms matches inbound `{quod_message, _, Ns, _}` / `{link_up, _, Ns,
> _}` on `Ns`. `quod_ledger` uses `Chan = term_to_binary({log, Ns}, [deterministic])`, so **every** `quod_ledger`
> receive/link clause MUST bind/guard on `Chan`, not `Ns`. A verbatim copy from brahms that matches on `Ns`
> would silently drop every Raft message.

**Assumption (flagged):** the committee channel is reliable, in-order, point-to-point per peer-pair but not
delivery-guaranteed (§E preamble). `quod_link` provides exactly this; a missing reply is "no reply", retried
on the next heartbeat.

### 6.2 M1 — persistence + single-voter log + apply + prove (one node)

**Goal:** a fully working 1-voter namespace, exercising every Raft code path a single voter runs (#18).

**Build:**

1. **`quod_ledger_store`** (§3) — `open/2`, `load/1`, `write_meta/3`, `append/2`, `truncate_from/2`,
   `write_snapshot/5`, plus the readers. Every mutating call fsyncs before returning; one fsync per
   `append/2` batch. (Single-chunk snapshots; chunking not built.)
2. **`quod_diff`** (pure, `-ifdef(TEST)` exported): `functor_hash(Functor, Arity, Clauses) -> integer()`,
   `read_check(KB, ReferencedFunctors) -> read_check()`, `diff_to_ops(BeforeKB, AfterKB) -> [op()]`,
   `apply_ops(KB, [op()]) -> KB'`. Content-only identity; deterministic apply.
3. **`quod_prolog`** (§4): `prove/3`, `apply_block/3` (`ok | {reject, conflict}`) wrapping the pure engine
   `apply/3`. `prove/3` runs against the local converged KB, returns bindings (not auto-asserted, #6),
   classifies after execution (#8); empty diff ⇒ read (no append); non-empty ⇒ transaction. Effects deferred
   until after commit (#11).
4. **`quod_ledger` gen_statem** (§1): `init/1` (load durable, reconstruct volatile, subscribe on `Chan`, arm
   election timer); brand-new-Ns create bootstrap (`{add, self}`); `append/2` (`{error, conflict_retry}` =
   OCC reject, `{error, busy}` = M5 backpressure); append path (leader, 1-voter: fsync, park `From`, commit
   on local fsync); apply loop (reply parked `From` from the apply step per OCC verdict; fail `pending` on
   tail loss / step-down); self-election as a degenerate normal election (#18).

**Demonstrable:** one node, `start_namespace(Ns, #{node_id => Self, mode => create})`; `append` ⇒ `{ok, 1}`;
`prove` returns the asserted bindings; restart ⇒ log replays from disk, same facts (#20, #29); a read appends
nothing (#6, #10); a second `append` whose `read_check` was invalidated returns `{error, conflict_retry}` and
changes no facts (#14).

### 6.3 M2 — election + replication on 3 nodes

**Goal:** a real N=3 committee over loopback QUIC. No change to M1's commit/apply/persist paths (#18).

**Build (extends `quod_ledger` only):** link management to peers (§2.6 — match on `Chan`); `send_rpc` unicast +
encode-once broadcast; receiving RPCs with the size-guard-before-decode and `[safe]` decode; RequestVote
(§1.6); AppendEntries (§1.7, fsync appended entries before `success`, fail `pending` above a truncation);
leader replication + commit with the mandatory current-term guard (§1.10); election & step-down mechanics
(randomized `[T, 2T]`, persisted self-vote, fail `pending` on step-down).

**Demonstrable:** 3 loopback nodes elect a leader; `append` on the leader commits once 2 of 3 have it (#17);
`append` on a follower returns `{error, not_in_charge, LeaderHint}`; kill the leader ⇒ new leader in ~T,
accepts appends; the three KBs are identical (#13, #25).

### 6.4 M3 — catch-up + snapshot (#29)

Plain catch-up via the AppendEntries back-up loop (no snapshot); compaction after `snapshot_every` committed
entries (`write_snapshot/5` fsync **before** truncating the live log, only the committed prefix);
InstallSnapshot receiver + leader side (`next_index[Peer] <= snap_idx` → send `#install_snapshot{}`). The
`#install_snapshot{}` records are already defined (shared header); InstallSnapshot and compaction land here,
not earlier — so §1 and §3 do not contradict on whether compaction happens.

**Demonstrable:** append many blocks so the leader compacts, then start a fresh 4th node or restart a member
whose log was compacted away ⇒ InstallSnapshot then AppendEntries, KB converges.

### 6.5 M4 — single-server membership change (#19)

`add_member/2` / `remove_member/2` (leader-only, one in flight via `cfg_uncommitted`); adopt-on-append;
leader-removes-itself; new-member catch-up reuses M3. Brahms only finds candidates; the in-log committee is
authoritative (#28).

**Demonstrable:** 3→5 via two sequential `add_member`s (the second blocked until the first commits), serving
appends throughout, then 5→3 including a leader removing itself with clean failover; surviving KBs identical.

### 6.6 M5 — metrics + backpressure

`quod_ledger:stats/1` (§1.14, one snake_case key set); `quod_metrics` gauges (partial-match consumer);
backpressure (`max_pending` → `{error, busy}`; `max_batch` kept under `?CHUNK_BYTES`/1 MiB). CP availability:
under partition the quorum-less side cannot append, surfaced as `{error, not_in_charge, _}`, not a crash.

**Demonstrable:** Prometheus per-Ns leader/term/commit gauges track failover live; flooding a leader returns
`{error, busy}` past the cap.

### 6.7 Test plan

**eunit (pure):** `quod_diff_tests` (op ordering #3; content-only order-independent `functor_hash` #1/#4;
`apply_ops` determinism #25). `quod_prolog` apply re-check (matching read_check ⇒ `{ok, _}`; changed functor
hash ⇒ `{reject, conflict}` #14/#23; determinism #25). `quod_ledger` pure helpers: `quorum/1` (1/3/5 → 1/2/3);
`term_at/2` incl. snapshot sentinel and index-0; the election-restriction truth-table (§1.6); the
**commit-rule current-term-guard** (refuses to commit a prior-term entry even at full replication; commits it
only once a current-term entry above it commits — Figure 8); the AppendEntries truncate-vs-skip decision incl.
the **idempotent same-term-skip that must NOT truncate on a delayed/duplicate RPC**. `quod_ledger_store`
round-trip + **durability ordering** (each mutating call returns only after fsync).

**Common Test over loopback QUIC:**

1. `raft_single_voter_SUITE` (M1): self-elect, `append` ⇒ `{ok, 1}`, `prove` returns bindings (not
   auto-asserted #6); restart ⇒ replays, same KB; a read appends nothing; a stale-`read_check` `append`
   returns `{error, conflict_retry}` and leaves facts unchanged.
2. `raft_safety_SUITE` (M2) — core safety: no two leaders per term; **double-vote prevention across crash**
   (persist `(cur_term, voted_for)` before the grant reply); leader failover within bounded timeouts +
   `pending` failed `{error, not_in_charge, _}`; log convergence (byte-identical up to `commit_index`, equal
   KBs); election restriction; **prior-term commit (Figure 8 scenario)**.
3. `raft_replay_SUITE`: feed a captured committed log through `quod_prolog`'s apply path on a fresh engine ⇒
   identical KB incl. identical accept/reject verdicts on OCC no-op blocks (#13, #25).
4. `raft_catchup_SUITE` (M3): fresh node back-up; compacted-member InstallSnapshot; restart-from-own-history
   delta catch-up.
5. `raft_membership_SUITE` (M4): 3→5 with the second `add_member` blocked until the first commits; 5→3;
   leader-removes-itself; no two-leader window.
6. `occ_conflict_SUITE`: A `prove`s a `#transaction{}` with a non-empty `read_check`; before A's `append` commits,
   B mutates a functor in A's `read_check`; A's `apply_block` re-checks at its write's log position, rejects,
   A's caller gets `{error, conflict_retry}` and retries — committed KB reflects B then A's retry in log
   order. Negative: a disjoint `read_check` commits without abort. Per-predicate granularity: a same-functor
   different-fact change still aborts (accepted MVP false conflict #4).

**Cross-cutting:** committed prefixes identical across members; `last_applied` monotone, never a different
entry at the same index; no `quod_ledger` crash on transient link drops (`{'DOWN', ...}` handled in `common/3`);
no `pending` `From` left without a reply after its index commits, is truncated, or its leader steps down.

---

## 7. Open questions / out of scope for Phase 1

Out of scope (each has a design home, deferred):

- **Foreign / cross-namespace writes** — only own-namespace writes + cross-namespace reads (#10); owner-
  executes-through-its-own-rules + cross-node commit-coupling + ACL/`::` authorization owed later.
- **Byzantine (BFT) agreement** — the committee runs Raft (crash-fault) only (#30); a BFT recipe under the
  same `append`/`apply` interface is later (#31).
- **Cryptographic identity & signing** — Phase 1 runs single-operator with `server_id() = {Host, Port}` and
  a keypair generated-but-unused; `#transaction.author`/`#transaction.sig` slots are reserved and verification is
  stubbed (see *Identity & signing readiness*). Real identity (`pubkey()` replaces `{Host, Port}` + signed
  admission record), signed changes, and BFT block commit certificates come with the survive-lies work.
- **Read-copies fan-out / the three read tiers** (#22) — Phase 1 reads hit a committee member's converged KB
  directly; replicating current facts out to non-committee read-copies is deferred.
- **`local_history` archive-holders** — full history is committee-only in the first cut (#21); read-copies
  hold current facts only.
- **History trimming** — the block list is kept in full permanently (#20); snapshotting (M3) compacts only
  the materialized live log, never the durable browsable block list.
- **Per-fact read-set granularity** — MVP hashes whole predicates (#4); same-functor different-fact changes
  cause accepted false conflicts; the read-set→notification index is also later.
- **Consistent cross-namespace snapshots** — read skew across namespaces tolerated (#7 caveat); no snapshots
  retained for reads.
- **Exactly-once effects across crashes** — effects-after-commit is at-most-once (no effect log).
- **Reactive event system** (`react_on` / D-P-E / live notifications, the
  read-set→notification index, cross-ontology notify) — Phase 2; see
  `content-layer-design.md` §14. Phase 1's only reactions are a write's own deferred
  effects, fired once on the submitting node at commit, never on other members,
  never on replay (§4.5–4.6, at-most-once).
- **Adaptive committee sizing / partition heal** — parked.

Open questions to resolve before/during build:

- Default `data_dir` and whether per-namespace dirs are base64url-encoded (assumed yes; flag for review).
- Whether `QUOD_NAMESPACE` doubles as both the Brahms membership id and the content namespace id (assumed
  yes for MVP; add `QUOD_CONTENT_NAMESPACE` if they ever diverge).
- Whether the leader keeps an optional pre-append OCC fast-fail (`quod_ledger:append` returning `{error,
  conflict_retry}` before replication) in addition to the authoritative apply-time gate, or relies solely on
  apply-time rejection.
