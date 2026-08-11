-module(quod_signing_journal).
-moduledoc """
Crash-durable signing state for one ontology on one validator.

The journal is the sole local anti-equivocation authority for consensus votes
and DTX sequence allocation.  It also retains the one locally-coordinated
Begin whose exact signed envelope may need redriving after a crash.  Every new
decision is persisted and datasync'd before its signature may be exposed.

Initialization and recovery are deliberately separate.  `initialize/3` is
the empty-ledger operation and may replace only a provably unused journal;
`recover/3` opens only an existing domain-bound journal and never uses a raw
ledger height to prune it.  `reconcile/2` is the sole pruning operation and
accepts only the compact result of an already-validated history fold.
""".

-include("quod_ingress_limits.hrl").
-include("quod_proof_limits.hrl").

-export([initialize/3, recover/3, reconcile/2, close/1,
         rounds/1, dtx_floor/2, pending_begin/1,
         record_vote/4, record_dtx/2]).
-export_type([handle/0, round/0, final_vote/0, lane/0, pending_begin/0]).

-ifdef(TEST).
-export([compact/1, test_frame/1, test_max_frame_payload_bytes/0]).
-endif.

%% New file and record domain.  Recognized vote-journal formats are rejected
%% explicitly at every frame boundary, including a four-byte short tail.
-define(V1_MAGIC, 16#51564A31). %% "QVJ1"
-define(V2_MAGIC, 16#51564A32). %% "QVJ2"
-define(V3_MAGIC, 16#51564A33). %% "QVJ3"
-define(MAGIC,    16#51534A31). %% "QSJ1"
-define(HDR_BYTES, 12).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).
-define(COMPACT_BYTES, (1024 * 1024)).

%% Exact deterministic-ETF overhead of
%% {quod_signing_pending_begin,1,Admission,Author,MaxU64,Group,Body,Envelope}
%% outside the two variable blobs.  The boundary therefore follows the shared
%% DTX limits automatically instead of duplicating their current values.
-define(PENDING_WRAPPER_BYTES, 165).
-define(MAX_FRAME_PAYLOAD_BYTES,
        (?QUOD_MAX_DTX_BODY_BYTES + ?QUOD_MAX_DTX_CONTROL_BYTES +
         ?PENDING_WRAPPER_BYTES)).

-type block_hash() :: <<_:256>>.
-type final_vote() :: none | {commit, block_hash()} | complaint.
-type round() :: #{support := none | block_hash(), final := final_vote()}.
-type rounds() :: #{non_neg_integer() => round()}.
-type lane() :: {<<_:256>>, <<_:256>>}. %% {AuthorAdmission, Author}
-type pending_begin() ::
        #{lane := lane(), sequence := pos_integer(), group_id := <<_:256>>,
          body := binary(), envelope := binary()}.

-record(journal, {
          fd :: file:io_device(),
          path :: file:filename_all(),
          domain :: <<_:256>>,
          offset = 0 :: non_neg_integer(),
          ever_used = false :: boolean(),
          rounds = #{} :: rounds(),
          dtx_floors = #{} :: #{lane() => non_neg_integer()},
          pending = none :: none | pending_begin()
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
    ok = filelib:ensure_dir(Path),
    ok = require_replaceable(Path),
    Tmp = temporary_path(Dir),
    _ = file:delete(Tmp),
    Header = frame(encode({quod_signing_header, 1, Domain, false})),
    {ok, TmpFd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(TmpFd, Header),
        ok = file:datasync(TmpFd)
    after
        _ = file:close(TmpFd)
    end,
    ok = file:rename(Tmp, Path),
    ok = sync_dir(Dir),
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
                {Offset, Used, Rounds, Floors, Pending, _Count} =
                    scan(Fd, Domain, recover),
                {ok, #journal{fd = Fd, path = Path, domain = Domain,
                              offset = Offset, ever_used = Used,
                              rounds = Rounds, dtx_floors = Floors,
                              pending = Pending}}
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
rounds(#journal{rounds = Rounds}) -> Rounds.

-doc "Return the safe floor: max(local allocation, reconciled committed floor).".
-spec dtx_floor(handle(), lane()) -> non_neg_integer().
dtx_floor(#journal{dtx_floors = Floors}, Lane) ->
    maps:get(Lane, Floors, 0).

-doc "Return the one exact locally pending Begin, if any.".
-spec pending_begin(handle()) -> none | pending_begin().
pending_begin(#journal{pending = Pending}) -> Pending.

-doc "Persist one consensus vote latch before its signature is exposed.".
-spec record_vote(handle(), support | commit | complaint, pos_integer(),
                  block_hash() | none) -> {ok, handle()}.
record_vote(J = #journal{rounds = Rounds}, Kind, Slot, BH) ->
    ok = valid_vote(Kind, Slot, BH),
    {Changed, Rounds1} = apply_vote(Kind, Slot, BH, Rounds),
    case Changed of
        false -> {ok, maybe_compact(J)};
        true ->
            Term = {quod_signing_vote, 1, Kind, Slot, BH},
            {ok, persist_mutation(Term, J#journal{rounds = Rounds1,
                                                  ever_used = true})}
    end.

-doc """
Persist one signed DTX allocation before returning its exact exposable bytes.

All controls advance the admission-scoped local floor.  Begin additionally
retains its semantic body and exact envelope in the same synced frame.  A
still-pending Begin may only be re-enveloped with the same lane, GroupId and
body at a higher sequence.
""".
-spec record_dtx(handle(), quod_dtx:control()) ->
          {ok, handle(), binary()}.
record_dtx(J, Control) ->
    case control_material(Control) of
        {ok, Kind, Lane, Sequence, Body, Envelope} ->
            Floor = dtx_floor(J, Lane),
            case Kind of
                'begin' ->
                    GroupId = quod_dtx:group_id(Control),
                    record_begin(
                      J, Lane, Sequence, Floor, GroupId, Body, Envelope);
                prepare ->
                    record_floor(J, Lane, Sequence, Floor, Envelope);
                decision ->
                    record_floor(J, Lane, Sequence, Floor, Envelope);
                finalize ->
                    record_floor(J, Lane, Sequence, Floor, Envelope);
                complete ->
                    record_floor(J, Lane, Sequence, Floor, Envelope)
            end;
        {error, Reason} ->
            error({invalid_dtx_control, Reason})
    end.

-doc "Raise live floors and prune retired state only from validated history.".
-spec reconcile(handle(),
                #{committed_slot := non_neg_integer(),
                  live_dtx_lanes := #{lane() => non_neg_integer()},
                  pending := none | {<<_:256>>, lane()}}) -> {ok, handle()}.
reconcile(J = #journal{rounds = Rounds, dtx_floors = Floors,
                       pending = Pending}, Validated) ->
    case valid_reconciliation(Validated, Pending) of
        {ok, Slot, LiveLanes, Pending1} ->
            Rounds1 = maps:filter(fun(S, _) -> S > Slot end, Rounds),
            Floors1 = reconciled_floors(Floors, LiveLanes, Pending1),
            J1 = J#journal{rounds = Rounds1, dtx_floors = Floors1,
                           pending = Pending1},
            %% Clearing a pending Begin must retire its old append record
            %% before another group can occupy the singleton.  This rare
            %% transition compacts immediately; ordinary vote/floor pruning
            %% retains the cheap O(1) threshold check.
            case Pending =/= none andalso Pending1 =:= none of
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
    Term = {quod_signing_dtx_floor, 1, Admission, Author, Sequence},
    Floors1 = (J#journal.dtx_floors)#{Lane => Sequence},
    J1 = persist_mutation(Term, J#journal{dtx_floors = Floors1,
                                          ever_used = true}),
    {ok, J1, Envelope};
record_floor(_J, Lane, Sequence, Floor, _Envelope) ->
    error({dtx_sequence_conflict, Lane, Floor, Sequence}).

record_begin(J = #journal{pending = none}, Lane, Sequence, Floor,
             GroupId, Body, Envelope) when Sequence > Floor ->
    append_begin(J, Lane, Sequence, GroupId, Body, Envelope);
record_begin(J = #journal{pending =
                            #{lane := Lane, sequence := Sequence,
                              group_id := GroupId, body := Body,
                              envelope := Envelope}},
             Lane, Sequence, Floor, GroupId, Body, Envelope)
  when Sequence =:= Floor ->
    {ok, J, Envelope};
record_begin(J = #journal{pending =
                            #{lane := Lane, sequence := OldSequence,
                              group_id := GroupId, body := Body}},
             Lane, Sequence, Floor, GroupId, Body, Envelope)
  when Sequence > OldSequence, Sequence > Floor ->
    append_begin(J, Lane, Sequence, GroupId, Body, Envelope);
