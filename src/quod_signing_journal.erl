-module(quod_signing_journal).
-moduledoc """
Crash-durable signing state for one ontology on one validator.

The journal is the sole local anti-equivocation authority for consensus votes
and DTX sequence allocation. A support decision retains the exact canonical
block in the same synced frame until the selected ancestry and material group
are durably archived, so restart cannot lose the body named by the durable
latch. Its one pending atomic row owns source
responsibility before private binding, bound own material before selection,
and finally this role's signed vote for redriving after a crash. Every new
decision is persisted and datasync'd before its signature may be exposed.

Initialization and recovery are deliberately separate.  `initialize/3` is
the empty-ledger operation and may replace only a provably unused journal;
`recover/3` opens only an existing domain-bound journal and never uses a raw
ledger height to prune it.  `reconcile/2` is the sole pruning operation and
accepts only the compact result of an already-validated history fold.
""".

-include("quod_ingress_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

-export([initialize/3, recover/3, reconcile/2, close/1,
         rounds/1, supported_block/2, dtx_floor/2, pending_dtx/1,
         pending_transactions/1,
         record_support/2, record_vote/4, record_dtx/2, record_dtx_intent/2, record_transaction/4,
         bind_transaction/2,
         activate_transaction/2, retire_transaction/2]).
-export_type([handle/0, round/0, final_vote/0, lane/0,
              pending_dtx_row/0, pending_dtx/0]).

-ifdef(TEST).
-export([compact/1, test_frame/1, test_max_frame_payload_bytes/0, supported_blocks/1]).
-endif.

%% New file and record domain.  Recognized superseded vote/signing-journal
%% formats are rejected explicitly at every frame boundary, including a
%% four-byte short tail.
-define(QVJ1_MAGIC, 16#51564A31). %% "QVJ1"
-define(QVJ2_MAGIC, 16#51564A32). %% "QVJ2"
-define(QVJ3_MAGIC, 16#51564A33). %% "QVJ3"
-define(QSJ1_MAGIC, 16#51534A31). %% "QSJ1"
-define(QSJ2_MAGIC, 16#51534A32). %% "QSJ2"
-define(QSJ3_MAGIC, 16#51534A33). %% transaction V13 envelopes
-define(QSJ4_MAGIC, 16#51534A34). %% Begin/Prepare/Decision/Finalize envelopes
-define(QSJ5_MAGIC, 16#51534A35). %% slot-bound atomic Vote/Resolve/Complete
-define(QSJ6_MAGIC, 16#51534A36). %% era/view bodies without signed material height
-define(MAGIC,      16#51534A37). %% "QSJ7": signed material height
-define(FORMAT_VERSION, 7).
-define(HDR_BYTES, 12).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).
-define(COMPACT_BYTES, (1024 * 1024)).

%% Exact deterministic-ETF overhead of
%% {quod_signing_pending_dtx,7,Admission,Author,MaxU64,Group,Body,Envelope}
%% outside the two variable blobs.  The boundary therefore follows the shared
%% DTX limits automatically instead of duplicating their current values.
-define(PENDING_WRAPPER_BYTES, 163).
-define(MAX_FRAME_PAYLOAD_BYTES,
        max((?QUOD_MAX_DTX_BODY_BYTES + ?QUOD_MAX_DTX_CONTROL_BYTES +
             ?PENDING_WRAPPER_BYTES), (?MAX_BLOCK_BYTES + 4096))).

-type block_hash() :: <<_:256>>.
-type final_vote() :: none | {commit, block_hash()} | complaint.
-type round() :: #{support := none | block_hash(), final := final_vote()}.
-type position() :: {<<_:256>>, pos_integer()}.
-type rounds() :: #{position() => round()}.
-type lane() :: {<<_:256>>, <<_:256>>}. %% {AuthorAdmission, Author}
-type pending_dtx_row() ::
        #{lane := lane(), sequence := non_neg_integer(),
          intent := <<_:256>>, group_ref := tuple(), body := binary(),
          material := quod_atomic:admission_material(), envelope := none | binary()}.
-type pending_dtx() :: #{<<_:256>> => pending_dtx_row()}.

-record(journal, {
          fd :: file:io_device(),
          path :: file:filename_all(),
          domain :: <<_:256>>,
          offset = 0 :: non_neg_integer(),
          ever_used = false :: boolean(),
          rounds = #{} :: rounds(),
          dtx_floors = #{} :: #{lane() => non_neg_integer()},
          pending_dtx = #{} :: pending_dtx(),
          transactions = #{} :: #{binary() =>
              #{admission := <<_:256>>, sequence := pos_integer(),
                state := dormant | bound | ready, body := binary(),
                envelope := binary()}}
         }).
-opaque handle() :: #journal{}.

%%%===================================================================
%%% public API
%%%===================================================================

-doc "Create or replace the unused signing journal for an empty ledger.".
-spec initialize(binary(), <<_:256>>, file:filename_all()) -> {ok, handle()}.
initialize(Ns, Domain, DataDir)
  when is_binary(Ns), is_binary(Domain), byte_size(Domain) =:= 32 ->
    Dir = quod_ledger_store:ns_dir(DataDir, Ns),
    Path = journal_path(Dir),
    ok = quod_file:ensure_parent(Path),
    ok = require_replaceable(Path),
    Tmp = temporary_path(Dir),
    _ = file:delete(Tmp),
    Header = frame(encode(
                     {quod_signing_header, ?FORMAT_VERSION, Domain, false})),
    {ok, TmpFd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(TmpFd, Header),
        ok = file:datasync(TmpFd)
    after
        _ = file:close(TmpFd)
    end,
    ok = file:rename(Tmp, Path),
    ok = quod_file:sync_dir(Dir),
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    {ok, #journal{fd = Fd, path = Path, domain = Domain,
                  offset = byte_size(Header)}};
initialize(_, _, _) ->
    error(invalid_signing_journal_domain).

-doc "Recover an existing journal without ledger-derived mutation.".
-spec recover(binary(), <<_:256>>, file:filename_all()) -> {ok, handle()}.
recover(Ns, Domain, DataDir)
  when is_binary(Ns), is_binary(Domain), byte_size(Domain) =:= 32 ->
    Dir = quod_ledger_store:ns_dir(DataDir, Ns),
    Path = journal_path(Dir),
    case file:open(Path, [read, write, raw, binary]) of
        {ok, Fd} ->
            try
                {Offset, Used, Rounds, Floors, PendingDtx,
                 Transactions, _Count} =
                    scan(Fd, Domain, recover),
                {ok, #journal{fd = Fd, path = Path, domain = Domain,
                              offset = Offset, ever_used = Used,
                              rounds = Rounds, dtx_floors = Floors,
                              pending_dtx = PendingDtx,
                              transactions = Transactions}}
            catch
                Class:Reason:Stack ->
                    _ = file:close(Fd),
                    erlang:raise(Class, Reason, Stack)
            end;
        {error, enoent} ->
            error({signing_journal_missing, Path});
        {error, Reason} ->
            error({signing_journal_io_error, 0, Reason})
    end;
recover(_, _, _) ->
    error(invalid_signing_journal_domain).

-doc "Close the journal file.".
-spec close(handle()) -> ok.
close(#journal{fd = Fd}) ->
    _ = file:close(Fd),
    ok.

-doc "Return the currently retained consensus vote latches.".
-spec rounds(handle()) -> rounds().
rounds(#journal{rounds = Rounds}) ->
    maps:map(
      fun(_Slot, #{support := Support, final := Final}) ->
              #{support => Support, final => Final}
      end, Rounds).

-doc "Return the exact body owned by one durable era/view support latch.".
-spec supported_block(handle(), position()) -> #block{} | none.
supported_block(#journal{rounds = Rounds}, Position) ->
    case maps:get(Position, Rounds, none) of
        #{block := #block{} = Block} -> Block;
        _ -> none
    end.

-ifdef(TEST).
-doc "Return exact blocks retained with this validator's live support latches.".
-spec supported_blocks(handle()) -> #{position() => #block{}}.
supported_blocks(#journal{rounds = Rounds}) ->
    maps:fold(
      fun(Slot, #{block := #block{} = Block}, Acc) ->
              Acc#{Slot => Block};
         (_Slot, _Round, Acc) ->
              Acc
      end, #{}, Rounds).
-endif.

-doc "Return the safe floor: max(local allocation, reconciled committed floor).".
-spec dtx_floor(handle(), lane()) -> non_neg_integer().
dtx_floor(#journal{dtx_floors = Floors}, Lane) ->
    maps:get(Lane, Floors, 0).

-doc "Return pending source responsibility or signed own votes, keyed by GroupId; zero sequence is unsigned.".
-spec pending_dtx(handle()) -> pending_dtx().
pending_dtx(#journal{pending_dtx = PendingDtx}) -> PendingDtx.

-doc "Return exact journaled content submissions still awaiting history.".
-spec pending_transactions(handle()) ->
          #{binary() =>
              #{admission := <<_:256>>, sequence := pos_integer(),
                state := dormant | bound | ready,
                body := binary(), envelope := binary()}}.
pending_transactions(#journal{transactions = Transactions}) -> Transactions.

-doc "Persist the exact block and its support latch atomically before signing.".
-spec record_support(handle(), #block{}) -> {ok, handle()}.
record_support(J = #journal{rounds = Rounds}, #block{} = Block) ->
    case supported_block(Block) of
        {ok, Slot, BH, Bytes} ->
            {Changed, Rounds1} = apply_support(Block, BH, Rounds),
            case Changed of
                false -> {ok, maybe_compact(J)};
                true ->
                    Term = {quod_signing_support, ?FORMAT_VERSION,
                            Slot, Bytes},
                    {ok, persist_mutation(
                           Term, J#journal{rounds = Rounds1,
                                          ever_used = true})}
            end;
        error ->
            error(invalid_supported_block)
    end;
record_support(_J, _Block) ->
    error(invalid_supported_block).

-doc "Persist one final-vote latch before its signature is exposed.".
-spec record_vote(handle(), commit | complaint, position(),
                  block_hash() | none) -> {ok, handle()}.
record_vote(J = #journal{rounds = Rounds}, Kind, Slot, BH) ->
    ok = valid_vote(Kind, Slot, BH),
    {Changed, Rounds1} = apply_vote(Kind, Slot, BH, Rounds),
    case Changed of
        false -> {ok, maybe_compact(J)};
        true ->
            Term = {quod_signing_final_vote,
                    ?FORMAT_VERSION, Kind, Slot, BH},
            {ok, persist_mutation(Term, J#journal{rounds = Rounds1,
                                                  ever_used = true})}
    end.

-doc """
Persist one signed DTX allocation before returning its exact exposable bytes.

All controls advance the admission-scoped local floor. Vote additionally
retains own material and the exact envelope in the same synced frame. Pending
intent (group, target and own bundle) cannot change. A pending choice may be
reclassified under the consensus admission rules, always at a higher sequence.
Only certified votes are immutable outcomes; this journal grants no outcome
authority and never resets the vote deadline or a currently admitted floor.
""".
-spec record_dtx(handle(), quod_atomic:control()) ->
          {ok, handle(), binary()}.
record_dtx(J, Control) ->
    case control_material(Control) of
        {ok, Kind, Lane, Sequence, Body, Envelope} ->
            Floor = dtx_floor(J, Lane),
            case Kind of
                vote ->
                    GroupId = quod_atomic:group_id(Control),
                    record_pending_dtx(
                      J, Floor, GroupId, pending_row(Lane, Sequence, Control, Body, Envelope));
                resolve ->
                    record_floor(J, Lane, Sequence, Floor, Envelope);
                complete ->
                    record_floor(J, Lane, Sequence, Floor, Envelope)
            end;
        {error, Reason} ->
            error({invalid_dtx_control, Reason})
    end.

-doc """
Persist source responsibility before any private effect binds, then its own
material only after binding completes. Both are unsigned states of the same
pending row: sequence zero allocates no signing floor and grants no vote.
Recovery of missing material can only select a deadline refusal. The existing
parent validator must select even a bound row before record_dtx signs it.
""".
-spec record_dtx_intent(handle(), quod_atomic:admission_material()) -> {ok, handle()}.
record_dtx_intent(J = #journal{pending_dtx = Rows}, Material) ->
    {ok, {group, _, _, Author, Admission, Id}} = quod_atomic:source_group_ref(Material),
    Pending = material_row({Admission, Author}, 0, Material, none),
    case maps:get(Id, Rows, undefined) of
        Pending -> {ok, J};
        Old ->
            case intent_successor(Old, Pending) of
                true -> {ok, persist_mutation(intent_term(Pending),
                              J#journal{pending_dtx = Rows#{Id => Pending}, ever_used = true})};
                false -> error({pending_dtx_intent_conflict, Id})
            end
    end.

intent_successor(undefined, #{material := {{quod_dtx_vote, _, _, _, none, _}, _, _}}) -> true;
intent_successor(#{sequence := 0, group_ref := Ref,
                   material := {{quod_dtx_vote, _, _, _, none, _}, _, _}},
                 #{sequence := 0, group_ref := Ref}) -> true;
intent_successor(_, _) -> false.

intent_term(#{body := Body}) -> {quod_signing_dtx_intent, ?FORMAT_VERSION, Body}.

-doc "Persist one exact signed content transaction before exposing its bytes.".
-spec record_transaction(handle(), #transaction{}, term(), dormant | ready) ->
          {ok, handle()}.
record_transaction(J = #journal{transactions = Transactions},
                   Transaction, Submission, InitialState)
  when InitialState =:= dormant; InitialState =:= ready ->
    case transaction_submission(Transaction, Submission) of
        {ok, TxId, Admission, Sequence, Body, Envelope} ->
            case maps:get(TxId, Transactions, undefined) of
                #{admission := Admission, sequence := Sequence,
                  state := ExistingState,
                  body := Body, envelope := Envelope} ->
                    case {ExistingState, InitialState} of
                        {dormant, ready} ->
                            %% A ready registration cannot stand in for the
                            %% durable target-prerequisite binding. Only the
                            %% explicit dormant -> bound -> ready transition
                            %% may activate this exact signed transaction.
                            error({transaction_signing_not_bound, TxId});
                        {bound, ready} ->
                            error({transaction_signing_not_bound, TxId});
                        _ ->
                            {ok, J}
                    end;
                undefined ->
                    Term = {quod_signing_transaction, ?FORMAT_VERSION,
                            TxId, Sequence, InitialState, Body, Envelope},
                    Transactions1 = Transactions#{TxId =>
                        #{admission => Admission,
                          sequence => Sequence, state => InitialState,
                          body => Body,
                          envelope => Envelope}},
                    {ok, persist_mutation(
                           Term, J#journal{transactions = Transactions1,
                                           ever_used = true})};
                _ ->
                    error({transaction_signing_conflict, TxId})
            end;
        error -> error(invalid_transaction_submission)
    end;
record_transaction(_J, _Transaction, _Submission, _InitialState) ->
    error(invalid_transaction_submission).

-doc "Record that every private prerequisite for one dormant transaction is durable.".
-spec bind_transaction(handle(), <<_:256>>) -> {ok, handle()}.
bind_transaction(J = #journal{transactions = Transactions},
                 <<_:256>> = TxId) ->
    case maps:get(TxId, Transactions, undefined) of
        #{state := bound} ->
            {ok, J};
        Row = #{state := dormant} ->
            Transactions1 = Transactions#{TxId => Row#{state := bound}},
            {ok, persist_mutation(
                   {quod_signing_transaction_bound, ?FORMAT_VERSION, TxId},
                   J#journal{transactions = Transactions1})};
        _ ->
            error({transaction_signing_not_dormant, TxId})
    end.

-doc "Activate one exact transaction after its private prerequisite was durably bound.".
-spec activate_transaction(handle(), <<_:256>>) -> {ok, handle()}.
activate_transaction(J = #journal{transactions = Transactions},
                     <<_:256>> = TxId) ->
    case maps:get(TxId, Transactions, undefined) of
        #{state := ready} ->
            {ok, J};
        Row = #{state := bound} ->
            Transactions1 = Transactions#{TxId => Row#{state := ready}},
            {ok, persist_mutation(
                   {quod_signing_transaction_activated,
                    ?FORMAT_VERSION, TxId},
                   J#journal{transactions = Transactions1})};
        #{state := dormant} ->
            error({transaction_signing_not_bound, TxId});
        undefined ->
            error({transaction_signing_not_found, TxId})
    end.

-doc "Retire one transaction row after committed history or correlated private cancellation.".
-spec retire_transaction(handle(), <<_:256>>) -> {ok, handle()}.
retire_transaction(J = #journal{transactions = Transactions},
                   <<_:256>> = TxId) ->
    case maps:is_key(TxId, Transactions) of
        false -> {ok, J};
        true ->
            Transactions1 = maps:remove(TxId, Transactions),
            Term = {quod_signing_transaction_retired,
                    ?FORMAT_VERSION, TxId},
            {ok, persist_mutation(
                   Term, J#journal{transactions = Transactions1})}
    end.

-doc "Raise live floors and prune retired state only from validated history.".
-spec reconcile(handle(),
                #{archived_protocol := #{<<_:256>> => non_neg_integer() | sealed},
                  live_dtx_lanes := #{lane() => non_neg_integer()},
                  current_admissions := #{<<_:256>> => <<_:256>>},
                  pending_dtx := #{<<_:256>> => lane()}}) -> {ok, handle()}.
reconcile(J = #journal{rounds = Rounds, dtx_floors = Floors,
                       pending_dtx = PendingDtx}, Validated) ->
    case valid_reconciliation(Validated, PendingDtx) of
        {ok, Archived, LiveLanes, Admissions, PendingDtx1} ->
            Rounds1 = maps:filter(
              fun({Era, View}, _) ->
                  case maps:get(Era, Archived, 0) of
                      sealed -> false;
                      Through -> View > Through
                  end
              end, Rounds),
            Floors1 = reconciled_floors(
                        Floors, LiveLanes, Admissions, PendingDtx1),
            J1 = J#journal{rounds = Rounds1, dtx_floors = Floors1,
                           pending_dtx = PendingDtx1},
            %% A removed pending vote has no append-only tombstone. Compact before
            %% returning so recovery cannot resurrect it.  Ordinary
            %% vote/floor pruning retains the cheap O(1) threshold check.
            case PendingDtx =/= PendingDtx1 of
                true -> {ok, compact(J1)};
                false -> {ok, maybe_compact(J1)}
            end;
        error ->
            error(invalid_signing_journal_reconciliation)
    end.

%%%===================================================================
%%% DTX mutation
%%%===================================================================

record_floor(J, Lane, Sequence, Floor, Envelope) when Sequence > Floor ->
    {Admission, Author} = Lane,
    Term = {quod_signing_dtx_floor, ?FORMAT_VERSION,
            Admission, Author, Sequence},
    Floors1 = (J#journal.dtx_floors)#{Lane => Sequence},
    J1 = persist_mutation(Term, J#journal{dtx_floors = Floors1,
                                          ever_used = true}),
    {ok, J1, Envelope};
record_floor(_J, Lane, Sequence, Floor, _Envelope) ->
    error({dtx_sequence_conflict, Lane, Floor, Sequence}).

record_pending_dtx(J = #journal{pending_dtx = PendingDtx},
                   Floor, GroupId,
                   #{lane := Lane, sequence := Sequence, intent := Intent,
                     body := Body, envelope := Envelope} = Pending) ->
    case maps:get(GroupId, PendingDtx, undefined) of
        #{lane := Lane, sequence := Sequence,
          body := Body, envelope := Envelope} ->
            %% Returning bytes already exposed by this journal is idempotent
            %% even when another group has since advanced the lane floor.
            {ok, J, Envelope};
        #{lane := Lane, sequence := OldSequence, intent := Intent}
          when Sequence > OldSequence, Sequence > Floor ->
            append_pending_dtx(J, GroupId, Pending);
        #{sequence := 0, intent := Intent} when Sequence > Floor ->
            append_pending_dtx(J, GroupId, Pending);
        #{lane := {OldAdmission, Author}, intent := Intent}
          when Lane =/= {OldAdmission, Author}, element(2, Lane) =:= Author, Sequence > Floor ->
            append_pending_dtx(J, GroupId, Pending);
        undefined when Sequence > Floor ->
            append_pending_dtx(J, GroupId, Pending);
        Existing ->
            error({pending_dtx_row_conflict,
                   #{pending => pending_identity(GroupId, Existing),
                     requested => {GroupId, Lane, Sequence}, floor => Floor}})
    end.

append_pending_dtx(J, GroupId, #{lane := Lane = {Admission, Author}, sequence := Sequence,
                                body := Body, envelope := Envelope} = Pending) ->
    Term = {quod_signing_pending_dtx, ?FORMAT_VERSION,
            Admission, Author, Sequence, GroupId, Body, Envelope},
    Floors1 = (J#journal.dtx_floors)#{Lane => Sequence},
    PendingDtx1 = (J#journal.pending_dtx)#{GroupId => Pending},
    J1 = persist_mutation(Term, J#journal{dtx_floors = Floors1,
                                          pending_dtx = PendingDtx1,
                                          ever_used = true}),
    {ok, J1, Envelope}.

%% Derived once from authenticated own material, not from the renewable
%% signing author. The stored wire frame still contains only the canonical
%% body/envelope; reopening derives exactly the same compact public reference.
pending_row(Lane, Sequence, Control, Body, Envelope) ->
    #{body := Body} = Row = material_row(Lane, Sequence,
                                         quod_atomic:control_material(Control), Envelope),
    Row.

material_row(Lane, Sequence,
             {Record, _, #{group := #{manifest := Manifest, group_id := Id}}} = Material, Envelope) ->
    {ok, GroupRef} = quod_dtx:manifest_group_ref(Manifest, Id),
    #{lane => Lane, sequence => Sequence, intent => quod_atomic:intent_id(Material),
      group_ref => GroupRef, body => encode(Record), material => Material, envelope => Envelope}.

pending_identity(_GroupId, undefined) -> none;
pending_identity(GroupId, #{lane := Lane, sequence := Sequence}) ->
    {GroupId, Lane, Sequence}.

control_material(Control) ->
    case quod_atomic:encode_control(Control) of
        {ok, Envelope} ->
            Meta = quod_atomic:control_metadata(Control),
            Target = maps:get(target, Meta),
            Kind = maps:get(kind, Meta),
            Body = term_to_binary(quod_atomic:control_body(Control), [deterministic]),
            Author = maps:get(author, Meta),
            Admission = maps:get(author_admission, Meta),
            Sequence = maps:get(sequence, Meta),
            case valid_control_kind(Kind) andalso
                 valid_lane({Admission, Author}) andalso
                 valid_sequence(Sequence) andalso
                 byte_size(Body) =< ?QUOD_MAX_DTX_BODY_BYTES andalso
                 byte_size(Envelope) =< ?QUOD_MAX_DTX_CONTROL_BYTES andalso
                 quod_atomic:verify_control(Target, Control) of
                true ->
                    {ok, Kind, {Admission, Author}, Sequence, Body, Envelope};
                false ->
                    {error, bad_control}
            end;
        {error, _} ->
            {error, bad_control}
    end.

valid_control_kind(vote) -> true;
valid_control_kind(resolve) -> true;
valid_control_kind(complete) -> true;
valid_control_kind(_) -> false.

transaction_submission(
  #transaction{tx_id = <<_:256>> = TxId, author_seq = Sequence,
               sig = Signature} = Transaction,
  {submit, Author, Signature, Body} = Submission)
  when is_integer(Sequence), Sequence >= 1,
       is_binary(Author), byte_size(Author) =:= 32,
       is_binary(Signature), byte_size(Signature) =:= 64,
       is_binary(Body), byte_size(Body) =< ?MAX_BLOCK_BYTES ->
    Envelope = term_to_binary(Submission, [deterministic]),
    case {quod_transaction:verify_submission(Submission),
          Transaction#transaction.author =:= Author,
          canonical_transaction_identity(Body, TxId, Sequence, Author)} of
        {true, true, {ok, Admission}} ->
            {ok, TxId, Admission, Sequence, Body, Envelope};
        _ -> error
    end;
transaction_submission(_Transaction, _Submission) -> error.

decoded_transaction(<<_:256>> = TxId, Sequence, State, Body, Envelope)
  when is_integer(Sequence), Sequence >= 1, Sequence =< ?MAX_SLOT,
       (State =:= dormant orelse State =:= bound orelse State =:= ready),
       is_binary(Body), byte_size(Body) =< ?MAX_BLOCK_BYTES,
       is_binary(Envelope), byte_size(Envelope) =< (?MAX_BLOCK_BYTES + 1024) ->
    try binary_to_term(Envelope, [safe]) of
        {submit, Author, Signature, Body} = Submission
          when is_binary(Author), byte_size(Author) =:= 32,
               is_binary(Signature), byte_size(Signature) =:= 64 ->
            case {quod_transaction:verify_submission(Submission),
                  canonical_transaction_identity(
                    Body, TxId, Sequence, Author)} of
                {true, {ok, Admission}} ->
                    {ok, #{admission => Admission,
                           sequence => Sequence, state => State,
                           body => Body,
                               envelope => Envelope}};
                _ -> error
            end;
        _ -> error
    catch _:_ -> error
    end;
decoded_transaction(_, _, _, _, _) -> error.

canonical_transaction_identity(Body, TxId, Sequence, Author) ->
    case quod_transaction:decode_submission_metadata(Body) of
        {ok, #{admission := Admission, tx_id := TxId,
               author := Author,
               sequence := Sequence}} ->
            {ok, Admission};
        _ -> error
    end.

%%%===================================================================
%%% vote state
%%%===================================================================

empty_round() -> #{support => none, final => none, block => none}.

supported_block(#block{era = <<_:256>> = Era, slot = Slot, block_bytes = Bytes} = Block)
  when is_integer(Slot), Slot >= 1, Slot =< ?MAX_SLOT,
       is_binary(Bytes),
       byte_size(Bytes) =< ?QUOD_MAX_CANONICAL_BLOCK_BYTES ->
    case quod_ledger:valid_block_view(Block) of
        true -> {ok, {Era, Slot}, crypto:hash(sha256, Bytes), Bytes};
        false -> error
    end;
supported_block(_) ->
    error.

apply_support(Block = #block{era = Era, slot = View}, BH, Rounds) ->
    Slot = {Era, View},
    Round = maps:get(Slot, Rounds, empty_round()),
    Round1 = apply_round_vote(support, Slot, BH, Round),
    Round2 =
        case maps:get(block, Round1, none) of
            none -> Round1#{block => Block};
            #block{block_bytes = Bytes} when Bytes =:= Block#block.block_bytes ->
                Round1;
            #block{} ->
                error({supported_block_conflict, Slot})
        end,
    {Round2 =/= Round, Rounds#{Slot => Round2}}.

apply_vote(Kind, Slot, BH, Rounds) ->
    Round = maps:get(Slot, Rounds, empty_round()),
    Round1 = apply_round_vote(Kind, Slot, BH, Round),
    {Round1 =/= Round, Rounds#{Slot => Round1}}.

apply_round_vote(support, Slot, BH, #{support := Support} = Round) ->
    case Support of
        BH -> Round;
        none -> Round#{support => BH};
        Other -> error({vote_conflict, Slot, {support, Other}, {support, BH}})
    end;
apply_round_vote(commit, Slot, BH, #{final := Final} = Round) ->
    case Final of
        {commit, BH} -> Round;
        none -> Round#{final => {commit, BH}};
        Other -> error({vote_conflict, Slot, Other, {commit, BH}})
    end;
apply_round_vote(complaint, _Slot, none, #{final := none} = Round) ->
    Round#{final => complaint};
apply_round_vote(complaint, _Slot, none, #{final := complaint} = Round) ->
    Round;
apply_round_vote(complaint, Slot, none, #{final := Other}) ->
    error({vote_conflict, Slot, Other, complaint}).

valid_vote(commit, {<<_:256>>, Slot}, BH) when is_integer(Slot), Slot >= 1,
                                  Slot =< ?MAX_SLOT, is_binary(BH),
                                  byte_size(BH) =:= 32 -> ok;
valid_vote(complaint, {<<_:256>>, Slot}, none) when is_integer(Slot), Slot >= 1,
                                       Slot =< ?MAX_SLOT -> ok;
valid_vote(Kind, Slot, BH) -> error({invalid_vote, Kind, Slot, BH}).

%%%===================================================================
%%% framed file
%%%===================================================================

require_replaceable(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {error, enoent} -> ok;
        {error, Reason} -> error({signing_journal_io_error, 0, Reason});
        {ok, Fd} ->
            try
                {_Offset, Used, _Rounds, _Floors, _PendingDtx,
                 _Transactions, Count} =
                    scan(Fd, any, strict),
                case not Used andalso Count =:= 0 of
                    true -> ok;
                    false -> error(signing_journal_not_empty)
                end
            after
                _ = file:close(Fd)
            end
    end.

scan(Fd, ExpectedDomain, Mode) ->
    case read_frame(Fd, 0, strict) of
        {ok, Payload, Offset} ->
            {Domain, HeaderUsed} = decode_header(Payload, 0),
            ok = expected_domain(ExpectedDomain, Domain),
            scan_records(Fd, Offset, Mode, HeaderUsed, #{}, #{}, #{},
                         #{}, 0);
        eof ->
            error({signing_journal_corruption, missing_header, 0})
    end.

scan_records(Fd, Offset, Mode, Used, Rounds, Floors, PendingDtx,
             Transactions,
             Count) ->
    case read_frame(Fd, Offset, Mode) of
        eof -> {Offset, Used, Rounds, Floors, PendingDtx,
                Transactions, Count};
        {ok, Payload, Next} ->
            Term = decode_canonical(Payload, Offset),
            {Rounds1, Floors1, PendingDtx1, Transactions1} =
                apply_record(Term, Rounds, Floors, PendingDtx,
                             Transactions, Offset),
            scan_records(Fd, Next, Mode, true, Rounds1, Floors1,
                         PendingDtx1, Transactions1, Count + 1)
    end.

read_frame(Fd, Offset, Mode) ->
    case file:pread(Fd, Offset, ?HDR_BYTES) of
        eof -> eof;
        {error, Reason} ->
            error({signing_journal_io_error, Offset, Reason});
        {ok, Header} ->
            case legacy_version(Header) of
                {vote, Version} ->
                    error({unsupported_vote_journal_format, Version, Offset});
                {signing, Version} ->
                    error({unsupported_signing_journal_format,
                           Version, Offset});
                none ->
                    read_current_frame(Fd, Offset, Mode, Header)
            end
    end.

read_current_frame(Fd, Offset, Mode, Header)
  when byte_size(Header) < ?HDR_BYTES ->
    torn_tail(Fd, Offset, Mode);
read_current_frame(Fd, Offset, Mode,
                   <<?MAGIC:32, Len:32, CRC:32>>)
  when Len =< ?MAX_FRAME_PAYLOAD_BYTES ->
    case file:pread(Fd, Offset + ?HDR_BYTES, Len) of
        {ok, Payload} when byte_size(Payload) =:= Len ->
            case erlang:crc32(Payload) of
                CRC -> {ok, Payload, Offset + ?HDR_BYTES + Len};
                _ -> error({signing_journal_corruption, bad_crc, Offset})
            end;
        eof -> torn_tail(Fd, Offset, Mode);
        {ok, _Short} -> torn_tail(Fd, Offset, Mode);
        {error, Reason} ->
            error({signing_journal_io_error, Offset, Reason})
    end;
read_current_frame(_Fd, Offset, _Mode,
                   <<?MAGIC:32, Len:32, _CRC:32>>) ->
    error({signing_journal_corruption, {frame_too_big, Len}, Offset});
read_current_frame(_Fd, Offset, _Mode, _Header) ->
    error({signing_journal_corruption, bad_magic, Offset}).

legacy_version(<<?QVJ1_MAGIC:32, _/binary>>) -> {vote, 1};
legacy_version(<<?QVJ2_MAGIC:32, _/binary>>) -> {vote, 2};
legacy_version(<<?QVJ3_MAGIC:32, _/binary>>) -> {vote, 3};
legacy_version(<<?QSJ1_MAGIC:32, _/binary>>) -> {signing, 1};
legacy_version(<<?QSJ2_MAGIC:32, _/binary>>) -> {signing, 2};
legacy_version(<<?QSJ3_MAGIC:32, _/binary>>) -> {signing, 3};
legacy_version(<<?QSJ4_MAGIC:32, _/binary>>) -> {signing, 4};
legacy_version(<<?QSJ5_MAGIC:32, _/binary>>) -> {signing, 5};
legacy_version(<<?QSJ6_MAGIC:32, _/binary>>) -> {signing, 6};
legacy_version(_) -> none.

torn_tail(_Fd, Offset, strict) ->
    error({signing_journal_corruption, torn_frame, Offset});
torn_tail(Fd, Offset, recover) ->
    trim(Fd, Offset),
    eof.

decode_header(Payload, Offset) ->
    case decode_canonical(Payload, Offset) of
        {quod_signing_header, ?FORMAT_VERSION, <<_:256>> = Domain, Used}
          when is_boolean(Used) -> {Domain, Used};
        Other -> error({signing_journal_bad_header, Other, Offset})
    end.

expected_domain(any, _Domain) -> ok;
expected_domain(Domain, Domain) -> ok;
expected_domain(Expected, Actual) ->
    error({signing_journal_domain_mismatch, Actual, Expected}).

decode_canonical(Payload, Offset) ->
    case quod_safe_term:decode(Payload, ?MAX_FRAME_PAYLOAD_BYTES) of
        {ok, Term} ->
            case encode(Term) =:= Payload of
                true -> Term;
                false -> error({signing_journal_bad_record,
                                noncanonical, Offset})
            end;
        {error, Reason} ->
            error({signing_journal_bad_record, Reason, Offset})
    end.

apply_record({quod_signing_support, ?FORMAT_VERSION, Slot, Bytes},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case decoded_supported_block(Slot, Bytes) of
        {ok, Block, BH} ->
            {_Changed, Rounds1} = apply_support(Block, BH, Rounds),
            {Rounds1, Floors, PendingDtx, Transactions};
        error ->
            error({signing_journal_bad_supported_block, Offset})
    end;
apply_record({quod_signing_final_vote, ?FORMAT_VERSION, Kind, Slot, BH},
             Rounds, Floors, PendingDtx, Transactions, _Offset) ->
    ok = valid_vote(Kind, Slot, BH),
    {_Changed, Rounds1} = apply_vote(Kind, Slot, BH, Rounds),
    {Rounds1, Floors, PendingDtx, Transactions};
apply_record({quod_signing_dtx_floor, ?FORMAT_VERSION,
              Admission, Author, Sequence},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    Lane = {Admission, Author},
    ok = valid_recorded_sequence(Lane, Sequence, Floors, Offset),
    {Rounds, Floors#{Lane => Sequence}, PendingDtx, Transactions};
apply_record({quod_signing_pending_dtx, ?FORMAT_VERSION,
              Admission, Author, Sequence, GroupId, Body, Envelope},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    Lane = {Admission, Author},
    ok = valid_recorded_sequence(Lane, Sequence, Floors, Offset),
    Pending = decoded_pending(
                Lane, Sequence, GroupId, Body, Envelope, Offset),
    ok = valid_pending_successor(
           maps:get(GroupId, PendingDtx, undefined), Pending, Offset),
    {Rounds, Floors#{Lane => Sequence},
     PendingDtx#{GroupId => Pending}, Transactions};
apply_record({quod_signing_dtx_intent, ?FORMAT_VERSION, Body},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case quod_atomic:decode_material(Body) of
        {ok, Material} ->
            case quod_atomic:source_group_ref(Material) of
                {ok, {group, _, _, Author, Admission, Id}} ->
                    Pending = material_row({Admission, Author}, 0, Material, none),
                    case maps:get(Id, PendingDtx, undefined) of
                        undefined -> {Rounds, Floors, PendingDtx#{Id => Pending}, Transactions};
                        Old ->
                            case intent_successor(Old, Pending) of
                                true -> {Rounds, Floors, PendingDtx#{Id => Pending}, Transactions};
                                false -> error({signing_journal_pending_conflict, Offset})
                            end
                    end;
                error -> error({signing_journal_bad_pending, Offset})
            end;
        error -> error({signing_journal_bad_pending, Offset})
    end;
apply_record({quod_signing_transaction, ?FORMAT_VERSION,
              TxId, Sequence, State, Body, Envelope},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case decoded_transaction(TxId, Sequence, State, Body, Envelope) of
        {ok, Row} ->
            case maps:get(TxId, Transactions, undefined) of
                undefined ->
                    {Rounds, Floors, PendingDtx,
                     Transactions#{TxId => Row}};
                _ -> error({signing_journal_bad_transaction, Offset})
            end;
        _ -> error({signing_journal_bad_transaction, Offset})
    end;
apply_record({quod_signing_transaction_activated, ?FORMAT_VERSION,
              <<_:256>> = TxId},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case maps:get(TxId, Transactions, undefined) of
        Row = #{state := bound} ->
            {Rounds, Floors, PendingDtx,
             Transactions#{TxId => Row#{state := ready}}};
        _ ->
            error({signing_journal_bad_transaction_activation, Offset})
    end;
apply_record({quod_signing_transaction_bound, ?FORMAT_VERSION,
              <<_:256>> = TxId},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case maps:get(TxId, Transactions, undefined) of
        Row = #{state := dormant} ->
            {Rounds, Floors, PendingDtx,
             Transactions#{TxId => Row#{state := bound}}};
        _ ->
            error({signing_journal_bad_transaction_binding, Offset})
    end;
apply_record({quod_signing_transaction_retired, ?FORMAT_VERSION,
              <<_:256>> = TxId},
             Rounds, Floors, PendingDtx, Transactions, Offset) ->
    case maps:is_key(TxId, Transactions) of
        true -> {Rounds, Floors, PendingDtx,
                 maps:remove(TxId, Transactions)};
        false -> error({signing_journal_bad_transaction_retirement, Offset})
    end;
apply_record(Other, _Rounds, _Floors, _Pending, _Effects, Offset) ->
    error({signing_journal_bad_record, Other, Offset}).

decoded_supported_block({<<_:256>> = Era, Slot} = Position, Bytes)
  when is_integer(Slot), Slot >= 1, Slot =< ?MAX_SLOT,
       is_binary(Bytes),
       byte_size(Bytes) =< ?QUOD_MAX_CANONICAL_BLOCK_BYTES ->
    case quod_ledger:decode_block(Bytes) of
        {ok, #block{era = Era, slot = Slot} = Block} ->
            case supported_block(Block) of
                {ok, Position, BH, Bytes} -> {ok, Block, BH};
                _ -> error
            end;
        _ ->
            error
    end;
decoded_supported_block(_Slot, _Bytes) ->
    error.

valid_recorded_sequence(Lane, Sequence, Floors, Offset) ->
    case valid_lane(Lane) andalso valid_sequence(Sequence) andalso
         Sequence > maps:get(Lane, Floors, 0) of
        true -> ok;
        false -> error({signing_journal_bad_sequence, Lane, Sequence, Offset})
    end.

valid_pending_successor(undefined, _Pending, _Offset) -> ok;
valid_pending_successor(#{sequence := 0, intent := Intent},
                        #{intent := Intent}, _Offset) -> ok;
valid_pending_successor(#{lane := {OldAdmission, Author}, intent := Intent},
                        #{lane := {NewAdmission, Author}, intent := Intent}, _Offset)
  when OldAdmission =/= NewAdmission -> ok;
valid_pending_successor(
  #{lane := Lane, sequence := OldSequence, intent := Intent},
  #{lane := Lane, sequence := Sequence, intent := Intent},
  _Offset) when Sequence > OldSequence -> ok;
valid_pending_successor(_Old, _New, Offset) ->
    error({signing_journal_pending_conflict, Offset}).

decoded_pending(Lane, Sequence, GroupId, Body, Envelope, Offset)
  when is_binary(GroupId), byte_size(GroupId) =:= 32,
       is_binary(Body), byte_size(Body) =< ?QUOD_MAX_DTX_BODY_BYTES,
       is_binary(Envelope), byte_size(Envelope) =< ?QUOD_MAX_DTX_CONTROL_BYTES ->
    case quod_atomic:decode_control(Envelope) of
        {ok, Control} ->
            case control_material(Control) of
                {ok, vote, Lane, Sequence, Body, Envelope} ->
                    case quod_atomic:group_id(Control) of
                        GroupId -> pending_row(Lane, Sequence, Control, Body, Envelope);
                        _ -> error({signing_journal_bad_pending, Offset})
                    end;
                _ -> error({signing_journal_bad_pending, Offset})
            end;
        _ -> error({signing_journal_bad_pending, Offset})
    end;
decoded_pending(_Lane, _Sequence, _GroupId, _Body, _Envelope, Offset) ->
    error({signing_journal_bad_pending, Offset}).

persist_mutation(Term, J = #journal{fd = Fd, offset = Offset}) ->
    Frame = frame(encode(Term)),
    case Offset + byte_size(Frame) >= ?COMPACT_BYTES of
        true ->
            %% The new state already contains Term.  Compacting it directly
            %% preserves this mutation with one data-file sync instead of
            %% syncing an append and immediately syncing a replacement.
            compact(J);
        false ->
            ok = file:pwrite(Fd, Offset, Frame),
            ok = file:datasync(Fd),
            J#journal{offset = Offset + byte_size(Frame)}
    end.

frame(Payload) when is_binary(Payload),
                    byte_size(Payload) =< ?MAX_FRAME_PAYLOAD_BYTES ->
    <<?MAGIC:32, (byte_size(Payload)):32,
      (erlang:crc32(Payload)):32, Payload/binary>>;
frame(Payload) when is_binary(Payload) ->
    error({signing_journal_frame_too_big, byte_size(Payload)}).

encode(Term) -> term_to_binary(Term, [deterministic]).

trim(Fd, Offset) ->
    {ok, _} = file:position(Fd, Offset),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd).

%%%===================================================================
%%% reconciliation and compaction
%%%===================================================================

valid_reconciliation(
  #{archived_protocol := Archived, live_dtx_lanes := Live,
    current_admissions := Admissions,
    pending_dtx := ValidatedPending} = Summary, PendingDtx)
  when map_size(Summary) =:= 4, is_map(Archived),
       is_map(Live), map_size(Live) =< ?MAX_VALIDATORS,
       is_map(Admissions), map_size(Admissions) =< ?MAX_VALIDATORS,
       is_map(ValidatedPending) ->
    case valid_archived_protocol(maps:to_list(Archived)) andalso
         valid_live_lanes(maps:to_list(Live)) andalso
         valid_admissions(maps:to_list(Admissions)) andalso
         valid_pending_refs(maps:to_list(ValidatedPending)) of
        true ->
            Kept = maps:filter(
                     fun(GroupId, #{lane := Lane}) ->
                             maps:get(GroupId, ValidatedPending, undefined)
                                 =:= Lane
                     end, PendingDtx),
            {ok, Archived, Live, Admissions, Kept};
        false -> error
    end;
valid_reconciliation(_, _) -> error.

%% The ledger owner supplies these floors only after syncing the selected
%% ancestry. Material height alone grants no release. `sealed` requires a
%% certified terminal membership block and durable old-era serving evidence;
%% an unknown era is retained, never inferred retired by binary ordering.
valid_archived_protocol([]) -> true;
valid_archived_protocol([{<<_:256>>, sealed} | Rest]) -> valid_archived_protocol(Rest);
valid_archived_protocol([{<<_:256>>, View} | Rest])
  when is_integer(View), View >= 0, View =< ?MAX_SLOT -> valid_archived_protocol(Rest);
valid_archived_protocol(_) -> false.

reconciled_floors(LocalFloors, CommittedFloors, Admissions, PendingDtx) ->
    %% An allocated sequence is anti-equivocation state even before its
    %% control commits.  Retain it for the exact currently admitted lane;
    %% validated membership retirement is the only authority that can prune
    %% it.  Otherwise a content commit between signing and DTX certification
    %% could make the live process allocate the same sequence twice while the
    %% first allocation remained durably present in this journal.
    Floors = maps:fold(
               fun(Lane, Local, Acc) ->
                       case lane_is_current(Lane, Admissions) of
                           true ->
                               Acc#{Lane => erlang:max(
                                              Local,
                                              maps:get(Lane, Acc, 0))};
                           false -> Acc
                       end
               end, CommittedFloors, LocalFloors),
    maps:fold(
      fun(_GroupId, #{sequence := 0}, Acc) -> Acc;
         (_GroupId, #{lane := Lane, sequence := Sequence}, Acc) ->
              Acc#{Lane => erlang:max(Sequence, maps:get(Lane, Acc, 0))}
      end, Floors, PendingDtx).

valid_live_lanes([]) -> true;
valid_live_lanes([{Lane, Floor} | Rest]) ->
    valid_lane(Lane) andalso is_integer(Floor) andalso Floor >= 0 andalso
        Floor =< ?MAX_SLOT andalso valid_live_lanes(Rest).

valid_admissions([]) -> true;
valid_admissions([{Author, Admission} | Rest]) ->
    is_binary(Author) andalso byte_size(Author) =:= 32 andalso
        is_binary(Admission) andalso byte_size(Admission) =:= 32 andalso
        valid_admissions(Rest).

valid_pending_refs([]) -> true;
valid_pending_refs([{GroupId, Lane} | Rest]) ->
    is_binary(GroupId) andalso byte_size(GroupId) =:= 32 andalso
        valid_lane(Lane) andalso valid_pending_refs(Rest).

lane_is_current({Admission, Author}, Admissions) ->
    maps:get(Author, Admissions, undefined) =:= Admission.

valid_lane({Admission, Author}) ->
    is_binary(Admission) andalso byte_size(Admission) =:= 32 andalso
        is_binary(Author) andalso byte_size(Author) =:= 32;
valid_lane(_) -> false.

valid_sequence(Sequence) ->
    is_integer(Sequence) andalso Sequence >= 1 andalso Sequence =< ?MAX_SLOT.

maybe_compact(J = #journal{offset = Offset}) ->
    case Offset >= ?COMPACT_BYTES of
        true -> compact(J);
        false -> J
    end.

compact(J = #journal{fd = OldFd, path = Path, domain = Domain,
                     ever_used = Used, rounds = Rounds,
                     dtx_floors = Floors, pending_dtx = PendingDtx,
                     transactions = Transactions}) ->
    Tmp = temporary_path(filename:dirname(Path)),
    _ = file:delete(Tmp),
    Terms = [{quod_signing_header, ?FORMAT_VERSION, Domain, Used}
             | snapshot_terms(Rounds, Floors, PendingDtx, Transactions)],
    Data = iolist_to_binary([frame(encode(Term)) || Term <- Terms]),
    {ok, TmpFd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(TmpFd, Data),
        ok = file:datasync(TmpFd)
    after
        _ = file:close(TmpFd)
    end,
    ok = file:rename(Tmp, Path),
    ok = quod_file:sync_dir(filename:dirname(Path)),
    _ = file:close(OldFd),
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    J#journal{fd = Fd, offset = byte_size(Data)}.

snapshot_terms(Rounds, Floors, PendingDtx, Transactions) ->
    round_terms(
      Rounds,
      pending_terms(
        PendingDtx,
        floor_terms(Floors, PendingDtx,
                    transaction_terms(Transactions)))).

transaction_terms(Transactions) ->
    [{quod_signing_transaction, ?FORMAT_VERSION,
      TxId, Sequence, State, Body, Envelope}
     || {TxId, #{sequence := Sequence, state := State, body := Body,
                 envelope := Envelope}} <-
             lists:sort(maps:to_list(Transactions))].

round_terms(Rounds, Tail) ->
    lists:foldr(
      fun({Slot, #{support := Support, final := Final,
                   block := Block}}, Acc) ->
              support_term(Slot, Support, Block,
                           final_vote_terms(Slot, Final, Acc))
      end, Tail, lists:sort(maps:to_list(Rounds))).

support_term(_Slot, none, none, Tail) -> Tail;
support_term(Slot, SupportBH,
             #block{block_bytes = Bytes} = Block, Tail)
  when is_binary(SupportBH), is_binary(Bytes) ->
    {ok, Slot, SupportBH, Bytes} = supported_block(Block),
    [{quod_signing_support, ?FORMAT_VERSION, Slot, Bytes} | Tail].

final_vote_terms(_Slot, none, Tail) -> Tail;
final_vote_terms(Slot, complaint, Tail) ->
    [{quod_signing_final_vote, ?FORMAT_VERSION,
      complaint, Slot, none} | Tail];
final_vote_terms(Slot, {commit, CommitBH}, Tail) ->
    [{quod_signing_final_vote, ?FORMAT_VERSION,
      commit, Slot, CommitBH} | Tail].

floor_terms(Floors, PendingDtx, Tail) ->
    PendingFloors = maps:fold(
                      fun(_GroupId,
                          #{lane := Lane, sequence := Sequence}, Acc) ->
                              Acc#{Lane => erlang:max(
                                             Sequence,
                                             maps:get(Lane, Acc, 0))}
                      end, #{}, PendingDtx),
    lists:foldr(
      fun({{Admission, Author}, Sequence}, Acc) ->
              Lane = {Admission, Author},
              case maps:get(Lane, PendingFloors, 0) of
                  Sequence ->
                      %% The last pending record for this lane already
                      %% carries this exact floor.
                      Acc;
                  _ ->
                      [{quod_signing_dtx_floor, ?FORMAT_VERSION,
                        Admission, Author, Sequence} | Acc]
              end
      end, Tail, lists:sort(maps:to_list(Floors))).

pending_terms(PendingDtx, Tail) ->
    Sorted = lists:sort(
               [{{Lane, Sequence, GroupId}, Pending}
                || {GroupId,
                    #{lane := Lane, sequence := Sequence} = Pending} <-
                       maps:to_list(PendingDtx)]),
    [pending_term(Key, Pending) || {Key, Pending} <- Sorted] ++ Tail.

pending_term(_, #{sequence := 0} = Pending) -> intent_term(Pending);
pending_term({{Admission, Author}, Sequence, GroupId}, #{body := Body, envelope := Envelope}) ->
    {quod_signing_pending_dtx, ?FORMAT_VERSION,
     Admission, Author, Sequence, GroupId, Body, Envelope}.

journal_path(Dir) -> filename:join(Dir, "signing.0001").
temporary_path(Dir) -> filename:join(Dir, "signing.0001.new").


-ifdef(TEST).
test_frame(Payload) -> frame(Payload).
test_max_frame_payload_bytes() -> ?MAX_FRAME_PAYLOAD_BYTES.
-endif.
