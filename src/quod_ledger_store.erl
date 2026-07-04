-module(quod_ledger_store).
-moduledoc """
Durable on-disk store for one namespace's Raft log — the **block list**.

This is the only quod code that touches disk. It is a plain library (no process,
no registration): every function is synchronous and completes its required `fsync`
before returning, and the handle is threaded by the caller (`quod_ledger`). See
`doc/ordering-layer-spec.md` §3.

Layout, under `DataDir/<base64url(Ns)>/`:

| file        | holds                                                          |
| ----------- | -------------------------------------------------------------- |
| `meta.term` | one frame of `#{cur_term, voted_for}` (atomic tmp+rename)      |
| `log.0001`  | append-only CRC-framed `#entry{}` records — the block list     |

Each frame is `<<Magic:32, Len:32, CRC:32, Payload:Len/binary>>` with
`Payload = term_to_binary(Term, [deterministic])` and `CRC = erlang:crc32(Payload)`.
The in-memory index (`#store.idx`) is rebuilt by scanning `log.0001` at `open/2`;
a truncated final frame (a crash mid-append that never `fsync`'d) is detected by
the length/CRC check and trimmed, which is safe because such an entry was never
acknowledged.

Snapshots/compaction are deferred to milestone M3; the snapshot API is present but
`read_snapshot/1` returns `none` until then.
""".
-include("quod_ledger.hrl").

-export([open/2, open_ro/2, close/1, load/1,
         read_meta/1, write_meta/3,
         append/2, truncate_from/2,
         read_at/2, read_range/3, last/1, term_at/2,
         read_snapshot/1, write_snapshot/5, install_snapshot/5]).

-export_type([handle/0]).

-define(MAGIC, 16#915106AA).
-define(HDR_BYTES, 12).   %% Magic:32 ++ Len:32 ++ CRC:32

-record(store, {dir         :: file:filename_all(),
                ns          :: binary(),
                log_fd      :: file:io_device(),
                idx = #{}   :: #{log_index() => {Offset :: non_neg_integer(),
                                                 PayloadLen :: non_neg_integer(),
                                                 term_no()}},
                last_index  = 0 :: log_index(),
                last_term   = 0 :: term_no(),
                base_offset = 0 :: non_neg_integer(),   %% next append offset (== log file size)
                snap_index  = 0 :: log_index(),
                snap_term   = 0 :: term_no()}).
-opaque handle() :: #store{}.

%%%===================================================================
%%% open / close / load
%%%===================================================================

-doc "Open (creating if needed) the on-disk store for `Ns` under `DataDir`.".
-spec open(binary(), file:filename_all()) -> {ok, handle()}.
open(Ns, DataDir) ->
    Dir = ns_dir(DataDir, Ns),
    ok = filelib:ensure_path(Dir),
    LogPath = filename:join(Dir, "log.0001"),
    {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
    {Idx, LastI, LastT, BaseOff} = scan_log(Fd),
    {SnapI, SnapT} = peek_snapshot(Dir),
    {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, idx = Idx,
                last_index = LastI, last_term = LastT, base_offset = BaseOff,
                snap_index = SnapI, snap_term = SnapT}}.

-doc """
Open a READ-ONLY handle for a concurrent reader (the catch-up server) alongside the live writer. NEVER
truncates: a torn / short / discontinuous tail — a frame the writer is mid-appending — simply bounds the
readable index, so the reader sees up to the last complete, CRC-valid, contiguous entry. `read_at`,
`read_range`, `last` work on it unchanged; do NOT `append`/`truncate_from`/`write_meta` through it. Errors
if the log does not exist yet.
""".
-spec open_ro(binary(), file:filename_all()) -> {ok, handle()} | {error, no_log}.
open_ro(Ns, DataDir) ->
    Dir = ns_dir(DataDir, Ns),
    case file:open(filename:join(Dir, "log.0001"), [read, raw, binary]) of
        {ok, Fd} ->
            try
                {Idx, LastI, LastT, BaseOff} = scan_ro(Fd, 0, #{}, 0, 0),
                {SnapI, SnapT} = peek_snapshot(Dir),
                {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, idx = Idx,
                            last_index = LastI, last_term = LastT, base_offset = BaseOff,
                            snap_index = SnapI, snap_term = SnapT}}
            catch C:R ->
                _ = file:close(Fd),   %% never leak the fd if the scan throws (e.g. a garbage term)
                {error, {scan_failed, C, R}}
            end;
        {error, enoent}  -> {error, no_log};
        {error, Reason}  -> {error, Reason}   %% emfile/eacces/… ⇒ degrade cleanly (never case_clause)
    end.