record_begin(#journal{pending = Pending}, Lane, Sequence, Floor,
             GroupId, _Body, _Envelope) ->
    error({pending_begin_conflict,
           #{pending => pending_identity(Pending), requested =>
                 {GroupId, Lane, Sequence}, floor => Floor}}).

append_begin(J, Lane = {Admission, Author}, Sequence, GroupId, Body, Envelope) ->
    Pending = #{lane => Lane, sequence => Sequence, group_id => GroupId,
                body => Body, envelope => Envelope},
    Term = {quod_signing_pending_begin, 1, Admission, Author, Sequence,
            GroupId, Body, Envelope},
    Floors1 = (J#journal.dtx_floors)#{Lane => Sequence},
    J1 = persist_mutation(Term, J#journal{dtx_floors = Floors1,
                                          pending = Pending,
                                          ever_used = true}),
    {ok, J1, Envelope}.

pending_identity(none) -> none;
pending_identity(#{group_id := GroupId, lane := Lane, sequence := Sequence}) ->
    {GroupId, Lane, Sequence}.

control_material(Control) ->
    case quod_dtx:encode_control(Control) of
        {ok, Envelope} ->
            Meta = quod_dtx:control_metadata(Control),
            Target = maps:get(target, Meta),
            Kind = maps:get(kind, Meta),
            Body = maps:get(body_blob, Meta),
            Author = maps:get(author, Meta),
            Admission = maps:get(author_admission, Meta),
            Sequence = maps:get(sequence, Meta),
            case valid_control_kind(Kind) andalso
                 valid_lane({Admission, Author}) andalso
                 valid_sequence(Sequence) andalso
                 byte_size(Body) =< ?QUOD_MAX_DTX_BODY_BYTES andalso
                 byte_size(Envelope) =< ?QUOD_MAX_DTX_CONTROL_BYTES andalso
                 quod_dtx:verify_control(Target, Control) of
                true ->
                    {ok, Kind, {Admission, Author}, Sequence, Body, Envelope};
                false ->
                    {error, bad_control}
            end;
        {error, _} ->
            {error, bad_control}
    end.

valid_control_kind('begin') -> true;
valid_control_kind(prepare) -> true;
valid_control_kind(decision) -> true;
valid_control_kind(finalize) -> true;
valid_control_kind(complete) -> true;
valid_control_kind(_) -> false.

%%%===================================================================
%%% vote state
%%%===================================================================

empty_round() -> #{support => none, final => none}.

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

valid_vote(support, Slot, BH) when is_integer(Slot), Slot >= 1,
                                   Slot =< ?MAX_SLOT, is_binary(BH),
                                   byte_size(BH) =:= 32 -> ok;
valid_vote(commit, Slot, BH) when is_integer(Slot), Slot >= 1,
                                  Slot =< ?MAX_SLOT, is_binary(BH),
                                  byte_size(BH) =:= 32 -> ok;
valid_vote(complaint, Slot, none) when is_integer(Slot), Slot >= 1,
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
                {_Offset, Used, _Rounds, _Floors, _Pending, Count} =
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
            scan_records(Fd, Offset, Mode, HeaderUsed, #{}, #{}, none, 0);
        eof ->
            error({signing_journal_corruption, missing_header, 0})
    end.

scan_records(Fd, Offset, Mode, Used, Rounds, Floors, Pending, Count) ->
    case read_frame(Fd, Offset, Mode) of
        eof -> {Offset, Used, Rounds, Floors, Pending, Count};
        {ok, Payload, Next} ->
            Term = decode_canonical(Payload, Offset),
            {Rounds1, Floors1, Pending1} =
                apply_record(Term, Rounds, Floors, Pending, Offset),
            scan_records(Fd, Next, Mode, true, Rounds1, Floors1,
                         Pending1, Count + 1)
    end.

read_frame(Fd, Offset, Mode) ->
    case file:pread(Fd, Offset, ?HDR_BYTES) of
        eof -> eof;
        {error, Reason} ->
            error({signing_journal_io_error, Offset, Reason});
        {ok, Header} ->
            case legacy_version(Header) of
                {ok, Version} ->
                    error({unsupported_vote_journal_format, Version, Offset});
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

legacy_version(<<?V1_MAGIC:32, _/binary>>) -> {ok, 1};
legacy_version(<<?V2_MAGIC:32, _/binary>>) -> {ok, 2};
legacy_version(<<?V3_MAGIC:32, _/binary>>) -> {ok, 3};
legacy_version(_) -> none.

torn_tail(_Fd, Offset, strict) ->
    error({signing_journal_corruption, torn_frame, Offset});
torn_tail(Fd, Offset, recover) ->
    trim(Fd, Offset),
    eof.

decode_header(Payload, Offset) ->
    case decode_canonical(Payload, Offset) of
        {quod_signing_header, 1, <<_:256>> = Domain, Used}
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

apply_record({quod_signing_vote, 1, Kind, Slot, BH},
             Rounds, Floors, Pending, _Offset) ->
    ok = valid_vote(Kind, Slot, BH),
    {_Changed, Rounds1} = apply_vote(Kind, Slot, BH, Rounds),
    {Rounds1, Floors, Pending};
apply_record({quod_signing_dtx_floor, 1, Admission, Author, Sequence},
             Rounds, Floors, Pending, Offset) ->
    Lane = {Admission, Author},
    ok = valid_recorded_sequence(Lane, Sequence, Floors, Offset),
    {Rounds, Floors#{Lane => Sequence}, Pending};
apply_record({quod_signing_pending_begin, 1, Admission, Author, Sequence,
              GroupId, Body, Envelope},
             Rounds, Floors, OldPending, Offset) ->
    Lane = {Admission, Author},
    ok = valid_recorded_sequence(Lane, Sequence, Floors, Offset),
    Pending = decoded_pending(
                Lane, Sequence, GroupId, Body, Envelope, Offset),
    ok = valid_pending_successor(OldPending, Pending, Offset),
    {Rounds, Floors#{Lane => Sequence}, Pending};
apply_record(Other, _Rounds, _Floors, _Pending, Offset) ->
    error({signing_journal_bad_record, Other, Offset}).

valid_recorded_sequence(Lane, Sequence, Floors, Offset) ->
    case valid_lane(Lane) andalso valid_sequence(Sequence) andalso
         Sequence > maps:get(Lane, Floors, 0) of
        true -> ok;
        false -> error({signing_journal_bad_sequence, Lane, Sequence, Offset})
    end.

valid_pending_successor(none, _Pending, _Offset) -> ok;
valid_pending_successor(
  #{lane := Lane, sequence := OldSequence, group_id := GroupId, body := Body},
  #{lane := Lane, sequence := Sequence, group_id := GroupId, body := Body},
  _Offset) when Sequence > OldSequence -> ok;
valid_pending_successor(_Old, _New, Offset) ->
    error({signing_journal_pending_conflict, Offset}).

decoded_pending(Lane, Sequence, GroupId, Body, Envelope, Offset)
  when is_binary(GroupId), byte_size(GroupId) =:= 32,
       is_binary(Body), byte_size(Body) =< ?QUOD_MAX_DTX_BODY_BYTES,
       is_binary(Envelope), byte_size(Envelope) =< ?QUOD_MAX_DTX_CONTROL_BYTES ->
    case quod_dtx:decode_control(Envelope) of
        {ok, Control} ->
            case control_material(Control) of
                {ok, 'begin', Lane, Sequence, Body, Envelope} ->
                    case quod_dtx:group_id(Control) of
                        GroupId -> #{lane => Lane, sequence => Sequence,
                                     group_id => GroupId, body => Body,
                                     envelope => Envelope};
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
  #{committed_slot := Slot, live_dtx_lanes := Live,
    pending := PendingRef} = Summary, Pending)
  when map_size(Summary) =:= 3, is_integer(Slot), Slot >= 0,
       Slot =< ?MAX_SLOT,
       is_map(Live), map_size(Live) =< ?MAX_VALIDATORS ->
    case valid_live_lanes(maps:to_list(Live)) of
        true ->
            case {PendingRef, Pending} of
                {none, _} -> {ok, Slot, Live, none};
                {{GroupId, Lane},
                 #{group_id := GroupId, lane := Lane} = Kept}
                  when is_binary(GroupId), byte_size(GroupId) =:= 32 ->
                    {ok, Slot, Live, Kept};
                _ -> error
            end;
        false -> error
    end;
valid_reconciliation(_, _) -> error.

reconciled_floors(LocalFloors, CommittedFloors, Pending) ->
    Floors = maps:fold(
               fun(Lane, Committed, Acc) ->
                       Local = maps:get(Lane, LocalFloors, 0),
                       Acc#{Lane => erlang:max(Local, Committed)}
               end, #{}, CommittedFloors),
    case Pending of
        none -> Floors;
        #{lane := Lane, sequence := Sequence} ->
            Floors#{Lane => erlang:max(Sequence, maps:get(Lane, Floors, 0))}
    end.

valid_live_lanes([]) -> true;
valid_live_lanes([{Lane, Floor} | Rest]) ->
    valid_lane(Lane) andalso is_integer(Floor) andalso Floor >= 0 andalso
        Floor =< ?MAX_SLOT andalso valid_live_lanes(Rest).

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
                     dtx_floors = Floors, pending = Pending}) ->
    Tmp = temporary_path(filename:dirname(Path)),
    _ = file:delete(Tmp),
    Terms = [{quod_signing_header, 1, Domain, Used}
             | snapshot_terms(Rounds, Floors, Pending)],
    Data = iolist_to_binary([frame(encode(Term)) || Term <- Terms]),
    {ok, TmpFd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(TmpFd, Data),
        ok = file:datasync(TmpFd)
    after
        _ = file:close(TmpFd)
    end,
    ok = file:rename(Tmp, Path),
    ok = sync_dir(filename:dirname(Path)),
    _ = file:close(OldFd),
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    J#journal{fd = Fd, offset = byte_size(Data)}.

snapshot_terms(Rounds, Floors, Pending) ->
    round_terms(
      Rounds,
      pending_terms(Pending, floor_terms(Floors, Pending, []))).

round_terms(Rounds, Tail) ->
    lists:foldr(
      fun({Slot, #{support := Support, final := Final}}, Acc) ->
              case {Support, Final} of
                  {none, none} -> Acc;
                  {SupportBH, none} ->
                      [{quod_signing_vote, 1, support, Slot, SupportBH} | Acc];
                  {none, complaint} ->
                      [{quod_signing_vote, 1, complaint, Slot, none} | Acc];
                  {SupportBH, complaint} ->
                      [{quod_signing_vote, 1, support, Slot, SupportBH},
                       {quod_signing_vote, 1, complaint, Slot, none} | Acc];
                  {none, {commit, CommitBH}} ->
                      [{quod_signing_vote, 1, commit, Slot, CommitBH} | Acc];
                  {SupportBH, {commit, CommitBH}} ->
                      [{quod_signing_vote, 1, support, Slot, SupportBH},
                       {quod_signing_vote, 1, commit, Slot, CommitBH} | Acc]
              end
      end, Tail, lists:sort(maps:to_list(Rounds))).

floor_terms(Floors, Pending, Tail) ->
    lists:foldr(
      fun({{Admission, Author}, Sequence}, Acc) ->
              case Pending of
                  #{lane := {Admission, Author}, sequence := Sequence} ->
                      %% The pending record already carries this exact floor.
                      Acc;
                  _ ->
                      [{quod_signing_dtx_floor, 1, Admission, Author,
                        Sequence} | Acc]
              end
      end, Tail, lists:sort(maps:to_list(Floors))).

pending_terms(none, Tail) -> Tail;
pending_terms(#{lane := {Admission, Author}, sequence := Sequence,
                group_id := GroupId, body := Body, envelope := Envelope}, Tail) ->
    [{quod_signing_pending_begin, 1, Admission, Author, Sequence,
      GroupId, Body, Envelope} | Tail].

journal_path(Dir) -> filename:join(Dir, "signing.0001").
temporary_path(Dir) -> filename:join(Dir, "signing.0001.new").

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, DirFd} ->
            Result = file:datasync(DirFd),
            _ = file:close(DirFd),
            case Result of
                ok -> ok;
                {error, eisdir} -> ok;
                Error -> Error
            end;
        {error, eisdir} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-ifdef(TEST).
test_frame(Payload) -> frame(Payload).
test_max_frame_payload_bytes() -> ?MAX_FRAME_PAYLOAD_BYTES.
-endif.
