-module(quod_ledger_store).
-moduledoc """
Durable on-disk store for one namespace's **DispersedSimplex block log** — the
append-only list of committed `#entry{}` records, each a block plus the quorum
certificate that finalized its slot.

This is the only quod code that touches disk. It is a plain library (no process,
no registration): every function is synchronous and completes its required `fsync`
before returning, and the handle is threaded by the caller — the writer is
`m:quod_simplex`; `m:quod_catchup` opens a read-only view via `open_ro/2` to serve
a joiner (the dissemination feed will do the same for its pull path in a later slice).

Layout, under `DataDir/<base64url(Ns)>/`:

| file       | holds                                                          |
| ---------- | -------------------------------------------------------------- |
| `log.0001` | append-only CRC-framed `#entry{}` records — the block log      |

Each frame is `<<Magic:32, Len:32, CRC:32, Payload:Len/binary>>` with
`Payload = term_to_binary(Entry, [deterministic])` and `CRC = erlang:crc32(Payload)`.
The in-memory index (`#store.idx`: `index => {Offset, PayloadLen}`) is rebuilt by
scanning `log.0001` at `open/2`; a truncated final frame (a crash mid-append that
never `fsync`'d) is detected by the length/CRC check and trimmed, which is safe
because such an entry was never acknowledged. `open_ro/2` opens a concurrent,
**non-truncating** read-only view for the catch-up/feed server, bounding the
readable tail at the last complete contiguous entry.

Snapshots/compaction are deferred (`doc/deferred.md` §3); nothing compacts yet, so
the full log always reloads.
""".
-include("quod_ledger.hrl").

-export([open/2, open_ro/2, close/1, load/1,
         append/2, read_at/2, read_range/3, last/1]).

-export_type([handle/0]).

-define(MAGIC, 16#915106AA).
-define(HDR_BYTES, 12).   %% Magic:32 ++ Len:32 ++ CRC:32

-record(store, {dir         :: file:filename_all(),
                ns          :: binary(),
                log_fd      :: file:io_device(),
                idx = #{}   :: #{log_index() => {Offset     :: non_neg_integer(),
                                                 PayloadLen :: non_neg_integer()}},
                last_index  = 0 :: log_index(),
                base_offset = 0 :: non_neg_integer()}).   %% next append offset (== log file size)
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
    {Idx, LastI, BaseOff} = scan_log(Fd),
    {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, idx = Idx,
                last_index = LastI, base_offset = BaseOff}}.