-doc "Close the store's file handle.".
-spec close(handle()) -> ok.
close(#store{log_fd = Fd}) -> _ = file:close(Fd), ok.

-doc """
Reload everything needed to reconstruct `quod_ledger`'s durable state: the persisted
term/vote, the full log (from `snap_index+1` up), and the snapshot metadata.
""".
-spec load(handle()) -> #{cur_term  := term_no(),
                          voted_for := node_id() | none,
                          log       := [#entry{}],
                          snap_idx  := log_index(),
                          snap_term := term_no(),
                          snap_cfg  := [node_id()],
                          snap_data := term() | none}.
load(S = #store{snap_index = SnapI, last_index = LastI}) ->
    {Term, VotedFor} = read_meta(S),
    {ok, Log} = read_range(S, SnapI + 1, LastI),
    {SnapData, SnapCfg} = read_snapshot_payload(S),
    #{cur_term => Term, voted_for => VotedFor, log => Log,
      snap_idx => SnapI, snap_term => S#store.snap_term,
      snap_cfg => SnapCfg, snap_data => SnapData}.

%%%===================================================================
%%% term/vote metadata — atomic (durable before a vote is granted)
%%%===================================================================

-doc "The persisted `{cur_term, voted_for}`; `{0, none}` for a fresh namespace.".
-spec read_meta(handle()) -> {term_no(), node_id() | none}.
read_meta(#store{dir = Dir}) ->
    case file:read_file(filename:join(Dir, "meta.term")) of
        {ok, Bin} ->
            case unframe(Bin) of
                {ok, Payload, _Rest} ->
                    #{cur_term := T, voted_for := V} = binary_to_term(Payload),
                    {T, V};
                _ -> {0, none}   %% torn/garbage meta: treat as fresh (next vote rewrites it)
            end;
        {error, enoent} -> {0, none}
    end.

-doc """
Persist `{Term, VotedFor}` atomically (tmp + datasync + rename). MUST complete
before `quod_ledger` grants a vote or replies at a bumped term.
""".
-spec write_meta(handle(), term_no(), node_id() | none) -> ok.
write_meta(#store{dir = Dir}, Term, VotedFor) ->
    Path = filename:join(Dir, "meta.term"),
    Tmp  = Path ++ ".tmp",
    Frame = frame(term_to_binary(#{cur_term => Term, voted_for => VotedFor}, [deterministic])),
    {ok, Fd} = file:open(Tmp, [write, raw, binary]),
    ok = file:write(Fd, Frame),
    ok = file:datasync(Fd),
    ok = file:close(Fd),
    ok = file:rename(Tmp, Path),
    %% M2: fsync the CONTAINING DIRECTORY after the rename. On POSIX the rename is
    %% atomic but the directory entry pointing at the new inode is durable only after
    %% the dir is fsync'd — without this a power-cut can lose a just-granted vote and
    %% let a restarted member double-vote in one term (review #9). 1-voter never has a
    %% contested vote, but real elections (M2) do.
    ok = sync_dir(Dir),
    ok.

%%%===================================================================
%%% append / truncate
%%%===================================================================

-doc """
Append contiguous entries (indices `last_index+1 ..`). One `datasync` for the
batch; returns only after it completes (the entries are durable before
`quod_ledger` counts them toward commit).
""".
-spec append(handle(), [#entry{}]) -> {ok, handle()}.
append(S, []) -> {ok, S};
append(S = #store{log_fd = Fd, base_offset = Off0, idx = Idx0,
                  last_index = LI0, last_term = LT0}, Entries) ->
    ok = assert_contiguous(LI0, Entries),
    {Off1, Idx1, LI1, LT1} =
        lists:foldl(
          fun(E = #entry{index = I, term = T}, {Off, Idx, _LI, _LT}) ->
                  Payload = term_to_binary(E, [deterministic]),
                  Frame   = frame(Payload),
                  ok = file:pwrite(Fd, Off, Frame),
                  {Off + byte_size(Frame),
                   Idx#{I => {Off, byte_size(Payload), T}}, I, T}
          end, {Off0, Idx0, LI0, LT0}, Entries),
    ok = file:datasync(Fd),
    {ok, S#store{base_offset = Off1, idx = Idx1, last_index = LI1, last_term = LT1}}.

-doc """
Delete entry `Index` and everything after it (follower conflict resolution).
Refuses to truncate into a snapshot. `datasync`'d before returning.
""".
-spec truncate_from(handle(), pos_integer()) -> {ok, handle()}.
truncate_from(#store{snap_index = SnapI}, Index) when Index =< SnapI ->
    error({truncate_below_snapshot, Index, SnapI});
truncate_from(S = #store{log_fd = Fd, idx = Idx}, Index) ->
    case maps:get(Index, Idx, undefined) of
        undefined ->
            {ok, S};   %% nothing at/after Index
        {Off, _Len, _T} ->
            {ok, _} = file:position(Fd, Off),
            ok = file:truncate(Fd),
            ok = file:datasync(Fd),
            Idx1 = maps:filter(fun(I, _) -> I < Index end, Idx),
            {LI, LT} = recompute_last(Idx1, S#store.snap_index, S#store.snap_term),
            {ok, S#store{idx = Idx1, base_offset = Off, last_index = LI, last_term = LT}}
    end.

%%%===================================================================
%%% reads
%%%===================================================================

-doc "Read the entry at `Index`, verifying its CRC.".
-spec read_at(handle(), pos_integer()) -> {ok, #entry{}} | not_found.
read_at(#store{log_fd = Fd, idx = Idx}, Index) ->
    case maps:get(Index, Idx, undefined) of
        undefined -> not_found;
        {Off, PayloadLen, _T} ->
            {ok, Frame} = file:pread(Fd, Off, ?HDR_BYTES + PayloadLen),
            case unframe(Frame) of
                {ok, Payload, _} -> {ok, binary_to_term(Payload)};
                {error, R}       -> error({corrupt_entry, Index, R})
            end
    end.

-doc """
Read entries `From..To` (clamped to the live tail), in index order. The live log
is contiguous, so a missing index in range is corruption, not an empty slot:
`read_range` raises rather than silently returning a short list (review #27).
""".
-spec read_range(handle(), pos_integer(), log_index()) -> {ok, [#entry{}]}.
read_range(_S, From, To) when From > To -> {ok, []};
read_range(S = #store{last_index = LI}, From, To0) ->
    To = min(To0, LI),
    Es = [case read_at(S, I) of
              {ok, E}   -> E;
              not_found -> error({log_gap, I, From, To})
          end || I <- lists:seq(From, To)],
    {ok, Es}.

-doc "`{LastIndex, LastTerm}` of the live tail (or the snapshot point if empty).".
-spec last(handle()) -> {log_index(), term_no()}.
last(#store{last_index = LI, last_term = LT}) -> {LI, LT}.

-doc "The term of the entry at `Index` (0/snapshot sentinels handled), or `undefined`.".
-spec term_at(handle(), log_index()) -> term_no() | undefined.
term_at(_S, 0) -> 0;
term_at(#store{snap_index = I, snap_term = T}, I) -> T;
term_at(#store{idx = Idx}, Index) ->
    case maps:get(Index, Idx, undefined) of
        {_Off, _Len, T} -> T;
        undefined       -> undefined
    end.

%%%===================================================================
%%% snapshots (API present; materialization is M3)
%%%===================================================================

-doc "Latest snapshot payload, or `none` (no snapshots are written before M3).".
-spec read_snapshot(handle()) ->
        none | {ok, log_index(), term_no(), [node_id()], term()}.
read_snapshot(#store{snap_index = 0}) -> none;
read_snapshot(S = #store{snap_index = I, snap_term = T}) ->
    {Data, Cfg} = read_snapshot_payload(S),
    {ok, I, T, Cfg, Data}.

-doc "Write a snapshot file atomically. (Exercised from M3; present for the API.)".
-spec write_snapshot(handle(), log_index(), term_no(), [node_id()], term()) -> {ok, handle()}.
write_snapshot(S = #store{dir = Dir}, LastIdx, LastTerm, Config, Data) ->
    Base = filename:join(Dir, snap_name(LastIdx, LastTerm)),
    ok = atomic_write(Base, frame(term_to_binary({Config, Data}, [deterministic]))),
    {ok, S#store{snap_index = LastIdx, snap_term = LastTerm}}.

-doc "Install a leader snapshot then drop the live log. (M3.)".
-spec install_snapshot(handle(), log_index(), term_no(), [node_id()], term()) -> {ok, handle()}.
install_snapshot(_S, _LastIdx, _LastTerm, _Config, _Data) ->
    error(not_implemented_m3).

%%%===================================================================
%%% internals
%%%===================================================================

ns_dir(DataDir, Ns) -> filename:join(DataDir, base64url(Ns)).

base64url(Bin) ->
    binary_to_list(base64:encode(Bin, #{mode => urlsafe, padding => false})).

frame(Payload) ->
    <<?MAGIC:32, (byte_size(Payload)):32, (erlang:crc32(Payload)):32, Payload/binary>>.

%% Parse one frame from the head of `Bin`. Returns the payload + the rest, or an
%% error (bad magic / short / CRC mismatch — i.e. a torn or corrupt frame).
unframe(<<?MAGIC:32, Len:32, CRC:32, Rest/binary>>) when byte_size(Rest) >= Len ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    case erlang:crc32(Payload) of
        CRC -> {ok, Payload, Tail};
        _   -> {error, bad_crc}
    end;
unframe(<<?MAGIC:32, _/binary>>) -> {error, short};
unframe(_)                       -> {error, bad_magic}.

%% Scan the whole log from offset 0, building the index. A torn final frame
%% (incomplete header/payload or bad CRC) is trimmed by truncating the file.
scan_log(Fd) ->
    {ok, 0} = file:position(Fd, 0),
    scan_log(Fd, 0, #{}, 0, 0).

scan_log(Fd, Off, Idx, LastI, LastT) ->
    case file:pread(Fd, Off, ?HDR_BYTES) of
        eof ->
            {Idx, LastI, LastT, Off};
        {ok, <<?MAGIC:32, Len:32, _CRC:32>> = Hdr} ->
            case file:pread(Fd, Off + ?HDR_BYTES, Len) of
                {ok, Payload} when byte_size(Payload) =:= Len ->
                    case unframe(<<Hdr/binary, Payload/binary>>) of
                        {ok, P, _} ->
                            #entry{index = I, term = T} = binary_to_term(P),
                            %% M2 (review #13): the frame is CRC-valid, but a valid frame at
                            %% the wrong index (a non-contiguous or out-of-order entry) means
                            %% the segment is corrupt from here on — trim it as a torn tail
                            %% rather than building an index with a gap/dup. The first live
                            %% entry (empty Idx) is accepted as-is so a future compacted log
                            %% starting above 1 still loads.
                            case map_size(Idx) =:= 0 orelse I =:= LastI + 1 of
                                true ->
                                    Next = Off + ?HDR_BYTES + Len,
                                    scan_log(Fd, Next, Idx#{I => {Off, Len, T}}, I, T);
                                false ->
                                    trim_or_fail(Fd, Off, Len, Idx, LastI, LastT, {discontinuity, I})
                            end;
                        {error, Reason} ->
                            trim_or_fail(Fd, Off, Len, Idx, LastI, LastT, Reason)   %% bad CRC
                    end;
                _ ->
                    trim(Fd, Off, Idx, LastI, LastT)           %% short payload: torn tail
            end;
        {ok, _Partial} ->
            trim(Fd, Off, Idx, LastI, LastT);                  %% short/garbage header
        {error, _} ->
            trim(Fd, Off, Idx, LastI, LastT)
    end.

trim(Fd, Off, Idx, LastI, LastT) ->
    {ok, _} = file:position(Fd, Off),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd),
    {Idx, LastI, LastT, Off}.

%% Read-only, NON-TRUNCATING scan (for open_ro): the same framing + contiguity checks as scan_log, but STOP
%% at the first torn / short / bad-CRC / discontinuous frame — bounding the readable tail — instead of
%% truncating the file or fail-stopping. A concurrent reader must never mutate the live writer's log.
scan_ro(Fd, Off, Idx, LastI, LastT) ->
    case file:pread(Fd, Off, ?HDR_BYTES) of
        {ok, <<?MAGIC:32, Len:32, _CRC:32>> = Hdr} ->
            case file:pread(Fd, Off + ?HDR_BYTES, Len) of
                {ok, Payload} when byte_size(Payload) =:= Len ->
                    case unframe(<<Hdr/binary, Payload/binary>>) of
                        {ok, P, _} ->
                            #entry{index = I, term = T} = binary_to_term(P),
                            case map_size(Idx) =:= 0 orelse I =:= LastI + 1 of
                                true  -> scan_ro(Fd, Off + ?HDR_BYTES + Len, Idx#{I => {Off, Len, T}}, I, T);
                                false -> {Idx, LastI, LastT, Off}   %% discontinuity ⇒ stop
                            end;
                        {error, _} -> {Idx, LastI, LastT, Off}       %% bad CRC / torn ⇒ stop
                    end;
                _ -> {Idx, LastI, LastT, Off}                        %% short payload ⇒ stop
            end;
        _ -> {Idx, LastI, LastT, Off}                                %% eof / short header ⇒ stop
    end.

%% A frame at `Off` failed its integrity/contiguity check. A crash mid-append can only
%% damage the FINAL frame, so if a well-formed frame appears anywhere AFTER this one, this
%% is mid-log corruption (bit-rot), not a torn tail: FAIL-STOP rather than silently
%% truncating — discarding the valid entries after the corrupt point would lose
%% durably-committed data and could let the node re-append divergent indices peers already
%% hold (review #8). We SCAN the tail for the magic instead of trusting this frame's (also
%% suspect) length field, so a corrupt length can't make the peek miss the next frame
%% (review #13). A coincidental magic in payload bytes only over-triggers fail-stop on a
%% genuine torn tail — conservative (recover from peers), never data loss.
trim_or_fail(Fd, Off, _Len, Idx, LastI, LastT, Reason) ->
    {ok, Size} = file:position(Fd, eof),
    From = Off + 4,   %% skip this frame's own magic
    case From < Size andalso file:pread(Fd, From, Size - From) of
        {ok, Tail} ->
            case binary:match(Tail, <<?MAGIC:32>>) of
                nomatch -> trim(Fd, Off, Idx, LastI, LastT);            %% nothing follows ⇒ torn tail
                _       -> error({log_corruption, Reason, Off})         %% a frame follows ⇒ interior
            end;
        _ -> trim(Fd, Off, Idx, LastI, LastT)                          %% at EOF ⇒ torn tail
    end.

assert_contiguous(LastI, Entries) ->
    Want = lists:seq(LastI + 1, LastI + length(Entries)),
    Got  = [I || #entry{index = I} <- Entries],
    case Got of
        Want -> ok;
        _    -> error({non_contiguous_append, LastI, Got})
    end.

recompute_last(Idx, SnapI, SnapT) when map_size(Idx) =:= 0 -> {SnapI, SnapT};
recompute_last(Idx, _SnapI, _SnapT) ->
    LI = lists:max(maps:keys(Idx)),
    {_Off, _Len, LT} = maps:get(LI, Idx),
    {LI, LT}.

peek_snapshot(Dir) ->
    case lists:sort([F || F <- filelib:wildcard("snapshot.*", Dir),
                          not lists:suffix(".tmp", F)]) of
        []    -> {0, 0};
        Files -> parse_snap_name(lists:last(Files))   %% lexical sort ~ latest (zero-padded names)
    end.

snap_name(Idx, Term) ->
    lists:flatten(io_lib:format("snapshot.~20..0b.~20..0b", [Idx, Term])).

parse_snap_name(Name) ->
    case string:tokens(Name, ".") of
        ["snapshot", IdxS, TermS] -> {list_to_integer(IdxS), list_to_integer(TermS)};
        _                         -> {0, 0}
    end.

read_snapshot_payload(#store{snap_index = 0}) -> {none, []};
read_snapshot_payload(#store{dir = Dir, snap_index = I, snap_term = T}) ->
    case file:read_file(filename:join(Dir, snap_name(I, T))) of
        {ok, Bin} ->
            case unframe(Bin) of
                {ok, P, _} -> {Cfg, Data} = binary_to_term(P), {Data, Cfg};
                _          -> {none, []}
            end;
        {error, enoent} -> {none, []}
    end.

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    {ok, Fd} = file:open(Tmp, [write, raw, binary]),
    ok = file:write(Fd, Bytes),
    ok = file:datasync(Fd),
    ok = file:close(Fd),
    ok = file:rename(Tmp, Path),
    ok = sync_dir(filename:dirname(Path)),
    ok.

%% Fsync the directory so a tmp+rename is durable across a power-cut (POSIX: the
%% rename's new dirent is not durable until the directory inode is synced). Best
%% effort — some platforms refuse to open a dir for sync; a failure there must not
%% mask the (already-synced) file write.
sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, DirFd} ->
            _ = file:datasync(DirFd),
            _ = file:close(DirFd),
            ok;
        {error, _} ->
            ok
    end.
