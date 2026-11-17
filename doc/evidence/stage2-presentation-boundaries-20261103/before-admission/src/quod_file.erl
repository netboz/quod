-module(quod_file).
-moduledoc """
Shared atomic file publication and directory durability.

This module owns no process or inventory. Existing custody and journal owners
serialize their writes. Errors propagate before a caller can claim persistence;
a rename or hard link alone does not make its directory entry durable.
""".
-export([write_atomic/3, ensure_parent/1, sync_dir/1]).

-doc """
Write `Bytes` to `Path` durably, privately and atomically (tmp + exclusive
create + `chmod Mode` before the bytes land + rename + dirent fsync).

The owning caller serializes writes to each path. Key custody and durable
journals share this file-publication boundary.
""".
-spec write_atomic(file:filename_all(), iodata(), non_neg_integer()) ->
          ok | {error, term()}.
write_atomic(Path, Bytes, Mode) ->
    case ensure_parent(Path) of
        ok ->
            Tmp = unicode:characters_to_list([Path, ".tmp"]),
            _ = file:delete(Tmp),                      %% clear any stale/leftover tmp
            try write_tmp(Tmp, Path, Bytes, Mode)
            catch throw:{error, _} = Err -> _ = file:delete(Tmp), Err end;
        {error, _} = Error ->
            Error
    end.

write_tmp(Tmp, Path, Bytes, Mode) ->
    case file:open(Tmp, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            try
                ok_(file:change_mode(Tmp, Mode)),      %% lock down BEFORE bytes land
                ok_(file:write(Fd, Bytes)),
                ok_(file:sync(Fd))
            after
                _ = file:close(Fd)
            end,
            ok_(file:rename(Tmp, Path)),
            ok_(sync_dir(filename:dirname(Path))),     %% durable dirent (POSIX rename)
            ok;
        {error, _} = E ->
            E
    end.


ok_(ok)               -> ok;
ok_({error, _} = E)   -> throw(E).

-doc "Create parent directories and persist their entries, including interrupted creation.".
-spec ensure_parent(file:filename_all()) -> ok | {error, term()}.
ensure_parent(Path) ->
    case filelib:ensure_dir(Path) of
        ok -> sync_ancestors(filename:dirname(Path));
        {error, _} = Error -> Error
    end.

%% Existing directories may be the result of an interrupted earlier creation.
%% Synchronize the chain as well as the leaf before claiming durable storage.
sync_ancestors(Dir) ->
    case sync_dir(Dir) of
        ok ->
            case filename:dirname(Dir) of
                Dir -> ok;
                Parent -> sync_ancestors(Parent)
            end;
        {error, _} = Error -> Error
    end.

-doc "Synchronize a private-file directory after rename, link or unlink; propagate failures.".
-spec sync_dir(file:filename_all()) -> ok | {error, term()}.
sync_dir(Dir) ->
    %% OTP's raw backend requires the directory flag; ordinary file:open
    %% refuses directories with eisdir before an fsync can occur.
    case prim_file:open(Dir, [read, directory]) of
        {ok, DirFd} ->
            try prim_file:sync(DirFd)
            after _ = prim_file:close(DirFd) end;
        {error, _} = Error -> Error
    end.