-doc """
Open a READ-ONLY handle for a concurrent reader (the catch-up/feed server) alongside the live writer.
NEVER truncates: a torn / short / discontinuous tail — a frame the writer is mid-appending — simply
bounds the readable index, so the reader sees up to the last complete, CRC-valid, contiguous entry.
`read_at`, `read_range`, `last` work on it unchanged; do NOT `append` through it. Errors if the log
does not exist yet.
""".
-spec open_ro(binary(), file:filename_all()) -> {ok, handle()} | {error, no_log | term()}.
open_ro(Ns, DataDir) ->
    Dir = ns_dir(DataDir, Ns),
    case file:open(filename:join(Dir, "log.0001"), [read, raw, binary]) of
        {ok, Fd} ->
            try
                {Idx, LastI, BaseOff} = scan_ro(Fd, 0, #{}, 0),
                {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, idx = Idx,
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

-doc "Reload the durable state `m:quod_simplex` rebuilds from: the full committed block log.".
-spec load(handle()) -> #{log := [#entry{}]}.
load(S = #store{last_index = LastI}) ->
    {ok, Log} = read_range(S, 1, LastI),
    #{log => Log}.

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
append(S = #store{log_fd = Fd, base_offset = Off0, idx = Idx0, last_index = LI0}, Entries) ->
    ok = assert_contiguous(LI0, Entries),
    {Off1, Idx1, LI1} =
        lists:foldl(
          fun(E = #entry{index = I}, {Off, Idx, _LI}) ->
                  Payload = term_to_binary(E, [deterministic]),
                  Frame   = frame(Payload),
                  ok = file:pwrite(Fd, Off, Frame),
                  {Off + byte_size(Frame), Idx#{I => {Off, byte_size(Payload)}}, I}
          end, {Off0, Idx0, LI0}, Entries),
    ok = file:datasync(Fd),
    {ok, S#store{base_offset = Off1, idx = Idx1, last_index = LI1}}.

%%%===================================================================
%%% reads
%%%===================================================================

-doc "Read the entry at `Index`, verifying its CRC.".
-spec read_at(handle(), pos_integer()) -> {ok, #entry{}} | not_found.
read_at(#store{log_fd = Fd, idx = Idx}, Index) ->
    case maps:get(Index, Idx, undefined) of
        undefined -> not_found;
        {Off, PayloadLen} ->
            {ok, Frame} = file:pread(Fd, Off, ?HDR_BYTES + PayloadLen),
            case unframe(Frame) of
                {ok, Payload, _} -> {ok, binary_to_term(Payload)};
                {error, R}       -> error({corrupt_entry, Index, R})
            end
    end.

-doc """
Read entries `From..To` (clamped to the live tail), in index order. The live log
is contiguous, so a missing index in range is corruption, not an empty slot:
`read_range` raises rather than silently returning a short list.
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

-doc "The `LastIndex` of the live tail (0 if empty).".
-spec last(handle()) -> log_index().
last(#store{last_index = LI}) -> LI.

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
    scan_log(Fd, 0, #{}, 0).

scan_log(Fd, Off, Idx, LastI) ->
    case file:pread(Fd, Off, ?HDR_BYTES) of
        eof ->
            {Idx, LastI, Off};
        {ok, <<?MAGIC:32, Len:32, _CRC:32>> = Hdr} ->
            case file:pread(Fd, Off + ?HDR_BYTES, Len) of
                {ok, Payload} when byte_size(Payload) =:= Len ->
                    case unframe(<<Hdr/binary, Payload/binary>>) of
                        {ok, P, _} ->
                            #entry{index = I} = binary_to_term(P),
                            %% A CRC-valid frame at the wrong index (non-contiguous / out-of-order)
                            %% means the segment is corrupt from here on — trim it as a torn tail
                            %% rather than building an index with a gap/dup. The first live entry
                            %% (empty Idx) is accepted as-is so a future compacted log starting above
                            %% 1 still loads.
                            case map_size(Idx) =:= 0 orelse I =:= LastI + 1 of
                                true ->
                                    Next = Off + ?HDR_BYTES + Len,
                                    scan_log(Fd, Next, Idx#{I => {Off, Len}}, I);
                                false ->
                                    trim_or_fail(Fd, Off, Idx, LastI, {discontinuity, I})
                            end;
                        {error, Reason} ->
                            trim_or_fail(Fd, Off, Idx, LastI, Reason)   %% bad CRC
                    end;
                _ ->
                    trim(Fd, Off, Idx, LastI)           %% short payload: torn tail
            end;
        {ok, _Partial} ->
            trim(Fd, Off, Idx, LastI);                  %% short/garbage header
        {error, _} ->
            trim(Fd, Off, Idx, LastI)
    end.

trim(Fd, Off, Idx, LastI) ->
    {ok, _} = file:position(Fd, Off),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd),
    {Idx, LastI, Off}.

%% Read-only, NON-TRUNCATING scan (for open_ro): the same framing + contiguity checks as scan_log, but
%% STOP at the first torn / short / bad-CRC / discontinuous frame — bounding the readable tail — instead
%% of truncating the file or fail-stopping. A concurrent reader must never mutate the live writer's log.
scan_ro(Fd, Off, Idx, LastI) ->
    case file:pread(Fd, Off, ?HDR_BYTES) of
        {ok, <<?MAGIC:32, Len:32, _CRC:32>> = Hdr} ->
            case file:pread(Fd, Off + ?HDR_BYTES, Len) of
                {ok, Payload} when byte_size(Payload) =:= Len ->
                    case unframe(<<Hdr/binary, Payload/binary>>) of
                        {ok, P, _} ->
                            #entry{index = I} = binary_to_term(P),
                            case map_size(Idx) =:= 0 orelse I =:= LastI + 1 of
                                true  -> scan_ro(Fd, Off + ?HDR_BYTES + Len, Idx#{I => {Off, Len}}, I);
                                false -> {Idx, LastI, Off}   %% discontinuity ⇒ stop
                            end;
                        {error, _} -> {Idx, LastI, Off}       %% bad CRC / torn ⇒ stop
                    end;
                _ -> {Idx, LastI, Off}                        %% short payload ⇒ stop
            end;
        _ -> {Idx, LastI, Off}                                %% eof / short header ⇒ stop
    end.

%% A frame at `Off` failed its integrity/contiguity check. A crash mid-append can only
%% damage the FINAL frame, so if a well-formed frame appears anywhere AFTER this one, this
%% is mid-log corruption (bit-rot), not a torn tail: FAIL-STOP rather than silently
%% truncating — discarding the valid entries after the corrupt point would lose
%% durably-committed data and could let the node re-append divergent indices peers already
%% hold. We SCAN the tail for the magic instead of trusting this frame's (also suspect)
%% length field, so a corrupt length can't make the peek miss the next frame. A coincidental
%% magic in payload bytes only over-triggers fail-stop on a genuine torn tail — conservative
%% (recover from peers), never data loss.
trim_or_fail(Fd, Off, Idx, LastI, Reason) ->
    {ok, Size} = file:position(Fd, eof),
    From = Off + 4,   %% skip this frame's own magic
    case From < Size andalso file:pread(Fd, From, Size - From) of
        {ok, Tail} ->
            case binary:match(Tail, <<?MAGIC:32>>) of
                nomatch -> trim(Fd, Off, Idx, LastI);            %% nothing follows ⇒ torn tail
                _       -> error({log_corruption, Reason, Off})  %% a frame follows ⇒ interior
            end;
        _ -> trim(Fd, Off, Idx, LastI)                          %% at EOF ⇒ torn tail
    end.

assert_contiguous(LastI, Entries) ->
    Want = lists:seq(LastI + 1, LastI + length(Entries)),
    Got  = [I || #entry{index = I} <- Entries],
    case Got of
        Want -> ok;
        _    -> error({non_contiguous_append, LastI, Got})
    end.
