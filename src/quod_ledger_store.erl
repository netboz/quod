-module(quod_ledger_store).
-moduledoc """
Durable on-disk store for one namespace's **DispersedSimplex block log** — the
append-only list of committed `#entry{}` records, each a block plus the quorum
certificate that finalized its slot.

This module exclusively owns the committed block log. It is a plain library (no process,
no registration): every function is synchronous and completes its required `fsync`
before returning, and the handle is threaded by the caller — the writer is
`m:quod_simplex`; `m:quod_catchup` opens a read-only view via `open_ro/2` to serve
a joiner. The separate `m:quod_vote_journal` stores only this validator's bounded,
in-flight vote decisions; it never duplicates blocks or knowledge-base data.

Layout, under `LedgerDir/<base64url(Ns)>/`:

| file       | holds                                                     |
| ---------- | --------------------------------------------------------- |
| `log.0001` | append-only CRC-framed `#entry{}` records — the block log |

`m:quod_vote_journal` separately owns `votes.0001` under the configured
**data** root. The roots may coincide, as they do in the Nomad deployment, but
`ledger_dir` can place the replicated block log elsewhere.

Each frame is `<<Magic:32, Len:32, CRC:32, Payload:Len/binary>>` with
`Payload = term_to_binary(Entry, [deterministic])` and `CRC = erlang:crc32(Payload)`.
Entries are strictly contiguous **from index 1** — a compacted log starting higher is
deliberately unsupported until compaction lands WITH its committee checkpoint
(`doc/deferred.md` §3); until then a log not starting at 1 is treated as corruption.

The in-memory index is **sparse**: one 8-byte file offset per `?CP_INTERVAL` entries
(`#store.cps`, a flat binary, ~32 KB per MILLION slots — the handle's heap cost is
effectively height-independent, unlike the ~54 B/slot map it replaced), rebuilt by
scanning `log.0001` at `open/2`. A read seeks to the nearest checkpoint, hops frame
headers to its target, then **streams** frames through one chunked cursor
(`next_frame/2`: `?READ_CHUNK`-sized preads, payloads sliced as zero-copy sub-binaries),
verifying each frame's CRC AND that the decoded entry's index is the one expected — any
drift (bit-rot, a bad checkpoint) raises `{corrupt_entry, ...}`, never a silently wrong
block. A frame length over `?MAX_FRAME_BYTES` is rejected before any allocation.

At `open/2` a truncated FINAL frame (a crash mid-append that never `fsync`'d) is
trimmed, which is safe because such an entry was never acknowledged. Corruption that is
provably interior (an intact frame follows it) fail-stops, and a real `pread` I/O error
fail-stops too — committed entries are never silently discarded on either. `open_ro/2`
opens a concurrent, **non-truncating** read-only view for the catch-up/feed server,
bounding the readable tail at the last complete contiguous entry.

Snapshots/compaction are deferred (`doc/deferred.md` §3); nothing compacts yet, so
the full log always rescans at open.
""".
-include("quod_ledger.hrl").

-export([open/2, ledger_dir/1, open_ro/2, close/1,
         append/2, read_at/2, read_range/3, fold/5, last/1]).
-export([default_data_dir/0, data_dir/1, ns_dir/2]).

-export_type([handle/0]).

