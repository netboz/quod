-module(quod_ledger_store).
-moduledoc """
One append-only archive for material ontology history and its selected consensus
proofs. V8 groups contain a fixed-size header, streamed proof-block frames,
contiguous material entry frames and a completion footer. One datasync commits
a whole group before the owner publishes its new material height or releases
signing-journal custody. Empty protocol carriers occupy proof space only.

A selected proof span may be reused or extended by later entries through
backward-only local offsets in this same archive. Extending a carrier parent
path does not copy its archived prefix. Those offsets are never signed authority or network claims.
The existing consensus/history verifier owns finality; the store owns exact
bytes, CRC checks, entry contiguity and complete-group durability.

Sparse checkpoints retain a material-entry offset and its group offset every
256 entries: 64KB per million entries, with no per-block map. Material seeks
hop at most 255 material headers and skip proof extents directly. Sequential
reads retain a chunked cursor; proof reads return one exact block at a time.
Captured sessions share only the immutable index and committed boundary, never
a raw file handle or a later append. Normal reads do not rescan history.

An incomplete final group, including complete orphan proof frames, contributes
no readable material entries. Writer recovery trims from that group's start;
read-only recovery leaves the file untouched. Damage before a completed group
fails loudly in both modes. Identifiable legacy formats and I/O errors never
authorize truncation. Full index reconstruction belongs to explicit open;
portable snapshots and compaction remain deferred.
""".
-include("quod_ledger.hrl").

-export([group_size/2, staging_path_in/1, proof_frame_size/1, open/2, open/3, ledger_dir/1, open_ro/2, open_ro/3,
         snapshot/1, resume/1,
         open_ro_snapshot/1, close/1,
         namespace/1,
         append/2, proof_cursor/2, proof_next/2,
         transfer_cursor/2, transfer_next/2,
         staging_path/1, with_proof_stage/2, stage_proof/2, staged_proof_source/1, reset_proof_stage/1,
         read_at/2, read_at/3, read_range/4, fold/5, fold_groups/3, last/1]).
-export([default_data_dir/0, data_dir/1, ns_dir/2]).

-export_type([handle/0, session/0, proof_source/0, proof_cursor/0, transfer_cursor/0,
              proof_stage/0]).

