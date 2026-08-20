-module(quod_namespace_desired_store).
-moduledoc """
Durable node-local hosting intent for dynamically created or joined ontologies.

`m:quod_namespace_manager` remains the sole desired-state owner. This module is
only its atomic disk representation; it is not a network catalogue, ledger, or
authorization source. Static configuration is kept separately and overrides a
same-name dynamic row at boot.
""".

-export([load/0, store/1, resume_config/2]).

-include_lib("kernel/include/file.hrl").

-define(MAGIC, 16#514E4431). %% "QND1"
-define(HEADER_BYTES, 40).
-define(MAX_BYTES, 64 * 1024 * 1024).

-spec load() -> #{binary() => map()}.
load() ->
    case path() of
        none -> #{};
        Path -> load_path(Path)
    end.

-spec store(#{binary() => map()}) -> ok.
store(Content) when is_map(Content) ->
    case path() of
        none -> ok;
        Path -> store_path(Path, Content)
    end.

-spec resume_config(map(), <<_:256>>) -> map().
resume_config(Config, <<_:256>> = Anchor) when is_map(Config) ->
    (maps:without([prepared_genesis_entry, genesis_diff], Config))
        #{genesis_hash => Anchor}.

path() ->
    case application:get_env(quod, namespace_desired_path) of
        {ok, Path} when is_list(Path), Path =/= [] -> Path;
        _ -> none
    end.

store_path(Path, Content) ->
    ok = validate_content(Content),
    Payload = term_to_binary(
                {quod_namespace_desired, 1,
                 lists:sort(maps:to_list(Content))},
                [deterministic]),
    true = byte_size(Payload) =< ?MAX_BYTES,
    Digest = crypto:hash(sha256, Payload),
    Bytes = <<?MAGIC:32/unsigned-big, (byte_size(Payload)):32/unsigned-big,
              Digest/binary, Payload/binary>>,
    ok = filelib:ensure_dir(Path),
    Tmp = Path ++ ".tmp",
    _ = file:delete(Tmp),
    {ok, Fd} = file:open(Tmp, [write, raw, binary, exclusive]),
    try
        ok = file:write(Fd, Bytes),
        ok = file:datasync(Fd)
    after
        ok = file:close(Fd)
    end,
    ok = file:rename(Tmp, Path),
    sync_dir(filename:dirname(Path)).

load_path(Path) ->
    case file:read_file_info(Path) of
        {error, enoent} -> #{};
        {ok, #file_info{size = Size}} when Size =< ?MAX_BYTES + ?HEADER_BYTES ->
            decode_file(Path);
        {ok, _} -> error(namespace_desired_too_large);
        {error, Reason} -> error({namespace_desired_io, Reason})
    end.

decode_file(Path) ->
    case file:read_file(Path) of
        {ok, <<?MAGIC:32/unsigned-big, Size:32/unsigned-big,
               Digest:32/binary, Payload:Size/binary>>}
          when Size =< ?MAX_BYTES ->
            Digest = crypto:hash(sha256, Payload),
            decode_payload(binary_to_term(Payload, [safe]));
        {ok, _} -> error(namespace_desired_corrupt);
        {error, Reason} -> error({namespace_desired_io, Reason})
    end.

decode_payload({quod_namespace_desired, 1, Entries}) when is_list(Entries) ->
    Content = maps:from_list(Entries),
    case map_size(Content) =:= length(Entries) of
        true -> ok = validate_content(Content), Content;
        false -> error(namespace_desired_corrupt)
    end;
decode_payload(_) ->
    error(namespace_desired_corrupt).

validate_content(Content) ->
    case lists:all(fun valid_entry/1, maps:to_list(Content)) of
        true -> ok;
        false -> error(namespace_desired_corrupt)
    end.

valid_entry({Ns, Config}) when is_binary(Ns), byte_size(Ns) > 0,
                                is_map(Config) ->
    lists:member(maps:get(mode, Config, undefined), [create, join]) andalso
        case maps:get(genesis_hash, Config, undefined) of
            <<_:256>> -> true;
            _ -> false
        end;
valid_entry(_) -> false.

sync_dir(Dir) ->
    case file:open(Dir, [read, raw]) of
        {ok, Fd} ->
            try file:sync(Fd)
            after _ = file:close(Fd)
            end;
        {error, eisdir} -> ok;
        {error, enotsup} -> ok;
        {error, Reason} -> error({namespace_desired_dir_sync, Reason})
    end.