-define(OLD_MAGIC, 16#915106AA). %% V1 certificates were not namespace/genesis-bound; reject, never trim
-define(MAGIC,     16#915106AB). %% V2 consensus-signature format
-define(HDR_BYTES, 12).      %% Magic:32 ++ Len:32 ++ CRC:32
-define(CP_INTERVAL, 256).   %% one checkpointed offset per this many entries (sparse index)
-define(READ_CHUNK, 262144). %% bytes per pread when streaming sequential frames (the read cursor)
-define(MAX_FRAME_BYTES, (64 * 1024 * 1024)).  %% sanity cap on a frame's length field — a corrupted
                                               %% Len must never drive a giant pread allocation

-record(store, {dir         :: file:filename_all(),
                ns          :: binary(),
                log_fd      :: file:io_device(),
                cps = <<>>  :: binary(),          %% sparse index: the K-th 8-byte word is the file
                                                  %% offset of entry `1 + K*?CP_INTERVAL`
                last_index  = 0 :: log_index(),
                base_offset = 0 :: non_neg_integer()}).   %% next append offset (== log file size)
-opaque handle() :: #store{}.

%%%===================================================================
%%% open / close
%%%===================================================================

-doc """
The data dir used when none is configured — the ONE definition of the default every
store user (`m:quod_simplex`, `m:quod_catchup`, `m:quod_explorer_http`) resolves against.
""".
-spec default_data_dir() -> file:filename().
default_data_dir() -> filename:join(filename:basedir(user_cache, "quod"), "data").

-doc "The store root from an ns `Config` map — its `data_dir` if set, else `default_data_dir/0`.".
-spec data_dir(map()) -> file:filename_all().
data_dir(Config) ->
    case maps:get(data_dir, Config, undefined) of
        undefined -> default_data_dir();
        Dir       -> Dir
    end.

-doc """
The LEDGER root from an ns `Config` map: `ledger_dir` if set, else `data_dir/1`. The split
exists because the two directories have DIFFERENT durability needs: the ledger is
replicated by consensus itself (any node re-fetches lost history trustlessly via
catch-up against the pinned genesis anchor), so it may live on fast LOCAL disk — while
the identity key and the vote journal (whose loss is not repairable from peers) stay on
the durable `data_dir`. On the production Ceph volume one fdatasync costs 40-106ms and
the per-commit ledger sync was a dominant share of consensus round time.
""".
-spec ledger_dir(map()) -> file:filename_all().
ledger_dir(Config) ->
    case maps:get(ledger_dir, Config, undefined) of
        undefined -> data_dir(Config);
        Dir       -> Dir
    end.

-doc "Open (creating if needed) the on-disk store for `Ns` under `DataDir`.".
-spec open(binary(), file:filename_all()) -> {ok, handle()}.
open(Ns, DataDir) ->
    Dir = ns_dir(DataDir, Ns),
    ok = filelib:ensure_path(Dir),
    LogPath = filename:join(Dir, "log.0001"),
    {ok, Fd} = file:open(LogPath, [read, write, raw, binary]),
    {Cps, LastI, BaseOff} = scan(Fd, trim),
    {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                last_index = LastI, base_offset = BaseOff}}.

-doc """
Open a READ-ONLY handle for a concurrent reader (the catch-up/feed server) alongside the live writer.
NEVER truncates: a torn / short / discontinuous tail — a frame the writer is mid-appending — simply
bounds the readable index, so the reader sees up to the last complete, CRC-valid, contiguous entry.
`read_at`, `read_range`, `fold`, `last` work on it unchanged; do NOT `append` through it. Errors if
the log does not exist yet.
""".
-spec open_ro(binary(), file:filename_all()) -> {ok, handle()} | {error, no_log | term()}.
open_ro(Ns, DataDir) ->
    Dir = ns_dir(DataDir, Ns),
    case file:open(filename:join(Dir, "log.0001"), [read, raw, binary]) of
        {ok, Fd} ->
            try
                {Cps, LastI, BaseOff} = scan(Fd, stop),
                {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                            last_index = LastI, base_offset = BaseOff}}
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

%%%===================================================================
%%% append
%%%===================================================================

