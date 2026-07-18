%%% include/quod_ledger.hrl
%%% Canonical types + records for the quod content/ordering layer
%%% (`quod_simplex` consensus, `quod_prolog` fact engine, `quod_ledger_store`, and their tests).
%%% Defined ONCE here and `-include`d everywhere — the single source of truth.
-ifndef(QUOD_LOG_HRL).
-define(QUOD_LOG_HRL, true).

-type log_index() :: non_neg_integer().      %% 0 = empty-log / origin sentinel; entries are 1..N
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

%% The committed change record. Every non-genesis transaction carries an Ed25519
%% signature over the namespace-bound canonical bytes owned by `quod_transaction`;
%% `author` is the submitting node's 32-byte public key. Only anchored genesis uses
%% `sig = none`.
-record(transaction, {tx_id      :: binary(),            %% client correlation id; uniqueness is enforced by author_seq
                 caller_ns    :: binary(),            %% emitting ontology (CallerNs)
                 goal = undefined :: term(),          %% successful Prolog goal that produced this write
                 result = undefined :: term(),        %% bindings returned by that proof
                 diff         :: [op()],              %% concrete asserts/retracts
                 read_check   :: read_check(),        %% what the proof relied on (OCC)
                 author       :: node_id(),           %% submitting node's pubkey
                 author_seq = 0 :: non_neg_integer(), %% signed, strictly increasing per author; 0 only before ingress/genesis
                 submitted_at = 0 :: non_neg_integer(), %% client submit wall-clock (ms since Unix epoch); 0 = unset/genesis. Advisory (self-reported).
                 sig = none   :: binary() | none}).   %% 64-byte Ed25519 signature; none only for genesis

%% --- DispersedSimplex consensus records (doc/simplex_extended.pdf) ---
%% A slot is a consensus height: the leader for slot v proposes one block; validators support
%% (notarize) then commit (finalize) it, or complain (skip) v. No block-hash chaining — slot
%% numbers + certificates carry the order (§2, "hash chaining turns out to be unnecessary").
-type slot() :: non_neg_integer().               %% 0 = origin sentinel (parent of slot 1); blocks are 1..N
                                                 %% (the founder's self-signed genesis BLOCK is slot 1)

%% A proposed block for a slot. `payload` is a non-empty batch of transactions.
%% a membership change is an ordinary #transaction asserting/retracting `peer_admitted`). `parent` is
%% the previous APPROVED slot it extends (0 = genesis). It may therefore be newer than the durable
%% committed head while consensus is pipelined.
%% `timestamp` is the leader's propose wall-clock (ms since Unix epoch) — the canonical block time (cf.
%% Bitcoin nTime / Ethereum block.timestamp / CometBFT block.Time). It is hashed with the rest of the block
%% (`block_hash/1` hashes the whole record), so a committed block's timestamp is covered by its cert. The
%% leader sets it monotonic (≥ the parent block's timestamp); validators reject a proposal that goes
%% backwards. 0 = genesis/origin (kept deterministic so co-founders agree). Future hardening: a
%% CometBFT-style voting-power-weighted median of validator timestamps instead of the leader's single clock.
-record(block, {slot      :: slot(),
                parent    :: slot(),
                payload   :: [#transaction{}],
                timestamp = 0 :: non_neg_integer()}).

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

%% Proof that an approved block was committed implicitly by its immediate child.
%% `support` binds this entry's exact block; `commit` binds `child`; and the child
%% names this slot as its parent. With quorum intersection, an honest child-commit
%% signer only signs after the parent is in its complete block tree. Runtime
%% pipelining is depth one, so no longer ancestry path is needed.
-record(implicit_cert, {support :: #cert{},
                        child   :: #block{},
                        commit  :: #cert{}}).

%% A committed log entry. `data` is a canonical `{batch, [#transaction{}]}` block payload,
%% or the atom `noop` for a complaint-skipped slot. Genesis uses the same batch format.
%% `cert` is the quorum certificate that finalized the slot —
%% the COMMIT cert for a #transaction, the COMPLAINT cert for a `noop` skip, or `none` for the
%% self-signed genesis (slot 1, verified out-of-band, not by a cert). A catch-up joiner verifies each
%% entry against its `cert` (trustless replay). Membership is NOT a distinct entry kind: the committee
%% is the set of `peer_admitted` facts (`quod_simplex:log_projection/2`). `index` doubles as the
%% slot number (commits are strictly in order, one entry per slot).
-record(entry, {index       :: log_index(),
                data        :: {batch, [#transaction{}]} | noop,
                timestamp = 0 :: non_neg_integer(), %% mirrors the committed block's `timestamp` — quod stores no header, so
                                                    %% catch-up rebuilds `#block{...}` from the entry and needs this to
                                                    %% reproduce the block_hash. 0 for a `noop` skip (no block) / genesis.
                cert = none :: #cert{} | #implicit_cert{} | none}).

-endif.
