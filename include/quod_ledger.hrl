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
%% The differ's ordered material operations: fact mutations plus explicit
%% occurrences which the reducer publishes without mutating ontology facts.
-type op()     :: {assert, clause()} | {retract, clause()} | {event, term()}.
%% The read-set: one exact mutation-version token per predicate {Functor, Arity}.
%% This header owns the token alphabet — it is part of the signed transaction
%% bytes; the MVCC store implements it (`quod_erlog_db_mvcc:version_token/2`).
%% `{present, Slot}`/`{absent, Slot}` name the last committed mutation height at
%% the reader's snapshot; `absent` means that mutation left no clauses to serve
%% (a retraction that emptied the predicate, or an abolish tombstone), so
%% absent → present → absent still conflicts by height. `never_present` means no
%% committed mutation existed; `static` names an unwritable built-in/compiled
%% predicate. The transient `staged` marker used during same-block validation is
%% deliberately NOT part of this alphabet and is rejected on the wire.
-type read_token() :: never_present
                    | {present, non_neg_integer()}
                    | {absent, non_neg_integer()}
                    | static.
-type prolog_symbol() :: atom() | {'$quod_symbol', binary()}.
-type read_check() ::
        #{ {Functor :: prolog_symbol(), Arity :: non_neg_integer()} =>
               read_token() }.

%% The committed change record. Every non-genesis transaction carries an Ed25519
%% signature over canonical bytes bound to the TARGET's immutable identity
%% `{Ns, GenesisAnchor, AuthorAdmission}` (owned by `quod_transaction`);
%% `author` is the submitting node's 32-byte public key and AuthorAdmission is
%% its current continuous membership generation. Only anchored genesis uses
%% `sig = none`.
%% A transaction is built from a sealed local plan (`m:quod_dtx`): `origin`
%% names the proof's origin ontology, `proof_id` the distributed proof, and
%% `plan_digest` the canonical unsigned plan bytes — `none` only for genesis.
-record(transaction, {tx_id      :: binary(),            %% target-bound digest of the complete semantic write
                 role = application :: application |
                                       {remote_application, term(), term(), binary()} |
                                       {remote_claim, term(), term(), binary()} |
                                       {remote_complete, term(), binary(), term()},
                                                        %% one canonical content family: Prolog application or
                                                        %% operation metadata; evidence has dedicated fields below
                 evidence = none :: none | {term(), tuple()},
                                                        %% exact referenced record + certified ledger ref;
                                                        %% signed but excluded from semantic identity
                 foreign_reads = [] :: [term()],       %% certified read-only plan statements;
                                                        %% signed but excluded from semantic identity
                 origin       :: {binary(), binary()},%% proof origin identity {OriginNs, OriginAnchor}; genesis = {Ns, <<0:256>>}
                 proof_id = none :: binary() | none,  %% 32-byte distributed-proof id; none only for genesis
                 plan_digest = none :: binary() | none, %% SHA-256 of the sealed plan's canonical bytes; none only for genesis
                 goal = undefined :: binary() | undefined, %% canonical atom-safe goal blob; undefined only for genesis
                 result = undefined :: binary() | undefined, %% canonical atom-safe sorted bindings blob; undefined only for genesis
                 diff         :: [op()],              %% concrete fact mutations and explicit events
                 read_check   :: read_check(),        %% what the proof relied on (OCC)
                 effects = [] :: [quod_effect:effect()], %% bounded typed direct effects; never callbacks/goals
                 request_auth = none :: none | quod_client_goal:request_auth(),
                                                        %% exact signed user intent; none for node/genesis work
                 auth_transcript = none :: none | {agent_goal_v1, binary()},
                                                        %% one canonical top-level can_invoke transcript
                 author = none :: node_id() | none,    %% set to the submitting node's pubkey before ingress
                 author_seq = 0 :: non_neg_integer(), %% signed, strictly increasing per author; 0 only before ingress/genesis
                 submitted_at = 0 :: non_neg_integer(), %% client submit wall-clock (ms since Unix epoch); 0 = unset/genesis. Advisory (self-reported).
                 sig = none   :: binary() | none,     %% 64-byte Ed25519 signature; none only for genesis
                 signed_bytes = none :: binary() | none}). %% exact canonical bytes covered by `sig`; a derived view never replaces them