-doc """
Append contiguous entries (indices `last_index+1 ..`). One `datasync` for the
batch; returns only after it completes (the entries are durable before
`m:quod_simplex` counts them toward commit).
""".
-spec append(handle(), [#entry{}]) -> {ok, handle()}.
append(S, []) -> {ok, S};
append(S = #store{log_fd = Fd, base_offset = Off0, cps = Cps0, last_index = LI0}, Entries) ->
    ok = assert_contiguous(LI0, Entries),
    {Off1, Cps1, LI1} =
        lists:foldl(
          fun(E = #entry{index = I}, {Off, Cps, _LI}) ->
                  Payload = term_to_binary(E, [deterministic]),
                  Frame   = frame(Payload),
                  ok = file:pwrite(Fd, Off, Frame),
                  {Off + byte_size(Frame), checkpoint(I, Off, Cps), I}
          end, {Off0, Cps0, LI0}, Entries),
    ok = file:datasync(Fd),
    {ok, S#store{base_offset = Off1, cps = Cps1, last_index = LI1}}.

%% Record entry `I`'s frame offset in the sparse index when it opens a checkpoint stride
%% (entries are contiguous from 1, so strides begin at 1, 257, 513, …).
checkpoint(I, Off, Cps) when I rem ?CP_INTERVAL =:= 1 -> <<Cps/binary, Off:64>>;
checkpoint(_I, _Off, Cps)                             -> Cps.

%%%===================================================================
%%% reads
%%%===================================================================

-doc "Read the entry at `Index`, verifying its CRC and its identity (`#entry.index =:= Index`).".
-spec read_at(handle(), pos_integer()) -> {ok, #entry{}} | not_found.
read_at(#store{last_index = LI}, Index) when Index < 1; Index > LI -> not_found;
read_at(S, Index) ->
    {ok, [E]} = read_range(S, Index, Index),
    {ok, E}.

-doc """
Read entries `From..To` (clamped to the live tail), in index order — one checkpoint
seek, then a sequential streamed read. Each entry is CRC- and index-verified; a
mismatch raises `{corrupt_entry, Index, Why}` rather than ever returning a wrong block.
""".
-spec read_range(handle(), pos_integer(), log_index()) -> {ok, [#entry{}]}.
read_range(S = #store{last_index = LI}, From, To0) ->
    case min(To0, LI) of
        To when From > To -> {ok, []};
        To -> {ok, lists:reverse(fold(S, From, To, fun(E, Acc) -> [E | Acc] end, []))}
    end.

-doc """
Fold `Fun` over the committed entries `From..To` in index order, STREAMING the log
through the chunked cursor — bounded memory no matter the range (the boot committee
re-fold and the KB replay run through here). `To` past the live tail is an ERROR, not a
silent partial fold: a caller that believes more is committed than the store holds must
fail loudly (`{fold_beyond_tail, To, Last}`), never act on a truncated view.
""".
-spec fold(handle(), pos_integer(), log_index(), fun((#entry{}, Acc) -> Acc), Acc) -> Acc
              when Acc :: term().
fold(_S, From, To, _Fun, Acc) when From > To -> Acc;
fold(#store{last_index = LI}, _From, To, _Fun, _Acc) when To > LI ->
    error({fold_beyond_tail, To, LI});
fold(S = #store{log_fd = Fd}, From, To, Fun, Acc) ->
    fold_run(Fd, {locate(S, From), <<>>}, From, To, Fun, Acc).

fold_run(_Fd, _Cur, I, To, _Fun, Acc) when I > To -> Acc;
fold_run(Fd, Cur, I, To, Fun, Acc) ->
    case next_frame(Fd, Cur) of
        {frame, Payload, Cur1} ->
            case binary_to_term(Payload) of
                #entry{index = I} = E -> fold_run(Fd, Cur1, I + 1, To, Fun, Fun(E, Acc));
                #entry{index = J}     -> error({corrupt_entry, I, {wrong_index, J}})
            end;
        {stop, Why, At} -> error({corrupt_entry, I, {Why, At}})
    end.

-doc "The `LastIndex` of the live tail (0 if empty).".
-spec last(handle()) -> log_index().
last(#store{last_index = LI}) -> LI.

%%%===================================================================
%%% internals
%%%===================================================================

-doc "The shared on-disk directory for one namespace's ledger and consensus metadata.".
-spec ns_dir(file:filename_all(), binary()) -> file:filename_all().
ns_dir(DataDir, Ns) -> filename:join(DataDir, base64url(Ns)).

base64url(Bin) ->
    binary_to_list(base64:encode(Bin, #{mode => urlsafe, padding => false})).

frame(Payload) ->
    <<?MAGIC:32, (byte_size(Payload)):32, (erlang:crc32(Payload)):32, Payload/binary>>.

%% The file offset of entry `I` (the caller has bounds-checked `1 =< I =< last_index`): jump
%% to the nearest checkpoint at or below `I`, then hop frame headers forward — headers only,
%% no payload reads. At most `?CP_INTERVAL - 1` hops.
locate(#store{log_fd = Fd, cps = Cps}, I) ->
    K = (I - 1) div ?CP_INTERVAL,
    <<_:K/binary-unit:64, Off:64, _/binary>> = Cps,
    skip_frames(Fd, Off, (I - 1) rem ?CP_INTERVAL).

skip_frames(_Fd, Off, 0) -> Off;
skip_frames(Fd, Off, N) ->
    case file:pread(Fd, Off, ?HDR_BYTES) of
        {ok, <<?MAGIC:32, Len:32, _CRC:32>>} when Len =< ?MAX_FRAME_BYTES ->
            skip_frames(Fd, Off + ?HDR_BYTES + Len, N - 1);
        Other -> error({corrupt_log, Off, Other})
    end.

%%%===================================================================
%%% the frame cursor — every reader walks frames through here
%%%===================================================================

%% A cursor is `{Off, Buf}`: `Buf` holds the file's bytes starting at absolute offset `Off`
%% (possibly none/partial; refilled in ?READ_CHUNK slabs, so sequential consumers cost ~one
%% pread per few hundred frames instead of two per frame). next_frame/2 parses the frame at
%% the cursor: `{frame, Payload, Cursor'}` with `Payload` a zero-copy sub-binary, or
%% `{stop, Why, Off}` — `eof` (clean end exactly at Off) | `short` (torn: bytes exist but
%% not a whole frame) | `{unsupported_format, 1}` | `bad_magic` | `bad_crc` |
%% `{frame_too_big, Len}` | `{io_error, R}`.
%% The framing rules live exactly once, here; the scans and reads only dispatch on `Why`.
next_frame(Fd, {Off, Buf0}) ->
    case fill(Fd, Off, Buf0, ?HDR_BYTES) of
        {short, <<>>} -> {stop, eof, Off};
        %% Four legacy-magic bytes are already an unambiguous V1 segment,
        %% even when the rest of its header was torn. Never reinterpret that
        %% identifiable incompatible format as a trimmable V2 append tail.
        {short, <<?OLD_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 1}, Off};
        {short, _}    -> {stop, short, Off};
        {io_error, R} -> {stop, {io_error, R}, Off};
        {ok, Buf1} ->
            case Buf1 of
                <<?OLD_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 1}, Off};
                <<?MAGIC:32, Len:32, _:32, _/binary>> when Len > ?MAX_FRAME_BYTES ->
                    {stop, {frame_too_big, Len}, Off};
                <<?MAGIC:32, Len:32, CRC:32, _/binary>> ->
                    case fill(Fd, Off, Buf1, ?HDR_BYTES + Len) of
                        {short, _}    -> {stop, short, Off};
                        {io_error, R} -> {stop, {io_error, R}, Off};
                        {ok, Buf2} ->
                            <<_:?HDR_BYTES/binary, Payload:Len/binary, Tail/binary>> = Buf2,
                            case erlang:crc32(Payload) of
                                CRC -> {frame, Payload, {Off + ?HDR_BYTES + Len, Tail}};
                                _   -> {stop, bad_crc, Off}
                            end
                    end;
                _ -> {stop, bad_magic, Off}
            end
    end.

%% Grow `Buf` (the bytes at `Off`) to at least `Need` bytes with one ?READ_CHUNK-or-bigger
%% pread. `{short, Buf'}` = the file ends before `Need` bytes (pread returns short only at EOF).
fill(_Fd, _Off, Buf, Need) when byte_size(Buf) >= Need -> {ok, Buf};
fill(Fd, Off, Buf, Need) ->
    case file:pread(Fd, Off + byte_size(Buf), max(?READ_CHUNK, Need - byte_size(Buf))) of
        {ok, More} ->
            Buf1 = <<Buf/binary, More/binary>>,
            case byte_size(Buf1) >= Need of
                true  -> {ok, Buf1};
                false -> {short, Buf1}
            end;
        eof        -> {short, Buf};
        {error, R} -> {io_error, R}
    end.

%%%===================================================================
%%% the open-time scan (index rebuild + tail recovery)
%%%===================================================================

%% Walk the whole log from offset 0, rebuilding the sparse checkpoint index and checking
%% contiguity from index 1. `Mode` decides what a bad tail does: the WRITER (`trim`)
%% recovers/fail-stops; a READ-ONLY view (`stop`) only bounds itself — it must never
%% mutate the live writer's file.
scan(Fd, Mode) -> scan(Fd, {0, <<>>}, <<>>, 0, Mode).

scan(Fd, Cur = {Off, _}, Cps, LastI, Mode) ->
    case next_frame(Fd, Cur) of
        {frame, Payload, Cur1} ->
            #entry{index = I} = binary_to_term(Payload),
            %% A CRC-valid frame at the wrong index — including a first frame that is not
            %% index 1 — means the segment is corrupt from here on (see the moduledoc:
            %% base-above-1 logs are unsupported until compaction lands with its committee
            %% checkpoint), so it is handled as bad, never silently indexed.
            case I =:= LastI + 1 of
                true  -> scan(Fd, Cur1, checkpoint(I, Off, Cps), I, Mode);
                false -> scan_bad(Fd, Off, Cps, LastI, {discontinuity, I}, Mode)
            end;
        {stop, eof, EndOff} -> {Cps, LastI, EndOff};
        {stop, short, At}   -> scan_torn(Fd, At, Cps, LastI, Mode);
        {stop, {unsupported_format, Version}, At} ->
            error({unsupported_ledger_format, Version, At});
        {stop, {io_error, R}, At} -> scan_io_error(At, Cps, LastI, R, Mode);
        {stop, Why, At}     -> scan_bad(Fd, At, Cps, LastI, Why, Mode)   %% bad_magic | bad_crc | frame_too_big
    end.

%% A SHORT frame (incomplete header/payload at EOF) is the torn tail of a crashed append:
%% the writer trims it (it was never acknowledged); a reader bounds its view before it.
scan_torn(Fd, Off, Cps, LastI, trim)  -> trim(Fd, Off, Cps, LastI);
scan_torn(_Fd, Off, Cps, LastI, stop) -> {Cps, LastI, Off}.

%% A WELL-SIZED but invalid frame (bad magic/CRC, insane length, wrong index): a torn tail
%% if nothing intact follows, interior corruption (fail-stop) if a frame does — the peek in
%% trim_or_fail decides. This is what keeps committed entries from being silently discarded.
scan_bad(Fd, Off, Cps, LastI, Why, trim)   -> trim_or_fail(Fd, Off, Cps, LastI, Why);
scan_bad(_Fd, Off, Cps, LastI, _Why, stop) -> {Cps, LastI, Off}.

%% A pread I/O ERROR is neither a torn tail nor provable corruption — NEVER truncate on it
%% (a transient eio must not discard durably-committed entries): the writer's open fails
%% loudly and the supervisor retries. A read-only view just bounds itself.
scan_io_error(Off, _Cps, _LastI, R, trim) -> error({log_io_error, Off, R});
scan_io_error(Off, Cps, LastI, _R, stop)  -> {Cps, LastI, Off}.

trim(Fd, Off, Cps, LastI) ->
    {ok, _} = file:position(Fd, Off),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd),
    {Cps, LastI, Off}.

%% A frame at `Off` failed its integrity/contiguity check. A crash mid-append can only
%% damage the FINAL frame, so if a well-formed frame appears anywhere AFTER this one, this
%% is mid-log corruption (bit-rot), not a torn tail: FAIL-STOP rather than silently
%% truncating — discarding the valid entries after the corrupt point would lose
%% durably-committed data and could let the node re-append divergent indices peers already
%% hold. We SCAN the tail for the magic instead of trusting this frame's (also suspect)
%% length field, so a corrupt length can't make the peek miss the next frame. A coincidental
%% magic in payload bytes only over-triggers fail-stop on a genuine torn tail — conservative
%% (recover from peers), never data loss.
trim_or_fail(Fd, Off, Cps, LastI, Reason) ->
    case file:position(Fd, eof) of
        {ok, Size} ->
            From = Off + 4,   %% skip this frame's own magic
            case tail_contains_magic(Fd, From, Size) of
                false ->
                    trim(Fd, Off, Cps, LastI);                    %% nothing intact follows
                true ->
                    error({log_corruption, Reason, Off});         %% interior damage
                {error, At, R} ->
                    error({log_io_error, At, R})
            end;
        {error, R} ->
            error({log_io_error, Off, R})
    end.

%% Scan a suspect tail in bounded windows. Consecutive reads overlap by three
%% bytes so either four-byte magic is detected even when split across a chunk
%% boundary. The size probe above promised every requested byte: EOF or a short
%% read is therefore an I/O failure, never permission to discard committed data.
tail_contains_magic(_Fd, Pos, Size) when Pos >= Size ->
    false;
tail_contains_magic(Fd, Pos, Size) ->
    Len = min(?READ_CHUNK, Size - Pos),
    case file:pread(Fd, Pos, Len) of
        {ok, Bin} when byte_size(Bin) =:= Len ->
            case binary:match(
                   Bin, [<<?MAGIC:32>>, <<?OLD_MAGIC:32>>]) of
                nomatch when Pos + Len >= Size ->
                    false;
                nomatch ->
                    tail_contains_magic(Fd, Pos + Len - 3, Size);
                _ ->
                    true
            end;
        {ok, _Short} ->
            {error, Pos, unexpected_eof};
        eof ->
            {error, Pos, unexpected_eof};
        {error, R} ->
            {error, Pos, R}
    end.

assert_contiguous(LastI, Entries) ->
    Want = lists:seq(LastI + 1, LastI + length(Entries)),
    Got  = [I || #entry{index = I} <- Entries],
    case Got of
        Want -> ok;
        _    -> error({non_contiguous_append, LastI, Got})
    end.