%% Every superseded frame magic stays named here so an old segment is rejected
%% as an identifiable format, never mistaken for corruption or a trimmable tail.
-define(V1_MAGIC,  16#915106AA). %% certificates were not namespace/genesis-bound
-define(V2_MAGIC,  16#915106AB). %% consensus-signature format; phash2 OCC read-sets
-define(V3_MAGIC,  16#915106AC). %% mutation-version OCC tokens; content-only block payload
-define(V4_MAGIC,  16#915106AD). %% shared tagged term payload with DTX controls
-define(V5_MAGIC,  16#915106AE). %% byte-canonical envelopes carrying transaction V13
-define(V6_MAGIC,  16#915106AF). %% transaction V14, five-phase atomic controls
-define(V7_MAGIC,  16#915106B0). %% transaction V15, Vote/Resolve/Complete
-define(MAGIC,     16#915106B1). %% V8: complete proof/material groups
-define(HDR_BYTES, 12).      %% Magic:32 ++ Len:32 ++ CRC:32
-define(CP_INTERVAL, 256).   %% one checkpointed offset per this many entries (sparse index)
-define(READ_CHUNK, 262144). %% bytes per pread when streaming sequential frames (the read cursor)
-define(MAX_FRAME_BYTES, (64 * 1024 * 1024)).  %% sanity cap on a frame's length field — a corrupted
                                               %% Len must never drive a giant pread allocation

-record(store, {dir         :: file:filename_all(),
                ns          :: binary(),
                log_fd      :: file:io_device(),
                cps = <<>>  :: binary(),          %% sparse {entry offset, group offset} pairs
                last_index  = 0 :: log_index(),
                base_offset = 0 :: non_neg_integer(), %% next append offset (== log file size)
                symbol_mode = materialized :: materialized | wrapped}).
-opaque handle() :: #store{}.

%% A read snapshot copies the writer's already-verified sparse index without
%% sharing its raw file handle. A catch-up worker opens its own read-only handle
%% and is bounded to this exact committed prefix even if the writer appends
%% concurrently.
-record(session, {dir         :: file:filename_all(),
                  ns          :: binary(),
                  cps = <<>>  :: binary(),
                  last_index  = 0 :: log_index(),
                  base_offset = 0 :: non_neg_integer(),
                  symbol_mode = materialized :: materialized | wrapped}).
-opaque session() :: #session{}.

%% One group has fixed-size framing metadata, streamed proof frames, material
%% entry frames, and a completion footer. Offsets are local I/O metadata only.
-record(group, {start, first, count, proof_start, proof_bytes,
                entries_start, entries_end, finish, continuation = 0}).
-record(proof_cursor, {cursor, finish, continuation = 0}).
-opaque proof_cursor() :: #proof_cursor{}.
-record(transfer_cursor, {material, next, last, proof, root_hash, phase = entries}).
-opaque transfer_cursor() :: #transfer_cursor{}.
-record(proof_stage, {fd, bytes = 0}).
-opaque proof_stage() :: #proof_stage{}.
%% The source advertises physical framed bytes, not a flattened witness blob.
%% The caller retains ownership of its iterator; each step returns exact block
%% bytes or `done`. Reuse points at a material entry in this captured archive.
-type proof_source() :: none | {reuse, pos_integer()} |
                        {extend, proof_source(), pos_integer()} |
                        {non_neg_integer(), fun((term()) -> done | {binary(), term()}), term()}.

-doc "Return the ontology whose ledger this handle reads.".
-spec namespace(handle()) -> binary().
namespace(#store{ns = Ns}) -> Ns.

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
the identity key and signing journal (whose loss is not repairable from peers) stay on
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
    open(Ns, DataDir, materialized).

-doc "Open a store whose decoded views use target-owned or opaque foreign symbols.".
-spec open(binary(), file:filename_all(), materialized | wrapped) ->
          {ok, handle()}.
open(Ns, DataDir, SymbolMode)
  when SymbolMode =:= materialized; SymbolMode =:= wrapped ->
    Dir = ns_dir(DataDir, Ns),
    ok = filelib:ensure_path(Dir),
    LogPath = filename:join(Dir, "log.0001"),
    {ok, Fd} = traced_file_open(
                 LogPath, [read, write, raw, binary], read_write, Ns),
    try
        {Cps, LastI, BaseOff} = scan(Fd, trim, SymbolMode, Ns),
        {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                    last_index = LastI, base_offset = BaseOff,
                    symbol_mode = SymbolMode}}
    catch C:R:Stack ->
        _ = file:close(Fd),
        erlang:raise(C, R, Stack)
    end.

-doc """
Reconstruct a READ-ONLY index for cold recovery or explicit stopped-ledger inspection.
Live readers borrow the owner's session through `open_ro_snapshot/1` instead.
NEVER truncates: a torn / short / discontinuous tail bounds the reconstructed
index at the last complete, CRC-valid, contiguous entry.
`read_at`, `read_range`, `fold`, `last` work on it unchanged; do NOT `append` through it. Errors if
the log does not exist yet.
""".
-spec open_ro(binary(), file:filename_all()) -> {ok, handle()} | {error, no_log | term()}.
open_ro(Ns, DataDir) ->
    open_ro(Ns, DataDir, materialized).

-doc "Open a read-only store with the selected symbol representation.".
-spec open_ro(binary(), file:filename_all(), materialized | wrapped) ->
          {ok, handle()} | {error, no_log | term()}.
open_ro(Ns, DataDir, SymbolMode)
  when SymbolMode =:= materialized; SymbolMode =:= wrapped ->
    Dir = ns_dir(DataDir, Ns),
    case traced_file_open(
           filename:join(Dir, "log.0001"), [read, raw, binary], read_only,
           Ns) of
        {ok, Fd} ->
            try
                {Cps, LastI, BaseOff} = scan(Fd, stop, SymbolMode, Ns),
                {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                            last_index = LastI, base_offset = BaseOff,
                            symbol_mode = SymbolMode}}
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

-doc "Copy the exact committed prefix and its already-verified sparse index.".
-spec snapshot(handle()) -> session().
snapshot(#store{dir = Dir, ns = Ns, cps = Cps,
               last_index = LastIndex, base_offset = BaseOffset,
               symbol_mode = SymbolMode}) ->
    #session{dir = Dir, ns = Ns, cps = Cps,
             last_index = LastIndex, base_offset = BaseOffset,
             symbol_mode = SymbolMode}.

-doc """
Resume the sole append owner from its captured, already-verified index without
rescanning the ledger. The file must still end at the captured boundary; any
other writer or torn append makes the session stale and forces the caller back
through the ordinary recovery open.
""".
-spec resume(session()) -> {ok, handle()} | {error, changed | term()}.
resume(#session{dir = Dir, ns = Ns, cps = Cps,
                last_index = LastIndex, base_offset = BaseOffset,
                symbol_mode = SymbolMode}) ->
    LogPath = filename:join(Dir, "log.0001"),
    case traced_file_open(
           LogPath, [read, write, raw, binary], read_write, Ns) of
        {ok, Fd} ->
            case file:position(Fd, eof) of
                {ok, BaseOffset} ->
                    {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                                last_index = LastIndex,
                                base_offset = BaseOffset,
                                symbol_mode = SymbolMode}};
                {ok, _DifferentSize} ->
                    _ = file:close(Fd),
                    {error, changed};
                {error, Reason} ->
                    _ = file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
Open a read-only handle over an exact writer snapshot without rescanning the
log. An append after the snapshot is harmless: this handle remains bounded to
the captured last index. A shorter file refuses the snapshot; CRC and index
checks still protect every returned frame.
""".
-spec open_ro_snapshot(session()) -> {ok, handle()} | {error, changed | term()}.
open_ro_snapshot(#session{dir = Dir, ns = Ns, cps = Cps,
                last_index = LastIndex, base_offset = BaseOffset,
                symbol_mode = SymbolMode}) ->
    LogPath = filename:join(Dir, "log.0001"),
    case traced_file_open(LogPath, [read, raw, binary], read_only, Ns) of
        {ok, Fd} ->
            case file:position(Fd, eof) of
                {ok, CurrentSize} when CurrentSize >= BaseOffset ->
                    {ok, #store{dir = Dir, ns = Ns, log_fd = Fd, cps = Cps,
                                last_index = LastIndex,
                                base_offset = BaseOffset,
                                symbol_mode = SymbolMode}};
                {ok, _ShorterSize} ->
                    _ = file:close(Fd),
                    {error, changed};
                {error, Reason} ->
                    _ = file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% append
%%%===================================================================

-doc """
Append one complete proof/material group. Entries are contiguous material
heights; proof blocks never increment them. The source is already verified by
consensus or the history verifier. This store checks framing and contiguity,
not consensus authority. One successful datasync publishes the entire group.
""".
-spec append(handle(), {proof_source(), [quod_ledger:entry_artifact()]}) -> {ok, handle()}.
append(S, {none, []}) -> {ok, S};
append(S = #store{ns = Ns, log_fd = Fd, base_offset = Off, cps = Cps,
                  last_index = Last}, {Source, [_ | _] = Entries}) ->
    ok = assert_contiguous(Last, Entries),
    quod_trace:with_span(
      quod_trace:context(), <<"quod.ledger.append_batch">>, internal,
      #{'quod.namespace' => Ns, 'quod.ledger.entries' => length(Entries)},
      fun(SpanCtx) ->
          EncodeStarted = erlang:monotonic_time(),
          EntryBytes = lists:sum([framed_size(entry_bytes(E)) || E <- Entries]),
          {NewProofBytes, SpanStart, SpanBytes, Continuation} = source_extent(Source, S, Off),
          Header = frame(<<0, (Last + 1):64, (length(Entries)):64,
                           NewProofBytes:64, EntryBytes:64, SpanStart:64, SpanBytes:64, Continuation:64>>),
          EntryStart = Off + byte_size(Header) + NewProofBytes,
          EntryEnd = EntryStart + EntryBytes,
          Footer = group_footer(Off, EntryEnd),
          EncodeNative = erlang:monotonic_time() - EncodeStarted,
          WriteStarted = erlang:monotonic_time(),
          ok = file:pwrite(Fd, Off, Header),
          EntryStart = write_proofs(Fd, Off + byte_size(Header), EntryStart, Source),
          {EntryEnd, Cps1} = lists:foldl(fun(E, {At, Index}) ->
              Bytes = frame(<<2, (entry_bytes(E))/binary>>),
              ok = file:pwrite(Fd, At, Bytes),
              {At + byte_size(Bytes), checkpoint(quod_ledger:entry_index(E), At, Off, Index)}
          end, {EntryStart, Cps}, Entries),
          ok = file:pwrite(Fd, EntryEnd, Footer),
          Finish = EntryEnd + byte_size(Footer),
          _ = quod_trace:set_attributes(SpanCtx,
                #{'quod.ledger.bytes' => Finish - Off,
                  'quod.ledger.proof_bytes' => NewProofBytes,
                  'quod.ledger.encode_us' => native_us(EncodeNative),
                  'quod.ledger.write_us' => native_us(erlang:monotonic_time() - WriteStarted)}),
          ok = quod_trace:with_span(
                 quod_trace:context(), <<"quod.ledger.datasync">>, internal,
                 #{'quod.namespace' => Ns}, fun(_) -> file:datasync(Fd) end),
          {ok, S#store{base_offset = Finish, cps = Cps1,
                       last_index = Last + length(Entries)}}
      end).

-doc "Physical bytes added by one group, including its framing and newly owned proof span.".
-spec group_size(proof_source(), [quod_ledger:entry_artifact()]) -> non_neg_integer().
group_size(Source, Entries) ->
    group_header_size() + byte_size(group_footer(0, 0)) + new_proof_bytes(Source) +
        lists:sum([framed_size(entry_bytes(E)) || E <- Entries]).

new_proof_bytes(none) -> 0;
new_proof_bytes({reuse, _}) -> 0;
new_proof_bytes({extend, Source, _}) -> new_proof_bytes(Source);
new_proof_bytes({Size, Next, _}) when is_function(Next, 1) -> Size.

entry_bytes(E) -> {ok, Bytes} = quod_ledger:encode_entry(E), Bytes.
framed_size(Bytes) -> ?HDR_BYTES + 1 + byte_size(Bytes).

-doc "Physical size of one exact proof-block frame for a streamed append source.".
-spec proof_frame_size(binary()) -> pos_integer().
proof_frame_size(Bytes) when is_binary(Bytes) -> framed_size(Bytes).
group_header_size() -> ?HDR_BYTES + 1 + 7 * 8.
group_footer(Start, EntryEnd) -> frame(<<3, Start:64, (EntryEnd + ?HDR_BYTES + 17):64>>).

source_extent(none, _S, _Off) -> {0, 0, 0, 0};
source_extent({reuse, Index}, S, _Off) ->
    {_At, Group} = locate(S, Index),
    {0, Group#group.proof_start, Group#group.proof_bytes, Group#group.continuation};
source_extent({extend, Source, Index}, S, Off) ->
    {Size, Start, Size, 0} = source_extent(Source, S, Off),
    true = Size > 0,
    {_At, Previous} = locate(S, Index),
    Continuation = case Previous#group.proof_bytes of
        0 -> 0;
        _ -> Previous#group.start
    end,
    {Size, Start, Size, Continuation};
source_extent({Size, Next, _State}, _S, Off)
  when is_integer(Size), Size > 0, is_function(Next, 1) ->
    {Size, Off + group_header_size(), Size, 0}.

write_proofs(Fd, At, End, {extend, Source, _}) -> write_proofs(Fd, At, End, Source);
write_proofs(_Fd, At, At, none) -> At;
write_proofs(_Fd, At, At, {reuse, _}) -> At;
write_proofs(Fd, At, End, {_Size, Next, State}) ->
    case Next(State) of
        done when At =:= End -> At;
        {Bytes, State1} when is_binary(Bytes) ->
            Frame = frame(<<1, Bytes/binary>>),
            case At + byte_size(Frame) =< End of
                true ->
                    ok = file:pwrite(Fd, At, Frame),
                    write_proofs(Fd, At + byte_size(Frame), End, {0, Next, State1});
                false -> error(proof_extent_mismatch)
            end;
        _ -> error(proof_extent_mismatch)
    end.

%% Each checkpoint retains two offsets, not a per-block hash map. The group
%% offset lets an arbitrary material seek obtain its proof span without walking
%% backward through the chain. At one row per 256 entries this is 64KB/million.
checkpoint(I, Off, Group, Cps) when I rem ?CP_INTERVAL =:= 1 ->
    <<Cps/binary, Off:64, Group:64>>;
checkpoint(_, _, _, Cps) -> Cps.

-doc "Open the selected proof span for one material entry in this captured prefix.".
-spec proof_cursor(handle(), pos_integer()) -> {ok, proof_cursor()} | not_found.
proof_cursor(#store{last_index = Last}, I) when I < 1; I > Last -> not_found;
proof_cursor(S, I) ->
    {_At, G} = locate(S, I),
    {ok, group_proof_cursor(G)}.

group_proof_cursor(G) ->
    #proof_cursor{cursor = {G#group.proof_start, <<>>},
                   finish = G#group.proof_start + G#group.proof_bytes,
                   continuation = G#group.continuation}.

-doc "Read one exact proof block; the cursor cannot escape the captured archive.".
-spec proof_next(handle(), proof_cursor()) -> done | {ok, binary(), proof_cursor()}.
proof_next(_S, #proof_cursor{cursor = {End, _}, finish = End, continuation = 0}) -> done;
proof_next(S = #store{log_fd = Fd},
           #proof_cursor{cursor = {End, _}, finish = End, continuation = Offset}) ->
    proof_next(S, group_proof_cursor(read_group(Fd, Offset)));
proof_next(#store{log_fd = Fd, base_offset = Boundary},
           #proof_cursor{cursor = {At, _} = Cur, finish = End} = Cursor) when End =< Boundary ->
    case next_frame(Fd, Cur) of
        {frame, <<1, Bytes/binary>>, {Next, _} = Cur1} when Next =< End ->
            {ok, Bytes, Cursor#proof_cursor{cursor = Cur1}};
        Other -> error({corrupt_proof, At, Other})
    end.

-doc """
Capture the remainder of the selected archive group containing a material
height. Entries precede the streamed proof on the wire, so the receiver can
check its head certificate before consuming ancestry. The cursor keeps local
offsets private and is bounded to this handle's captured committed prefix.
It crosses page boundaries without seeking again. A range ending inside a
group must still consume that group through its last material entry.
""".
-spec transfer_cursor(handle(), pos_integer()) ->
          {ok, pos_integer(), transfer_cursor()} | not_found.
transfer_cursor(#store{last_index = Last}, I) when I < 1; I > Last -> not_found;
transfer_cursor(S, I) ->
    {At, G} = locate(S, I),
    RootHash = case I of
        1 -> none;
        _ ->
            {ok, [Previous]} = read_range(S, I - 1, I - 1, bytes),
            {ok, Hash} = quod_ledger:entry_block_hash(Previous),
            Hash
    end,
    Last = G#group.first + G#group.count - 1,
    {ok, Last, #transfer_cursor{material = {{At, <<>>}, G}, next = I,
                                last = Last, root_hash = RootHash,
                                proof = group_proof_cursor(G)}}.

-doc """
Read one opaque material envelope or proof block for the existing page reader.
The previous material hash bounds ancestry: shared archive spans must not make
each request retransmit the whole prefix. This structural cutoff grants no
authority; the receiving finality verifier checks the exact era/root and every
link. No application symbols are materialized while traversing proof bytes.
""".
-spec transfer_next(handle(), transfer_cursor()) ->
          done | {ok, {entry | proof, binary()}, transfer_cursor()}.
transfer_next(_S, #transfer_cursor{phase = done}) -> done;
transfer_next(S, C = #transfer_cursor{phase = entries, next = I, last = Last})
  when I > Last ->
    transfer_next(S, C#transfer_cursor{phase = proof, material = none});
transfer_next(#store{log_fd = Fd}, C = #transfer_cursor{phase = entries,
                                                       material = Cur, next = I}) ->
    {frame, Bytes, Next} = next_material(Fd, Cur),
    case quod_ledger:entry_index(Bytes) of
        I -> {ok, {entry, Bytes}, C#transfer_cursor{material = Next, next = I + 1}};
        Other -> error({corrupt_entry, I, {wrong_index, Other}})
    end;
transfer_next(S, C = #transfer_cursor{phase = proof, proof = Cur, root_hash = Root}) ->
    case proof_next(S, Cur) of
        done when Root =:= none -> done;
        done -> error({incomplete_archived_proof, C#transfer_cursor.last});
        {ok, Bytes, Next} ->
            {ok, Parent} = quod_ledger:block_parent(Bytes),
            Phase = case Parent of {_, _, Root} -> done; _ -> proof end,
            {ok, {proof, Bytes}, C#transfer_cursor{proof = Next, phase = Phase}}
    end.

-doc """
Own temporary proof bytes for one existing fetch worker. The unnamed file uses
the archive's frame reader; it is not a second durable log or a recovery source.
The standard file process permits the final append owner to consume the frozen
source while this worker waits for its acknowledgement. Worker death closes
the descriptor, including an untrappable kill. The existing work owner must
retain Path before the worker opens it and remove it on DOWN as well, covering
interruption between exclusive creation and unlink. No proof bytes are written
until unlink succeeds.
The caller must account for incoming bytes before staging and verify the whole
selected witness before passing its source to the append owner.
""".
-spec with_proof_stage(file:filename_all(), fun((proof_stage()) -> Result)) -> Result
    when Result :: term().
with_proof_stage(Path, Fun) ->
    {ok, Fd} = file:open(Path, [read, write, binary, exclusive]),
    try
        ok = file:delete(Path),
        Fun(#proof_stage{fd = Fd})
    after
        _ = file:close(Fd),
        _ = file:delete(Path)
    end.

-doc "Allocate a private staging name for the existing work owner to retain before starting its worker.".
-spec staging_path(handle() | session()) -> file:filename_all().
staging_path(#store{dir = Dir}) -> staging_path_in(Dir);
staging_path(#session{dir = Dir}) -> staging_path_in(Dir).

staging_path_in(Directory) ->
    filename:join(Directory, ".proof-" ++ base64url(crypto:strong_rand_bytes(16))).

-spec stage_proof(proof_stage(), binary()) -> proof_stage().
stage_proof(Stage = #proof_stage{fd = Fd, bytes = Size}, Bytes) when is_binary(Bytes) ->
    ok = file:write(Fd, frame(<<1, Bytes/binary>>)),
    Stage#proof_stage{bytes = Size + proof_frame_size(Bytes)}.

-doc "Borrow a frozen staged span until the enclosing worker's callback returns.".
-spec staged_proof_source(proof_stage()) -> proof_source().
staged_proof_source(#proof_stage{bytes = 0}) -> none;
staged_proof_source(#proof_stage{fd = Fd, bytes = Size}) ->
    {Size, fun({End, _}) when End =:= Size -> done;
              (Cur) ->
                  case next_frame(Fd, Cur) of
                      {frame, <<1, Bytes/binary>>, {End, _} = Next} when End =< Size ->
                          {Bytes, Next};
                      Other -> error({invalid_proof_stage, Other})
                  end
           end, {0, <<>>}}.

-doc "Release a staged span only after its complete append acknowledgement; old sources cease to be valid.".
-spec reset_proof_stage(proof_stage()) -> proof_stage().
reset_proof_stage(#proof_stage{fd = Fd}) ->
    {ok, 0} = file:position(Fd, 0),
    ok = file:truncate(Fd),
    #proof_stage{fd = Fd}.

%%%===================================================================
%%% reads
%%%===================================================================

-doc "Read the entry at `Index`, verifying its CRC and its identity (`#entry.index =:= Index`).".
-spec read_at(handle(), pos_integer()) -> {ok, quod_ledger:entry_artifact()} | not_found.
read_at(S, Index) -> read_at(S, Index, all).

-doc "Read one full entry or exact point selection through the same CRC/index-checked frame cursor.".
-spec read_at(handle(), pos_integer(), term()) ->
          {ok, quod_ledger:entry_artifact() | quod_ledger:selected_entry()} | not_found.
read_at(#store{last_index = LI}, Index, _) when Index < 1; Index > LI -> not_found;
read_at(S = #store{ns = Ns, log_fd = Fd, symbol_mode = Mode}, Index, Selection) ->
    quod_trace:with_optional_span(
      quod_trace:context(), <<"quod.ledger.read_at">>, internal,
      #{'quod.namespace' => Ns, 'quod.ledger.slot' => Index},
      fun() ->
          [E] = fold_run(Fd, material_cursor(S, Index), Index, Index,
                         fun(Entry, Acc) -> [Entry | Acc] end, [], {Mode, Selection}),
          {ok, E}
      end).

-doc """
Read entries or opaque transport bytes `From..To` (clamped to the captured tail)
in index order, through one checkpoint seek and sequential streamed cursor.
Both representations check CRC and index; mismatches raise
`{corrupt_entry, Index, Why}`. Opaque bytes still require full decoding and
verification at consumption; they are never entry artifacts or append authority.
""".
-spec read_range(handle(), pos_integer(), log_index(), all | bytes) ->
          {ok, [quod_ledger:entry_artifact()] | [binary()]}.
read_range(S = #store{last_index = LI, log_fd = Fd, symbol_mode = Mode}, From, To0, Form)
  when Form =:= all; Form =:= bytes ->
    case min(To0, LI) of
        To when From > To -> {ok, []};
        To ->
            Representation = case Form of all -> {Mode, all}; bytes -> bytes end,
            {ok, lists:reverse(fold_run(Fd, material_cursor(S, From), From, To,
                                      fun(E, Acc) -> [E | Acc] end, [], Representation))}
    end.

-doc """
Fold `Fun` over the committed entries `From..To` in index order, STREAMING the log
through the chunked cursor — bounded memory no matter the range (the boot committee
re-fold and the KB replay run through here). `To` past the live tail is an ERROR, not a
silent partial fold: a caller that believes more is committed than the store holds must
fail loudly (`{fold_beyond_tail, To, Last}`), never act on a truncated view.
""".
-spec fold(handle(), pos_integer(), log_index(),
           fun((quod_ledger:entry_artifact(), Acc) -> Acc), Acc) -> Acc
              when Acc :: term().
fold(_S, From, To, _Fun, Acc) when From > To -> Acc;
fold(#store{last_index = LI}, _From, To, _Fun, _Acc) when To > LI ->
    error({fold_beyond_tail, To, LI});
fold(S = #store{log_fd = Fd, symbol_mode = SymbolMode}, From, To, Fun, Acc) ->
    fold_run(Fd, material_cursor(S, From), From, To, Fun, Acc, {SymbolMode, all}).

-doc "Fold complete archive groups at recovery; proof bytes remain behind a streamed cursor.".
-spec fold_groups(handle(),
                  fun(([quod_ledger:entry_artifact()], proof_cursor(), Acc) -> Acc), Acc) -> Acc
    when Acc :: term().
fold_groups(S, Fun, Acc) -> fold_groups(S, {0, <<>>}, 1, Fun, Acc).

fold_groups(#store{last_index = Last, base_offset = End}, {End, _}, Next, _Fun, Acc)
  when Next =:= Last + 1 -> Acc;
fold_groups(S = #store{log_fd = Fd, base_offset = Boundary, symbol_mode = Mode},
            Cur, Next, Fun, Acc) ->
    {G, AfterHeader} = group_from_cursor(Fd, Cur),
    true = G#group.first =:= Next andalso G#group.finish =< Boundary,
    Material = {seek_cursor(AfterHeader, G#group.entries_start), G},
    {Entries, {AtFooter, G}} = group_entries(Fd, Material, Next, G#group.count, Mode, []),
    case next_frame(Fd, AtFooter) of
        {frame, <<3, Start:64, End:64>>, {End, _} = AfterFooter}
          when Start =:= G#group.start, End =:= G#group.finish ->
            Acc1 = Fun(Entries, group_proof_cursor(G), Acc),
            fold_groups(S, AfterFooter, Next + G#group.count, Fun, Acc1);
        Other -> error({corrupt_material_group, G#group.start, Other})
    end.

group_entries(_Fd, Cur, _I, 0, _Mode, Acc) -> {lists:reverse(Acc), Cur};
group_entries(Fd, Cur, I, Count, Mode, Acc) ->
    {frame, Bytes, Cur1} = next_material(Fd, Cur),
    case materialize_entry(Bytes, {Mode, all}) of
        {ok, Entry} ->
            case quod_ledger:entry_index(Entry) of
                I -> group_entries(Fd, Cur1, I + 1, Count - 1, Mode, [Entry | Acc]);
                Wrong -> error({corrupt_entry, I, {wrong_index, Wrong}})
            end;
        {error, Why} -> error({corrupt_entry, I, Why})
    end.

fold_run(_Fd, _Cur, I, To, _Fun, Acc, _SymbolMode) when I > To -> Acc;
fold_run(Fd, Cur, I, To, Fun, Acc, SymbolMode) ->
    {frame, Payload, Cur1} = next_material(Fd, Cur),
    case materialize_entry(Payload, SymbolMode) of
        {ok, E} ->
            Index = try quod_ledger:entry_index(E)
                    catch error:Reason -> error({corrupt_entry, I, Reason}) end,
            case Index of
                I -> fold_run(Fd, Cur1, I + 1, To, Fun, Fun(E, Acc), SymbolMode);
                J -> error({corrupt_entry, I, {wrong_index, J}})
            end;
        {error, Why} -> error({corrupt_entry, I, Why})
    end.

materialize_entry(Bytes, bytes) -> {ok, Bytes};
materialize_entry(Bytes, {Mode, all}) -> quod_ledger:decode_entry(Bytes, Mode);
materialize_entry(Bytes, {Mode, Selection}) -> quod_ledger:select_entry(Bytes, Selection, Mode).

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

%% Material seeking skips each proof extent in one step, regardless of its
%% number of carriers. At most 255 material headers follow the checkpoint.
locate(#store{last_index = Last}, I) when I < 1; I > Last ->
    error({entry_out_of_range, I, Last});
locate(#store{log_fd = Fd, cps = Cps}, I) ->
    K = (I - 1) div ?CP_INTERVAL,
    <<_:K/binary-unit:128, Off:64, GroupOff:64, _/binary>> = Cps,
    G = read_group(Fd, GroupOff),
    skip_material(Fd, Off, G, (I - 1) rem ?CP_INTERVAL).

skip_material(_Fd, Off, G, 0) -> {Off, G};
skip_material(Fd, Off, #group{entries_end = Off, finish = NextGroup}, N) ->
    Next = read_group(Fd, NextGroup),
    skip_material(Fd, Next#group.entries_start, Next, N);
skip_material(Fd, Off, G, N) ->
    case file:pread(Fd, Off, ?HDR_BYTES + 1) of
        {ok, <<?MAGIC:32, Len:32, _CRC:32, 2>>}
          when Len > 1, Len =< ?MAX_FRAME_BYTES,
               Off + ?HDR_BYTES + Len =< G#group.entries_end ->
            Next = Off + ?HDR_BYTES + Len,
            case Next =:= G#group.entries_end of
                true when N =:= 1 ->
                    NextG = read_group(Fd, G#group.finish),
                    {NextG#group.entries_start, NextG};
                _ -> skip_material(Fd, Next, G, N - 1)
            end;
        Other -> error({corrupt_log, Off, Other})
    end.

material_cursor(S, I) ->
    {At, G} = locate(S, I),
    {{At, <<>>}, G}.

next_material(Fd, {{At, _} = Cur, G = #group{entries_end = At}}) ->
    case next_frame(Fd, Cur) of
        {frame, <<3, Start:64, End:64>>, {End, _} = AfterFooter}
          when Start =:= G#group.start, End =:= G#group.finish ->
            {Next, AfterHeader} = group_from_cursor(Fd, AfterFooter),
            next_material(Fd, {seek_cursor(AfterHeader, Next#group.entries_start), Next});
        Other -> error({corrupt_material_group, G#group.start, Other})
    end;
next_material(Fd, {Cur, G}) ->
    case next_frame(Fd, Cur) of
        {frame, <<2, Bytes/binary>>, {At, _} = Next} when At =< G#group.entries_end ->
            {frame, Bytes, {Next, G}};
        Other -> error({corrupt_material_group, G#group.start, Other})
    end.

seek_cursor({At, Buf}, Target) when Target >= At ->
    Skip = Target - At,
    case byte_size(Buf) >= Skip of
        true -> <<_:Skip/binary, Rest/binary>> = Buf, {Target, Rest};
        false -> {Target, <<>>}
    end.

read_group(Fd, Off) ->
    %% A point seek needs only this fixed-size header. Do not read a 256KB
    %% sequential slab for each of the up to 255 intervening material groups.
    case file:pread(Fd, Off, group_header_size()) of
        {ok, <<?MAGIC:32, 57:32, _/binary>> = Header}
          when byte_size(Header) =:= ?HDR_BYTES + 57 ->
            {G, _} = group_from_cursor(Fd, {Off, Header}), G;
        Other -> error({corrupt_group_header, Off, Other})
    end.

group_from_cursor(Fd, {Off, _} = Cur) ->
    case next_frame(Fd, Cur) of
        {frame, Header, {After, _} = Next} ->
            case decode_group(Header, Off, After) of
                {ok, G} -> {G, Next};
                error -> error({corrupt_group_header, Off})
            end;
        Other -> error({corrupt_group_header, Off, Other})
    end.

decode_group(<<0, First:64, Count:64, NewProofBytes:64, EntryBytes:64,
               SpanStart:64, SpanBytes:64, Continuation:64>>, Off, After)
  when First > 0, Count > 0, EntryBytes >= Count * (?HDR_BYTES + 2) ->
    Start = After + NewProofBytes,
    End = Start + EntryBytes,
    Fresh = NewProofBytes > 0 andalso SpanStart =:= After
            andalso SpanBytes =:= NewProofBytes,
    Reused = NewProofBytes =:= 0 andalso
             ((SpanStart =:= 0 andalso SpanBytes =:= 0) orelse
              (SpanStart > 0 andalso SpanBytes > 0 andalso SpanStart + SpanBytes =< Off)),
    case (Fresh orelse Reused) andalso
         (Continuation =:= 0 orelse (Continuation < Off andalso SpanBytes > 0)) of
        true -> {ok, #group{start = Off, first = First, count = Count,
                            proof_start = SpanStart, proof_bytes = SpanBytes,
                            entries_start = Start, entries_end = End,
                            finish = End + ?HDR_BYTES + 17, continuation = Continuation}};
        false -> error
    end;
decode_group(_, _, _) -> error.

%%%===================================================================
%%% the frame cursor — every reader walks frames through here
%%%===================================================================

%% A cursor is `{Off, Buf}`: `Buf` holds the file's bytes starting at absolute offset `Off`
%% (possibly none/partial; refilled in ?READ_CHUNK slabs, so sequential consumers cost ~one
%% pread per few hundred frames instead of two per frame). next_frame/2 parses the frame at
%% the cursor: `{frame, Payload, Cursor'}` with `Payload` a zero-copy sub-binary, or
%% `{stop, Why, Off}` — `eof` (clean end exactly at Off) | `short` (torn: bytes exist but
%% not a whole frame) | `{unsupported_format, Version}` | `bad_magic` | `bad_crc` |
%% `{frame_too_big, Len}` | `{io_error, R}`.
%% The framing rules live exactly once, here; the scans and reads only dispatch on `Why`.
next_frame(Fd, {Off, Buf0}) ->
    case fill(Fd, Off, Buf0, ?HDR_BYTES) of
        {short, <<>>} -> {stop, eof, Off};
        %% Four legacy-magic bytes are already an unambiguous older segment,
        %% even when the rest of its header was torn. Never reinterpret that
        %% identifiable incompatible format as a trimmable current append tail.
        {short, <<?V1_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 1}, Off};
        {short, <<?V2_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 2}, Off};
        {short, <<?V3_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 3}, Off};
        {short, <<?V4_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 4}, Off};
        {short, <<?V5_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 5}, Off};
        {short, <<?V6_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 6}, Off};
        {short, <<?V7_MAGIC:32, _/binary>>} ->
            {stop, {unsupported_format, 7}, Off};
        {short, _}    -> {stop, short, Off};
        {io_error, R} -> {stop, {io_error, R}, Off};
        {ok, Buf1} ->
            case Buf1 of
                <<?V1_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 1}, Off};
                <<?V2_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 2}, Off};
                <<?V3_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 3}, Off};
                <<?V4_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 4}, Off};
                <<?V5_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 5}, Off};
                <<?V6_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 6}, Off};
                <<?V7_MAGIC:32, _/binary>> ->
                    {stop, {unsupported_format, 7}, Off};
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

%% Rebuild only at explicit open. A group contributes neither an index row
%% nor readable height until its footer, proof frames and entries all check.
scan(Fd, Mode, SymbolMode, Ns) ->
    quod_trace:with_span(
      quod_trace:context(), <<"quod.ledger.index_scan">>, internal,
      #{'quod.namespace' => Ns, 'quod.ledger.open_mode' => open_mode(Mode)},
      fun(SpanCtx) ->
          {Result = {_Cps, Last, End}, {Framing, Decode, Proofs}} =
              scan_groups(Fd, {0, <<>>}, <<>>, 0, Mode, SymbolMode, {0, 0, 0}),
          _ = quod_trace:set_attributes(SpanCtx,
                #{'quod.ledger.entries' => Last, 'quod.ledger.bytes' => End,
                  'quod.ledger.proof_blocks' => Proofs,
                  'quod.ledger.framing_us' => native_us(Framing),
                  'quod.ledger.decode_us' => native_us(Decode)}),
          Result
      end).

scan_groups(Fd, {Off, _} = StartCur, Cps, Last, Mode, SymbolMode, Stats0) ->
    {Frame, Stats} = scan_frame(Fd, StartCur, Stats0),
    case Frame of
        {stop, eof, Off} -> {{Cps, Last, Off}, Stats};
        {stop, {unsupported_format, Version}, At} ->
            error({unsupported_ledger_format, Version, At});
        {stop, {io_error, R}, At} -> error({log_io_error, At, R});
        {frame, Header, Cur = {After, _}} ->
            case decode_group(Header, Off, After) of
                {ok, G = #group{first = First}} when First =:= Last + 1 ->
                    try scan_group(Fd, Cur, G, Cps, SymbolMode, Stats) of
                        {Cps1, NextCur, NextStats} -> scan_groups(Fd, NextCur, Cps1,
                                            Last + G#group.count, Mode, SymbolMode, NextStats)
                    catch
                        throw:{bad_group, At, Why, FailedStats} ->
                            {recover_group(Fd, Off, At, Cps, Last, Why, Mode), FailedStats}
                    end;
                _ -> {recover_group(Fd, Off, Off, Cps, Last, bad_group_header, Mode), Stats}
            end;
        {stop, Why, At} -> {recover_group(Fd, Off, At, Cps, Last, Why, Mode), Stats}
    end.

scan_group(Fd, Cur, G, Cps, SymbolMode, Stats0) ->
    {AfterProof, Stats1} = scan_proofs(Fd, Cur, G#group.entries_start, Stats0),
    {AfterEntries, Cps1, Stats2} = scan_material(Fd, AfterProof, G, G#group.first,
                                       G#group.first + G#group.count, Cps, SymbolMode, Stats1),
    {Footer, Stats} = scan_frame(Fd, AfterEntries, Stats2),
    case Footer of
        {frame, <<3, Start:64, End:64>>, {End, _} = NextCur}
          when Start =:= G#group.start, End =:= G#group.finish -> {Cps1, NextCur, Stats};
        Other -> group_failure(AfterEntries, Other, Stats)
    end.

scan_proofs(_Fd, {End, _} = Cur, End, Stats) -> {Cur, Stats};
scan_proofs(Fd, Cur, End, Stats0) ->
    {Frame, Stats1} = scan_frame(Fd, Cur, Stats0),
    case Frame of
        {frame, <<1, Bytes/binary>>, {At, _} = Next} when At =< End ->
            {Decoded, Stats} = scan_decode(proof, Bytes, wrapped, Stats1),
            case Decoded of
                {ok, _} -> scan_proofs(Fd, Next, End, Stats);
                {error, Why} -> group_failure(Cur, {bad_proof_block, Why}, Stats)
            end;
        Other -> group_failure(Cur, Other, Stats1)
    end.

scan_material(_Fd, {At, _} = Cur, #group{entries_end = At}, End, End, Cps, _Mode, Stats) ->
    {Cur, Cps, Stats};
scan_material(Fd, {Off, _} = Cur, G, I, End, Cps, Mode, Stats0) when I < End ->
    {Frame, Stats1} = scan_frame(Fd, Cur, Stats0),
    case Frame of
        {frame, <<2, Bytes/binary>>, {At, _} = Next} when At =< G#group.entries_end ->
            {Decoded, Stats} = scan_decode(material, Bytes, Mode, Stats1),
            case Decoded of
                {ok, E} ->
                    case quod_ledger:entry_index(E) of
                        I -> scan_material(Fd, Next, G, I + 1, End,
                                           checkpoint(I, Off, G#group.start, Cps), Mode, Stats);
                        Other -> group_failure(Cur, {wrong_index, I, Other}, Stats)
                    end;
                {error, Why} -> group_failure(Cur, Why, Stats)
            end;
        Other -> group_failure(Cur, Other, Stats1)
    end;
scan_material(_Fd, Cur, _G, _I, _End, _Cps, _Mode, Stats) -> group_failure(Cur, bad_group_extent, Stats).

%% Aggregate counters travel with the startup cursor. No per-frame spans or
%% process-dictionary state: observed decoding cannot change archive authority.
scan_frame(Fd, Cur, {Framing, Decode, Proofs}) ->
    Started = erlang:monotonic_time(),
    Frame = next_frame(Fd, Cur),
    {Frame, {Framing + erlang:monotonic_time() - Started, Decode, Proofs}}.

scan_decode(Kind, Bytes, Mode, {Framing, Decode, Proofs}) ->
    Started = erlang:monotonic_time(),
    {Result, Count} = case Kind of
        proof -> {quod_ledger:decode_block(Bytes, Mode), 1};
        material -> {quod_ledger:decode_entry(Bytes, Mode), 0}
    end,
    {Result, {Framing, Decode + erlang:monotonic_time() - Started, Proofs + Count}}.

-spec group_failure({non_neg_integer(), binary()}, term(),
                    {non_neg_integer(), non_neg_integer(), non_neg_integer()}) -> no_return().
group_failure(_, {stop, {unsupported_format, Version}, Pos}, _Stats) ->
    error({unsupported_ledger_format, Version, Pos});
group_failure(_, {stop, {io_error, R}, At}, _Stats) -> error({log_io_error, At, R});
group_failure({At, _}, Why, Stats) -> throw({bad_group, At, Why, Stats}).

recover_group(Fd, Start, At, Cps, Last, Why, Mode) ->
    {ok, Size} = file:position(Fd, eof),
    case tail_has_completed_group(Fd, Start, Size) of
        true -> error({log_corruption, Why, At});
        false when Mode =:= stop -> {Cps, Last, Start};
        false -> trim(Fd, Start, Cps, Last)
    end.

traced_file_open(Path, Options, Mode, Ns) ->
    quod_trace:with_optional_span(
      quod_trace:context(), <<"quod.ledger.file_open">>, internal,
      #{'quod.namespace' => Ns,
        'quod.ledger.open_mode' => atom_to_binary(Mode)},
      fun() -> file:open(Path, Options) end).

open_mode(trim) -> <<"read_write">>;
open_mode(stop) -> <<"read_only">>.

native_us(Native) ->
    erlang:convert_time_unit(Native, native, microsecond).

trim(Fd, Off, Cps, LastI) ->
    {ok, _} = file:position(Fd, Off),
    ok = file:truncate(Fd),
    ok = file:datasync(Fd),
    {Cps, LastI, Off}.

%% Proof-frame magic is not evidence of a completed append. Search only for a
%% CRC-valid completion footer at its exact physical boundary. This permits
%% truncating complete orphan proof frames, yet refuses to discard a completed
%% group behind corrupted length metadata. Reads are bounded even on damage.
tail_has_completed_group(_Fd, Pos, Size) when Pos >= Size -> false;
tail_has_completed_group(Fd, Pos, Size) ->
    Len = min(?READ_CHUNK, Size - Pos),
    case file:pread(Fd, Pos, Len) of
        {ok, Bytes} when byte_size(Bytes) =:= Len ->
            Found = lists:any(fun({Delta, _}) ->
                tail_marker(Fd, Pos + Delta)
            end, binary:matches(Bytes, [<<?MAGIC:32>>, <<?V7_MAGIC:32>>,
                   <<?V6_MAGIC:32>>, <<?V5_MAGIC:32>>, <<?V4_MAGIC:32>>,
                   <<?V3_MAGIC:32>>, <<?V2_MAGIC:32>>, <<?V1_MAGIC:32>>])),
            case Found orelse Pos + Len >= Size of
                true -> Found;
                false -> tail_has_completed_group(Fd, Pos + Len - 3, Size)
            end;
        Other -> error({log_io_error, Pos, Other})
    end.

tail_marker(Fd, Off) ->
    case file:pread(Fd, Off, 4) of
        {ok, <<Magic:32>>} when Magic >= ?V1_MAGIC, Magic =< ?V7_MAGIC ->
            error({unsupported_ledger_format, Magic - ?V1_MAGIC + 1, Off});
        {ok, <<?MAGIC:32>>} -> footer_at(Fd, Off);
        Other -> error({log_io_error, Off, Other})
    end.

footer_at(Fd, Off) ->
    case file:pread(Fd, Off, ?HDR_BYTES + 17) of
        {ok, <<?MAGIC:32, 17:32, CRC:32, 3, Start:64, End:64>>}
          when Start < Off, End =:= Off + ?HDR_BYTES + 17 ->
            CRC =:= erlang:crc32(<<3, Start:64, End:64>>);
        {error, R} -> error({log_io_error, Off, R});
        _ -> false
    end.

assert_contiguous(LastI, Entries) ->
    Want = lists:seq(LastI + 1, LastI + length(Entries)),
    Got  = [(quod_ledger:entry_view(E))#entry.index || E <- Entries],
    case Got of
        Want -> ok;
        _    -> error({non_contiguous_append, LastI, Got})
    end.