%% --- DispersedSimplex consensus records (doc/simplex_extended.pdf) ---
%% A slot is a consensus height: the leader for slot v proposes one block; validators support
%% (notarize) then commit (finalize) it, or complain (skip) v. No block-hash chaining — slot
%% numbers + certificates carry the order (§2, "hash chaining turns out to be unnecessary").
-type slot() :: non_neg_integer().               %% 0 = origin sentinel (parent of slot 1); blocks are 1..N
                                                 %% (the founder's self-signed genesis BLOCK is slot 1)

%% One proposed/committed block payload.  The single `{batch, Items}` family is
%% homogeneous: either ordinary transactions, or canonical DTX-control blobs
%% from one protocol phase.  The ledger classifier rejects empty, mixed,
%% malformed, duplicate, and non-canonical batches.
-type block_payload() :: {batch, nonempty_list(#transaction{})}
                       | {batch, nonempty_list({dtx, binary()})}.

%% A proposed block for a slot. `payload` is one tagged `block_payload()` (a
%% membership change remains an ordinary #transaction asserting/retracting
%% `peer_admitted`). `parent` is
%% the previous APPROVED slot it extends (0 = genesis). It may therefore be newer than the durable
%% committed head while consensus is pipelined.
%% `timestamp` is the leader's propose wall-clock (ms since Unix epoch) — the canonical block time (cf.
%% Bitcoin nTime / Ethereum block.timestamp / CometBFT block.Time). It is inside the exact producer-owned
%% `block_bytes`, so a committed block's timestamp is covered by its cert. The
%% leader sets it monotonic (≥ the parent block's timestamp); validators reject a proposal that goes
%% backwards. 0 = genesis/origin; the sole creator fixes it in the anchored slot-1 block. The decoded
%% fields are only a local view of those hashed bytes. Future hardening: a
%% CometBFT-style voting-power-weighted median of validator timestamps instead of the leader's single clock.
-record(block, {slot      :: slot(),
                parent    :: slot(),
                payload   :: block_payload(),
                timestamp = 0 :: non_neg_integer(),
                block_bytes = none :: binary() | none}). %% producer-owned canonical identity; other fields are its decoded view

%% A signed vote from ONE validator. `kind`: `support` (notarize) / `commit` (finalize) /
%% `complaint` (timeout→skip the slot). `block_hash` binds a support/commit share to a specific
%% block (`none` for a complaint — it is slot-only). `signer` = the validator's pubkey (node_id);
%% `sig` = Ed25519 over the canonical share bytes (`quod_simplex:share_bytes/4`),
%% including the locally-derived namespace/genesis consensus domain.
-record(share, {kind       :: support | commit | complaint,
                slot       :: slot(),
                block_hash :: binary() | none,
                signer     :: node_id(),
                sig        :: binary()}).

%% A quorum certificate = a bag of ≥⅔ `share`s of the SAME (kind, slot, block_hash) from distinct
%% validators. `sigs` = `[{signer_pubkey, sig}]`. Verification requires both the known validator set
%% and the trusted local namespace/genesis domain — this IS the P2 relayed-commit proof: a subscriber
%% verifies a block without trusting the relay or accepting a certificate from another ontology/chain.
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

%% What one committed slot carries. A proposed block's tagged payload is stored
%% byte-for-byte; complaint-certified skips additionally use `noop`. The
%% variants are enumerated in exactly one place -- `quod_ledger:classify/1` --
%% so a new kind cannot be silently folded as nothing at a forgotten consumer.
-type entry_data() :: block_payload() | noop.

%% The native view of a committed log entry. Live readers/transport/store carry
%% quod_ledger:entry_artifact(); obtain this view through entry_view/1. The
%% record shape is retained in prepared lifecycle descriptors, not as a second
%% append API. `data` is the exact tagged block payload, or the atom
%% `noop` for a complaint-skipped slot. Genesis is a `{batch, [GenesisTx]}`.
%% `cert` is claimed finality evidence, not a codec authentication verdict —
%% after verification, a COMMIT cert (direct or implicit), a COMPLAINT cert for a `noop` skip, or `none` for the
%% self-signed genesis (slot 1, verified out-of-band, not by a cert). A catch-up joiner verifies each
%% entry against its `cert` (trustless replay). Membership is NOT a distinct entry kind: the committee
%% is the set of `peer_admitted` facts (`quod_simplex:log_projection/2`). `index` doubles as the
%% slot number (commits are strictly in order, one entry per slot).
-record(entry, {index       :: log_index(),
                data        :: entry_data(),
                timestamp = 0 :: non_neg_integer(), %% mirrors the committed block's covered timestamp for local consumers;
                                                    %% the artifact retains the block view bound to `block_bytes`.
                                                    %% 0 for a `noop` skip (no block) / genesis.
                block_bytes = none :: binary() | none, %% exact committed block bytes; `none` only for a complaint skip
                cert = none :: term()}). %% A decoded view is not a finality verdict;
                                        %% the forward verifier checks certificate shape/signatures.

-endif.
