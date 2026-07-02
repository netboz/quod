%%% include/quod_ledger.hrl
%%% Canonical types + records for the quod ordering/content layer
%%% (`quod_ledger`, `quod_prolog`, `quod_ledger_store`, and their tests).
%%% Defined ONCE here and `-include`d everywhere — the single source of truth.
%%% See doc/ordering-layer-spec.md.
-ifndef(QUOD_LOG_HRL).
-define(QUOD_LOG_HRL, true).

-type term_no()   :: non_neg_integer().      %% Raft term, starts at 0
-type log_index() :: non_neg_integer().      %% 0 = empty-log / snapshot sentinel; entries are 1..N
-type pubkey()    :: binary().               %% Ed25519 public key (32 bytes)
-type endpoint()  :: {inet:hostname(), inet:port_number()}.   %% where a node is dialed — a routing hint
%% A node's STABLE identity is its pubkey. (Transitional: the no-identity/test path still uses an
%% `endpoint()` as the id, so `node_id()` admits both until those suites migrate to keypairs.)
-type node_id()   :: pubkey() | endpoint().
%% Identity is the `node_id()` (the pubkey); `endpoint()` is only "where it is now" (a seed/contact/
%% redirect target, resolved on connect). Membership entries are node_id-only, so a host move never
%% rewrites the durable log; the address travels as a hint (gossip / the link header).

%% A Prolog clause; identity is its content only (Head + Body).
-type clause() :: {Head :: term(), Body :: term()}.   %% Body == true for a plain fact
%% The differ's write-set: an ordered op-log of asserts/retracts.
-type op()     :: {assert, clause()} | {retract, clause()}.
%% The read-set: one content hash per predicate {Functor, Arity}.
-type read_check() :: #{ {Functor :: atom(), Arity :: non_neg_integer()} => integer() }.

%% The committed change record. `sig` is RESERVED for signing (Phase B): it stays `none`
%% until node-author signatures land; `author` is the submitting node's pubkey.
-record(transaction, {tx_id      :: binary(),            %% unique per transaction (ulid)
                 caller_ns  :: binary(),            %% emitting ontology (CallerNs)
                 diff       :: [op()],              %% concrete asserts/retracts
                 read_check :: read_check(),        %% what the proof relied on (OCC)
                 author     :: node_id(),           %% submitting node's pubkey
                 sig = none :: binary() | none}).   %% Ed25519 sig over canonical bytes; none until Phase B

%% A Raft log entry. `data` is a #transaction{} for `block` entries, the atom `noop`
%% for the election marker, or a membership op for `config` entries. The membership ops:
%% `{add, S}` seeds a founding voter; `{add_learner, S}` admits a non-voting catch-up member
%% (to be promoted); `{add_replica, S}` admits a PERMANENT non-voting full-copy replica (a read
%% replica — fed like a learner but never promoted); `{promote, S}` turns a learner into a
%% voter; `{remove, S}` drops a member.
-type member_op() :: {add,         node_id()}
                   | {add_learner, node_id()}
                   | {add_replica, node_id()}
                   | {promote,     node_id()}
                   | {remove,      node_id()}.
