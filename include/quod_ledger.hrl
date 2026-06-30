%%% include/quod_ledger.hrl
%%% Canonical types + records for the quod ordering/content layer
%%% (`quod_ledger`, `quod_prolog`, `quod_ledger_store`, and their tests).
%%% Defined ONCE here and `-include`d everywhere — the single source of truth.
%%% See doc/ordering-layer-spec.md.
-ifndef(QUOD_LOG_HRL).
-define(QUOD_LOG_HRL, true).

-type term_no()   :: non_neg_integer().      %% Raft term, starts at 0
-type log_index() :: non_neg_integer().      %% 0 = empty-log / snapshot sentinel; entries are 1..N
-type server_id() :: {inet:hostname(), inet:port_number()}.   %% == Brahms NodeId == {Host, Port}
-type pubkey()    :: binary().               %% Ed25519 public key — the REAL identity (later; see spec)

%% A Prolog clause; identity is its content only (Head + Body).
-type clause() :: {Head :: term(), Body :: term()}.   %% Body == true for a plain fact
%% The differ's write-set: an ordered op-log of asserts/retracts.
-type op()     :: {assert, clause()} | {retract, clause()}.
%% The read-set: one content hash per predicate {Functor, Arity}.
-type read_check() :: #{ {Functor :: atom(), Arity :: non_neg_integer()} => integer() }.

%% The committed change record.
%% `author`/`sig` are RESERVED for signing (identity readiness): Phase 1 sets
%% author = self node id and sig = none, and verification is a pass-through stub.
-record(transaction, {tx_id      :: binary(),            %% unique per transaction (ulid)
                 caller_ns  :: binary(),            %% emitting ontology (CallerNs)
                 diff       :: [op()],              %% concrete asserts/retracts
                 read_check :: read_check(),        %% what the proof relied on (OCC)
                 author     :: server_id(),         %% who submitted it (Phase 1: node id; later: pubkey())
                 sig = none :: binary() | none}).   %% Ed25519 sig over canonical bytes; none in Phase 1

%% A Raft log entry. `data` is a #transaction{} for `block` entries, the atom `noop`
%% for the election marker, or a membership op for `config` entries. The membership ops:
%% `{add, S}` seeds a founding voter; `{add_learner, S}` admits a non-voting catch-up member
%% (to be promoted); `{add_replica, S}` admits a PERMANENT non-voting full-copy replica (a read
%% replica — fed like a learner but never promoted); `{promote, S}` turns a learner into a
%% voter; `{remove, S}` drops a member.
-type member_op() :: {add,         server_id()}
                   | {add_learner, server_id()}
                   | {add_replica, server_id()}
                   | {promote,     server_id()}
                   | {remove,      server_id()}.
-record(entry, {index :: log_index(),
                term  :: term_no(),
                kind  :: block | config,
                data  :: #transaction{} | noop | member_op()}).

%% --- the six Raft RPC records (snake_case fields) ---
-record(request_vote,         {term           :: term_no(),
                               candidate_id   :: server_id(),
                               last_log_index :: log_index(),
                               last_log_term  :: term_no()}).
-record(request_vote_reply,   {term         :: term_no(),
                               vote_granted :: boolean()}).
-record(append_entries,       {term           :: term_no(),
                               leader_id      :: server_id(),
                               prev_log_index :: log_index(),
                               prev_log_term  :: term_no(),
                               entries        :: [#entry{}],   %% [] for a heartbeat
                               leader_commit  :: log_index()}).
-record(append_entries_reply, {term        :: term_no(),
                               success     :: boolean(),
                               match_index :: log_index()}).   %% success: matched idx; fail: conflict hint
-record(install_snapshot,     {term                :: term_no(),
                               leader_id           :: server_id(),
                               last_included_index :: log_index(),
                               last_included_term  :: term_no(),
                               config              :: [server_id()],
                               data                :: binary()}).
-record(install_snapshot_reply, {term :: term_no()}).

%% --- join handshake (membership growth; rides the same {log, Ns} channel) ---
%% A fresh node (mode=join) unicasts #join_request{} to a contact; the leader admits it
%% as a non-voting learner ({add_learner}) after proving `can_join`, then catches it up
%% and promotes it. `pubkey` is RESERVED (none in Phase 1) so signed admission slots in
%% later with no shape change. #join_reply{} carries the leader's disposition; the actual
%% membership state reaches the joiner through the replicated config entries (AppendEntries).
-record(join_request, {joiner :: server_id(),
                       pubkey = none :: pubkey() | none,
                       args   = #{}  :: map()}).
-record(join_reply,   {result :: learner_admitted | already_member
                                | {redirect, server_id() | none}
                                | {denied, term()}}).

-endif.
