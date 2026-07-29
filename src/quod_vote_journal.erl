-module(quod_vote_journal).
-moduledoc """
Durable, bounded consensus vote latches for one namespace.

The committed ledger proves what the network finalized; this journal records what
this validator itself has already signed in the still-live consensus window. A
validator must durably record a support, commit, or complaint decision before its
signature is allowed onto the network. Reloading these records after a crash keeps
the independent one-support and commit-versus-complaint safety rules intact.

The journal stores no knowledge-base or proposal payload data. Every record is
bound to the same namespace/genesis consensus domain as the signature it guards.
Records are small CRC-framed terms in `votes.0001` under the namespace data directory. Appending a
new decision performs one `datasync`. Finalized slots are removed from the
in-memory view immediately; once the file reaches a bounded size, the remaining
live decisions are rewritten to a temporary file and atomically renamed. A crash
during compaction therefore leaves either the old complete history or the new
complete live snapshot. An incomplete final frame is trimmed on recovery; a
complete frame with an invalid checksum fail-stops instead of discarding a vote.
""".

-export([open/4, close/1, record/4, prune/2, rounds/1]).
-export_type([handle/0, round/0, final_vote/0]).

-ifdef(TEST).
-export([compact/1]).
-endif.

-define(OLD_MAGIC, 16#51564A31). %% "QVJ1" — rejected explicitly; no mixed signature formats
-define(MAGIC,     16#51564A32). %% "QVJ2"
-define(HDR_BYTES, 12).
-define(MAX_FRAME_BYTES, 1024).
-define(COMPACT_BYTES, (1024 * 1024)).
-define(MAX_SLOT, 16#FFFFFFFFFFFFFFFF).

-type block_hash() :: <<_:256>>.
-type final_vote() :: none | {commit, block_hash()} | complaint.
-type round() :: #{support := none | block_hash(), final := final_vote()}.
-type rounds() :: #{non_neg_integer() => round()}.

-record(journal, {fd :: file:io_device(),
                  path :: file:filename_all(),
                  domain :: <<_:256>>,
                  offset = 0 :: non_neg_integer(),
                  rounds = #{} :: rounds()}).
-opaque handle() :: #journal{}.

-doc "Open and recover one namespace journal, discarding decisions at or below `Committed`.".
-spec open(binary(), <<_:256>>, file:filename_all(), non_neg_integer()) -> {ok, handle()}.
open(Ns, Domain, DataDir, Committed)
  when is_binary(Ns), is_binary(Domain), byte_size(Domain) =:= 32,
       is_integer(Committed), Committed >= 0 ->
    Dir = quod_ledger_store:ns_dir(DataDir, Ns),
    ok = filelib:ensure_path(Dir),
    Path = filename:join(Dir, "votes.0001"),
    New = not filelib:is_file(Path),
    _ = file:delete(Path ++ ".new"),
    {ok, Fd} = file:open(Path, [read, write, raw, binary]),
    case New of
        true ->
            ok = file:datasync(Fd),
            ok = sync_dir(Dir);
        false ->
            ok
    end,
    {Offset, AllRounds} = scan(Fd, Domain),
    Live = maps:filter(fun(Slot, _Round) -> Slot > Committed end, AllRounds),
    J0 = #journal{fd = Fd, path = Path, domain = Domain,
                  offset = Offset, rounds = Live},
    case Offset >= ?COMPACT_BYTES of
        true  -> {ok, compact(J0)};
        false -> {ok, J0}
    end.

-doc "Close the journal file.".
-spec close(handle()) -> ok.
close(#journal{fd = Fd}) ->
    _ = file:close(Fd),
    ok.

-doc "Return the currently live, durably recorded vote decisions.".
-spec rounds(handle()) -> rounds().
rounds(#journal{rounds = Rounds}) -> Rounds.

-doc """
Durably record one new vote before it is signed or broadcast. Repeating the same
decision is idempotent. A conflicting support hash or final vote fail-stops the
caller instead of permitting equivocation.
""".
-spec record(handle(), support | commit | complaint, pos_integer(), block_hash() | none) ->
        {ok, handle()}.
record(J = #journal{domain = Domain, rounds = Rounds}, Kind, Slot, BlockHash) ->
    ok = valid_vote(Kind, Slot, BlockHash),
    {Changed, Rounds1} = apply_vote(Kind, Slot, BlockHash, Rounds),
    case Changed of
        false ->
            {ok, J};
        true ->
            Term = {quod_vote, 2, Domain, Kind, Slot, BlockHash},
            Frame = frame(term_to_binary(Term, [deterministic])),
            #journal{fd = Fd, offset = Offset} = J,
            ok = file:pwrite(Fd, Offset, Frame),
            ok = file:datasync(Fd),
            {ok, J#journal{offset = Offset + byte_size(Frame), rounds = Rounds1}}
    end.

-doc "Forget finalized decisions in memory and compact the append log when it reaches its size bound.".
-spec prune(handle(), non_neg_integer()) -> {ok, handle()}.
prune(J = #journal{rounds = Rounds, offset = Offset}, Committed)
  when is_integer(Committed), Committed >= 0 ->
    Live = maps:filter(fun(Slot, _Round) -> Slot > Committed end, Rounds),
    J1 = J#journal{rounds = Live},
    case Offset >= ?COMPACT_BYTES of
        true  -> {ok, compact(J1)};
        false -> {ok, J1}
    end.

%%%===================================================================
%%% vote state
%%%===================================================================

empty_round() -> #{support => none, final => none}.

apply_vote(Kind, Slot, BlockHash, Rounds) ->
    Round = maps:get(Slot, Rounds, empty_round()),
    Round1 = apply_round_vote(Kind, Slot, BlockHash, Round),
    {Round1 =/= Round, Rounds#{Slot => Round1}}.

apply_round_vote(support, Slot, BH, #{support := Support} = Round) ->
    case Support of
        BH ->
            Round;
        none ->
            Round#{support => BH};
        OtherBH ->
            error({vote_conflict, Slot, {support, OtherBH}, {support, BH}})
    end;
apply_round_vote(commit, Slot, BH, #{final := Final} = Round) ->
    case Final of
        {commit, BH} ->
            Round;
        none ->
            Round#{final => {commit, BH}};
        OtherFinal ->
            error({vote_conflict, Slot, OtherFinal, {commit, BH}})
    end;
apply_round_vote(complaint, _Slot, none, #{final := none} = Round) ->
    Round#{final => complaint};
apply_round_vote(complaint, _Slot, none, #{final := complaint} = Round) ->
    Round;
apply_round_vote(complaint, Slot, none, #{final := Other}) ->
    error({vote_conflict, Slot, Other, complaint}).

valid_vote(support, Slot, BH) when is_integer(Slot), Slot >= 1, Slot =< ?MAX_SLOT,
                                   is_binary(BH), byte_size(BH) =:= 32 -> ok;
valid_vote(commit, Slot, BH) when is_integer(Slot), Slot >= 1, Slot =< ?MAX_SLOT,
                                  is_binary(BH), byte_size(BH) =:= 32 -> ok;
valid_vote(complaint, Slot, none) when is_integer(Slot), Slot >= 1, Slot =< ?MAX_SLOT -> ok;
valid_vote(Kind, Slot, BH) -> error({invalid_vote, Kind, Slot, BH}).

%%%===================================================================
%%% framed append log
%%%===================================================================

frame(Payload) when byte_size(Payload) =< ?MAX_FRAME_BYTES ->
    <<?MAGIC:32, (byte_size(Payload)):32, (erlang:crc32(Payload)):32, Payload/binary>>.

scan(Fd, Domain) -> scan(Fd, Domain, 0, #{}).

scan(Fd, Domain, Offset, Rounds) ->
    case file:pread(Fd, Offset, ?HDR_BYTES) of
        eof ->
            {Offset, Rounds};
        %% The four-byte magic alone identifies the incompatible journal.
        %% Reject it before the generic torn-header repair so recovery never
        %% truncates recognizable V1 bytes.
        {ok, <<?OLD_MAGIC:32, _/binary>>} ->
            error({unsupported_vote_journal_format, 1});
        {ok, Header} when byte_size(Header) < ?HDR_BYTES ->
            trim(Fd, Offset),
            {Offset, Rounds};
        {ok, <<?MAGIC:32, Len:32, CRC:32>>} when Len =< ?MAX_FRAME_BYTES ->
            case file:pread(Fd, Offset + ?HDR_BYTES, Len) of
                {ok, Payload} when byte_size(Payload) =:= Len ->
                    case erlang:crc32(Payload) of
                        CRC ->
                            Rounds1 = decode_record(Payload, Domain, Rounds),
                            scan(Fd, Domain, Offset + ?HDR_BYTES + Len, Rounds1);
                        _ ->
                            error({vote_journal_corruption, bad_crc, Offset})
                    end;
                eof ->
                    trim(Fd, Offset),
                    {Offset, Rounds};
                {ok, _Short} ->
                    trim(Fd, Offset),
                    {Offset, Rounds};
                {error, Reason} ->
                    error({vote_journal_io_error, Offset, Reason})
            end;
        {ok, <<?MAGIC:32, Len:32, _CRC:32>>} ->
            error({vote_journal_corruption, {frame_too_big, Len}, Offset});
        {ok, _BadHeader} ->
            error({vote_journal_corruption, bad_magic, Offset});
        {error, Reason} ->
            error({vote_journal_io_error, Offset, Reason})
    end.

decode_record(Payload, Domain, Rounds) ->
    try binary_to_term(Payload, [safe]) of
        {quod_vote, 2, Domain, Kind, Slot, BH} ->
            ok = valid_vote(Kind, Slot, BH),
            {_Changed, Rounds1} = apply_vote(Kind, Slot, BH, Rounds),
            Rounds1;
        {quod_vote, 2, OtherDomain, _Kind, _Slot, _BH}
          when is_binary(OtherDomain), byte_size(OtherDomain) =:= 32 ->
            error({vote_journal_domain_mismatch, OtherDomain, Domain});
        Other ->
            error({vote_journal_bad_record, Other})
    catch
        error:{vote_conflict, _, _, _} = Conflict -> error(Conflict);
        error:{vote_journal_domain_mismatch, _, _} = Mismatch -> error(Mismatch);
        error:Reason -> error({vote_journal_bad_record, Reason})
    end.

trim(Fd, Offset) ->
    {ok, _} = file:position(Fd, Offset),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd).

%%%===================================================================
%%% bounded compaction
%%%===================================================================

compact(J = #journal{fd = OldFd, path = Path, domain = Domain,
                     rounds = Rounds}) ->
    Tmp = Path ++ ".new",
    _ = file:delete(Tmp),
    {ok, TmpFd} = file:open(Tmp, [write, raw, binary, exclusive]),
    Data = iolist_to_binary([frame(term_to_binary(Term, [deterministic]))
                             || Term <- round_terms(Domain, Rounds)]),
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

round_terms(Domain, Rounds) ->
    lists:flatmap(
      fun({Slot, #{support := Support, final := Final}}) ->
              case {Support, Final} of
                  {none, none} ->
                      [];
                  {SupportBH, none} ->
                      [{quod_vote, 2, Domain, support, Slot, SupportBH}];
                  {none, complaint} ->
                      [{quod_vote, 2, Domain, complaint, Slot, none}];
                  {SupportBH, complaint} ->
                      [{quod_vote, 2, Domain, support, Slot, SupportBH},
                       {quod_vote, 2, Domain, complaint, Slot, none}];
                  {none, {commit, CommitBH}} ->
                      [{quod_vote, 2, Domain, commit, Slot, CommitBH}];
                  {SupportBH, {commit, CommitBH}} ->
                      [{quod_vote, 2, Domain, support, Slot, SupportBH},
                       {quod_vote, 2, Domain, commit, Slot, CommitBH}]
              end
      end, lists:sort(maps:to_list(Rounds))).

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, DirFd} ->
            Result = file:datasync(DirFd),
            _ = file:close(DirFd),
            case Result of
                ok -> ok;
                %% Some OTP/file-driver combinations reject directory fsync
                %% even when the underlying filesystem makes rename atomic.
                {error, eisdir} -> ok;
                Error -> Error
            end;
        {error, eisdir} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.