-record(entry, {index :: log_index(),
                term  :: term_no(),
                kind  :: block | config,
                data  :: #transaction{} | noop | member_op()}).

%% --- DispersedSimplex consensus records (doc/simplex_extended.pdf) ---
%% A slot is a consensus height: the leader for slot v proposes one block; validators support
%% (notarize) then commit (finalize) it, or complain (skip) v. No block-hash chaining — slot
%% numbers + certificates carry the order (§2, "hash chaining turns out to be unnecessary").
-type slot() :: non_neg_integer().               %% 0 = genesis; blocks are 1..N

%% A proposed block for a slot. `payload` is a batch of committed changes (a #transaction, a
%% membership op, or `noop`). `parent` is the previous committed slot it extends (0 = genesis).
-record(block, {slot    :: slot(),
                parent  :: slot(),
                payload :: [#transaction{} | member_op() | noop]}).

%% A signed vote from ONE validator. `kind`: `support` (notarize) / `commit` (finalize) /
%% `complaint` (timeout→skip the slot). `block_hash` binds a support/commit share to a specific
%% block (`none` for a complaint — it is slot-only). `signer` = the validator's pubkey (node_id);
%% `sig` = Ed25519 over the canonical share bytes (`quod_simplex:share_bytes/3`).
-record(share, {kind       :: support | commit | complaint,
                slot       :: slot(),
                block_hash :: binary() | none,
                signer     :: node_id(),
                sig        :: binary()}).

%% A quorum certificate = a bag of ≥⅔ `share`s of the SAME (kind, slot, block_hash) from distinct
%% validators. `sigs` = `[{signer_pubkey, sig}]`. Self-verifying against the known validator set —
%% this IS the P2 relayed-commit proof: a subscriber verifies a block by its commit cert without
%% trusting the relay.
-record(cert, {kind       :: support | commit | complaint,
               slot       :: slot(),
               block_hash :: binary() | none,
               sigs       :: [{node_id(), binary()}]}).

%% --- the Raft RPC records (snake_case fields) ---
%% Pre-vote (Ra-style, per the Raft thesis §9.6): a non-binding trial election run before a real
%% one. It carries the node's CURRENT term (not term+1); the `token` is a fresh `make_ref()` that
%% correlates a reply to its round (pre-votes never bump the term, so one term hosts many rounds
%% and the token — not the term — is the round id). The grant rule + why it bounds the term and
%% protects a live leader live in `quod_ledger:pre_vote_grant/4` and `start_pre_vote/1`.
-record(pre_vote,             {term           :: term_no(),
                               token          :: reference(),
                               candidate_id   :: node_id(),
                               last_log_index :: log_index(),
                               last_log_term  :: term_no()}).
-record(pre_vote_reply,       {term         :: term_no(),
                               token        :: reference(),
                               vote_granted :: boolean()}).
-record(request_vote,         {term           :: term_no(),
                               candidate_id   :: node_id(),
                               last_log_index :: log_index(),
                               last_log_term  :: term_no()}).
-record(request_vote_reply,   {term         :: term_no(),
                               vote_granted :: boolean()}).
-record(append_entries,       {term           :: term_no(),
                               leader_id      :: node_id(),
                               prev_log_index :: log_index(),
                               prev_log_term  :: term_no(),
                               entries        :: [#entry{}],   %% [] for a heartbeat
                               leader_commit  :: log_index()}).
-record(append_entries_reply, {term        :: term_no(),
                               success     :: boolean(),
                               match_index :: log_index()}).   %% success: matched idx; fail: conflict hint
-record(install_snapshot,     {term                :: term_no(),
                               leader_id           :: node_id(),
                               last_included_index :: log_index(),
                               last_included_term  :: term_no(),
                               config              :: [node_id()],
                               data                :: binary()}).
-record(install_snapshot_reply, {term :: term_no()}).

%% --- join handshake (membership growth; rides the same {log, Ns} channel) ---
%% A fresh node (mode=join) unicasts #join_request{} to a contact (an endpoint); the leader
%% admits it as a non-voting learner ({add_learner}) after proving `can_join`, then catches it
%% up and promotes it. `joiner` is the joiner's PUBKEY (its node_id), bound by the leader to the
%% connection's TLS-authenticated pubkey before admission (the possession gate). A `{redirect, _}`
%% carries the leader's ENDPOINT (a resolved address) so the joiner can dial it; the membership
%% itself reaches the joiner through the replicated config entries (AppendEntries).
-record(join_request, {joiner :: node_id(),
                       args   = #{}  :: map()}).
-record(join_reply,   {result :: learner_admitted | already_member
                                | {redirect, endpoint() | none}
                                | {denied, term()}}).

-endif.
