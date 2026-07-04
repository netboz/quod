%%% include/quod_ledger.hrl
%%% Canonical types + records for the quod content/ordering layer
%%% (`quod_simplex` consensus, `quod_prolog` fact engine, `quod_ledger_store`, and their tests).
%%% Defined ONCE here and `-include`d everywhere — the single source of truth.
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

%% --- DispersedSimplex consensus records (doc/simplex_extended.pdf) ---
%% A slot is a consensus height: the leader for slot v proposes one block; validators support
%% (notarize) then commit (finalize) it, or complain (skip) v. No block-hash chaining — slot
%% numbers + certificates carry the order (§2, "hash chaining turns out to be unnecessary").
-type slot() :: non_neg_integer().               %% 0 = origin sentinel (parent of slot 1); blocks are 1..N
                                                 %% (the founder's self-signed genesis BLOCK is slot 1)

%% A proposed block for a slot. `payload` is a batch of committed changes (a #transaction or `noop`;
%% a membership change is an ordinary #transaction asserting/retracting `peer_admitted`). `parent` is
%% the previous committed slot it extends (0 = genesis).
-record(block, {slot    :: slot(),
                parent  :: slot(),
                payload :: [#transaction{} | noop]}).

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

%% A committed log entry. `data` is a #transaction{} for a normal committed change, or the atom
%% `noop` for a complaint-skipped slot. `cert` is the quorum certificate that finalized the slot —
%% the COMMIT cert for a #transaction, the COMPLAINT cert for a `noop` skip, or `none` for the
%% self-signed genesis (slot 1, verified out-of-band, not by a cert). A catch-up joiner verifies each
%% entry against its `cert` (trustless replay). Membership is NOT a distinct entry kind: the committee
%% is the set of `peer_admitted` facts (`quod_simplex:committee_from_log/1`).
-record(entry, {index       :: log_index(),
                term        :: term_no(),
                kind        :: block,
                data        :: #transaction{} | noop,
                cert = none :: #cert{} | none}).

-endif.
