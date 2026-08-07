-module(quod_ontology).
-moduledoc """
Runtime creation of a local, self-founded ontology and joining of an existing
ontology through its pinned genesis anchor.

Creation deliberately reuses the normal namespace manager, namespace
supervision tree, genesis builder, and root storage placement. It adds no
catalogue or durable hosting manifest: a full application restart forgets the
runtime hosting intent, and calling `create/2` again resumes the existing
ledger.
Joining uses that same lifecycle asynchronously: acceptance starts the existing
catch-up process, and `local_state/1` reports its local progress.

These functions are trusted same-VM APIs; they do not authenticate a remote
caller. Node-local Prolog lifecycle requests must enter through
`quod_prolog:run_action/2`, which proves root policy before calling them.
""".

-include("quod_ingress_limits.hrl").

-export([create/2, join/3,
         validate_action/1, prepare_action/1, execute_prepared/1,
         local_state/1, genesis_anchor/1]).
-export_type([structural_descriptor/0, prepared_descriptor/0]).

-define(ROOT_NS, <<"quod:root">>).
-define(MAX_NAMESPACE_BYTES, 128).
-define(MAX_ERROR_TERM_BYTES, 4096).

-type creation() ::
        {ok, created | resumed, binary(), binary()} |
        {error, term()}.

-type joining() ::
        {ok, joining | resumed, binary(), binary()} |
        {error, term()}.

-type local_state() :: not_hosted | starting | joining | ready | stopping.

-type input_option() ::
        {source_file, file:filename()} |
        {source, unicode:chardata()} |
        {terms, [term()]}.

-record(lifecycle_request, {
    kind :: create | join,
    namespace :: binary(),
    payload :: term()
}).

-record(prepared_lifecycle, {
    namespace :: binary(),
    config :: map(),
    status :: created | joining | resumed
}).

-opaque structural_descriptor() :: #lifecycle_request{}.
-opaque prepared_descriptor() :: #prepared_lifecycle{}.

-spec create(term(), [input_option()]) -> creation().
create(Name, Options) ->
    execute_action({create_ontology, Name, Options}).

-spec join(term(), unicode:chardata(), [term()]) -> joining().
join(Name, GenesisHash, Seeds) ->
    execute_action({join_ontology, Name, GenesisHash, Seeds}).

-doc """
Validate a typed lifecycle action without reading source paths, compiling
Prolog, inspecting storage, or changing hosting state.
""".
-spec validate_action(term()) ->
          {ok, structural_descriptor()} | {error, term()}.
validate_action(Action) ->
    case Action of
        {create_ontology, _, _} -> validate_typed_action(Action);
        {join_ontology, _, _, _} -> validate_typed_action(Action);
        _ -> {error, invalid_action}
    end.

validate_typed_action(Action) ->
    case quod_predicates:is_ground(Action) of
        true -> validate_ground_action(Action);
        false -> {error, invalid_arguments}
    end.

validate_ground_action({create_ontology, Name, Options}) ->
    case normalize_user_name(Name) of
        {error, _} = Error ->
            Error;
        {ok, Ns} ->
            case normalize_option_shapes(Options) of
                {ok, NormalizedOptions} ->
                    {ok,
                     #lifecycle_request{
                        kind = create,
                        namespace = Ns, payload = NormalizedOptions}};
                {error, _} = Error ->
                    Error
            end
    end;
validate_ground_action(
  {join_ontology, Name, GenesisHash, Seeds}) ->
    case normalize_user_name(Name) of
        {error, _} = Error ->
            Error;
        {ok, Ns} ->
            case normalize_genesis_hash(GenesisHash) of
                {error, _} = Error ->
                    Error;
                {ok, _GenesisHex, RawGenesisHash} ->
                    case normalize_seeds(Seeds) of
                        {error, _} = Error ->
                            Error;
                        {ok, SeedPeers} ->
                            {ok,
                             #lifecycle_request{
                                kind = join,
                                namespace = Ns,
                                payload = {RawGenesisHash, SeedPeers}}}
                    end
            end
    end.

-doc """
Finish a structurally validated lifecycle request without mutating hosting
state. The lifecycle runner calls this only after authorization; the trusted
same-VM API calls it directly. Create sources are read, parsed, and compiled
exactly once into the descriptor; join inputs are already normalized.
""".
-spec prepare_action(structural_descriptor()) ->
          {ok, prepared_descriptor()} | {error, term()}.
prepare_action(
  #lifecycle_request{kind = create, namespace = Ns, payload = Options}) ->
    case load_options(Options) of
        {error, _} = Error ->
            Error;
        {ok, InitialTerms} ->
            case validate_initial_terms(InitialTerms) of
                {error, _} = Error ->
                    Error;
                {ok, InitialDiff} ->
                    case initial_diff_size(InitialDiff) of
                        ok -> prepare_create(Ns, InitialDiff);
                        {error, _} = Error -> Error
                    end
            end
    end;
prepare_action(
  #lifecycle_request{kind = join, namespace = Ns,
                     payload = {RawGenesisHash, SeedPeers}})
  when is_binary(RawGenesisHash), byte_size(RawGenesisHash) =:= 32,
       is_list(SeedPeers) ->
    prepare_join(Ns, RawGenesisHash, SeedPeers);
prepare_action(_InvalidDescriptor) ->
    {error, invalid_action}.

-doc """
Perform only the namespace-manager mutation described by a prepared lifecycle
descriptor. It never re-reads or recompiles caller-controlled input.
""".
-spec execute_prepared(prepared_descriptor()) -> creation() | joining().
execute_prepared(
  #prepared_lifecycle{namespace = Ns, config = Config, status = Status}) ->
    start(Ns, Config, Status);
execute_prepared(_InvalidDescriptor) ->
    {error, invalid_action}.

execute_action(Action) ->
    case validate_action(Action) of
        {error, _} = Error ->
            Error;
        {ok, Structural} ->
            case prepare_action(Structural) of
                {error, _} = Error -> Error;
                {ok, Prepared} -> execute_prepared(Prepared)
            end
    end.

-spec local_state(term()) -> {ok, local_state()} | {error, term()}.
local_state(Name) ->
    case canonical_name(Name) of
        {error, _} = Error -> Error;
        {ok, Ns} -> {ok, local_state_validated(Ns)}
    end.

-doc """
Return the exact local 32-byte genesis anchor. A live Simplex anchor wins; while
the namespace is starting, a pinned join anchor is read from the manager's
serialized desired configuration.
""".
-spec genesis_anchor(term()) -> {ok, binary()} | {error, term()}.
genesis_anchor(Name) ->
    case canonical_name(Name) of
        {error, _} = Error ->
            Error;
        {ok, Ns} ->
            case quod_simplex:genesis_hash(Ns) of
                Hash when is_binary(Hash), byte_size(Hash) =:= 32 ->
                    {ok, Hash};
                _ ->
                    desired_genesis_anchor(Ns)
            end
    end.

desired_genesis_anchor(Ns) ->
    Desired = application:get_env(quod, namespace_desired, #{}),
    Content =
        case Desired of
            #{content := Value} when is_map(Value) -> Value;
            _ -> #{}
        end,
    case maps:get(Ns, Content, undefined) of
        undefined ->
            {error, not_hosted};
        Config when is_map(Config) ->
            case maps:get(genesis_hash, Config, undefined) of
                Hash when is_binary(Hash), byte_size(Hash) =:= 32 ->
                    {ok, Hash};
                _ ->
                    {error, genesis_unavailable}
            end;
        _ ->
            {error, genesis_unavailable}
    end.

normalize_option_shapes(Options) ->
    normalize_option_shapes(Options, []).

normalize_option_shapes([], AccRev) ->
    {ok, lists:reverse(AccRev)};
normalize_option_shapes([{terms, Terms} | Rest], AccRev) ->
    case proper_list(Terms) of
        true ->
            normalize_option_shapes(Rest, [{terms, Terms} | AccRev]);
        false ->
            {error, invalid_options}
    end;
normalize_option_shapes([{source, Text} | Rest], AccRev) ->
    case source_chars(Text) of
        {ok, Chars} ->
            normalize_option_shapes(Rest, [{source, Chars} | AccRev]);
        error ->
            {error, invalid_options}
    end;
normalize_option_shapes([{source_file, Path0} | Rest], AccRev) ->
    case source_path(Path0) of
        {ok, Path} ->
            normalize_option_shapes(
              Rest, [{source_file, Path} | AccRev]);
        error ->
            {error, invalid_options}
    end;
normalize_option_shapes(_ImproperOrInvalid, _AccRev) ->
    {error, invalid_options}.

load_options(Options) ->
    load_options(Options, 1, []).

load_options([], _Index, AccRev) ->
    {ok, lists:reverse(AccRev)};
load_options([Option | Rest], Index, AccRev) ->
    case load_option(Option, Index) of
        {ok, Terms} ->
            load_options(Rest, Index + 1, lists:reverse(Terms, AccRev));
        {error, _} = Error ->
            Error
    end;
load_options(_ImproperOrNonList, _Index, _AccRev) ->
    {error, invalid_options}.

load_option({terms, Terms}, _Index) ->
    {ok, Terms};
load_option({source, Chars}, Index) when is_list(Chars) ->
    read_source(Chars, Index);
load_option({source_file, Path}, Index) when is_binary(Path) ->
    read_source_file(Path, Index);
load_option(_Unknown, _Index) ->
    {error, invalid_options}.

proper_list([]) -> true;
proper_list([_ | Rest]) -> proper_list(Rest);
proper_list(_) -> false.

source_chars(Text) ->
    try unicode:characters_to_list(Text) of
        Chars when is_list(Chars) -> {ok, Chars};
        _ -> error
    catch _:_ -> error
    end.

source_path(Path) ->
    try unicode:characters_to_binary(Path) of
        <<>> -> error;
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
    catch _:_ -> error
    end.

read_source(Chars, Index) ->
    Result =
        try erlog_io:read_string_terms(Chars)
        catch CatchClass:CatchReason -> {caught, CatchClass, CatchReason}
        end,
    case Result of
        {ok, Terms} when is_list(Terms) ->
            {ok, Terms};
        {error, {Line, Module, Detail}} when is_integer(Line) ->
            {error, {source_error, Index, Line, {Module, Detail}}};
        {error, ErrorReason} ->
            {error, {source_error, Index, 0, ErrorReason}};
        {caught, ErrorClass, ErrorReason} ->
            {error, {source_error, Index, 0, {ErrorClass, ErrorReason}}}
    end.

read_source_file(Path, Index) ->
    Result =
        try erlog_io:read_file(Path)
        catch CatchClass:CatchReason -> {caught, CatchClass, CatchReason}
        end,
    case Result of
        {ok, Terms} ->
            case proper_list(Terms) of
                true -> {ok, Terms};
                false -> source_file_error(Index, Path, invalid_terms)
            end;
        {error, {Line, Module, Detail}} when is_integer(Line) ->
            {error, {source_error, Index, Line, {Module, Detail}}};
        {error, ErrorReason} ->
            source_file_error(Index, Path, ErrorReason);
        {error, einval, ErrorReason} ->
            source_file_error(Index, Path, {error, einval, ErrorReason});
        {exit, einval, ErrorReason} ->
            source_file_error(Index, Path, {exit, einval, ErrorReason});
        {caught, ErrorClass, ErrorReason} ->
            source_file_error(Index, Path, {ErrorClass, ErrorReason});
        Other ->
            source_file_error(Index, Path, {unexpected, Other})
    end.

source_file_error(Index, Path, Reason) ->
    {error, {source_file_error, Index, Path, Reason}}.

prepare_create(Ns, InitialDiff) ->
    case root_storage() of
        {error, _} = Error ->
            Error;
        {ok, Storage} ->
            {_Ns, BaseConfig} =
                quod_app:build_ns_config(
                  #{namespace => Ns, mode => create,
                    genesis_file => <<>>}),
            Config =
                maps:merge(
                  BaseConfig,
                  Storage#{committee => [],
                           genesis_diff => InitialDiff}),
            case existing_ledger(Ns, Config) of
                {error, _} = Error ->
                    Error;
                Status ->
                    %% An author need not supply a `can_invoke/4` clause:
                    %% founding injects the bodyless host-entry default, so the
                    %% ontology can always answer its own host and is never born
                    %% locked out. Author clauses layer restrictions on remote
                    %% and cross-ontology callers.
                    {ok,
                     #prepared_lifecycle{
                        namespace = Ns, config = Config,
                        status = Status}}
            end
    end.

prepare_join(Ns, RawGenesisHash, SeedPeers) ->
    case root_storage() of
        {error, _} = Error ->
            Error;
        {ok, Storage} ->
            {_Ns, BaseConfig0} =
                quod_app:build_ns_config(
                  #{namespace => Ns, mode => join,
                    genesis_file => <<>>,
                    genesis_hash => binary:encode_hex(RawGenesisHash),
                    seeds => []}),
            %% Validation above makes build_ns_config's malformed-hex fallback
            %% unreachable; retain the already-decoded anchor explicitly.
            BaseConfig = BaseConfig0#{genesis_hash => RawGenesisHash},
            Config = maps:merge(
                       BaseConfig,
                       Storage#{seed_peers => SeedPeers}),
            case existing_ledger(Ns, Config) of
                {error, _} = Error -> Error;
                created ->
                    {ok,
                     #prepared_lifecycle{
                        namespace = Ns, config = Config,
                        status = joining}};
                resumed ->
                    {ok,
                     #prepared_lifecycle{
                        namespace = Ns, config = Config,
                        status = resumed}}
            end
    end.

start(Ns, Config, Status) ->
    Result =
        try quod_namespace_manager:start_new_content(Ns, Config)
        catch exit:_ -> {error, outcome_unknown}
        end,
    case Result of
        {ok, Hash} when is_binary(Hash), byte_size(Hash) =:= 32 ->
            {ok, Status, Ns, Hash};
        {error, {already_configured, Ns}} = Error ->
            Error;
        {error, outcome_unknown} = Error ->
            Error;
        {error, genesis_mismatch} = Error ->
            Error;
        {error, genesis_unavailable} = Error ->
            Error;
        {error, Reason} ->
            {error, {start_failed, Reason}}
    end.

canonical_name(Name) ->
    case try quod_ontology_name:flatten(Name)
         catch _:_ -> error
         end of
        Ns when is_binary(Ns) ->
            validate_name(Ns);
        error ->
            {error, invalid_name}
    end.

validate_name(<<>>) ->
    {error, invalid_name};
validate_name(Ns) when byte_size(Ns) > ?MAX_NAMESPACE_BYTES ->
    {error, invalid_name};
validate_name(Ns) ->
    try unicode:characters_to_binary(Ns, utf8, utf8) of
        Ns -> {ok, Ns};
        _ -> {error, invalid_name}
    catch _:_ ->
        {error, invalid_name}
    end.

-doc "Canonicalize a non-system ontology name without touching hosting state or storage.".
-spec normalize_user_name(term()) -> {ok, binary()} | {error, term()}.
normalize_user_name(Name) ->
    case canonical_name(Name) of
        {ok, <<"quod">>} -> {error, reserved_system_namespace};
        {ok, <<"quod:", _/binary>>} ->
            {error, reserved_system_namespace};
        Other -> Other
    end.

normalize_genesis_hash(Value) ->
    try unicode:characters_to_binary(Value) of
        Hex when is_binary(Hex), byte_size(Hex) =:= 64 ->
            try binary:decode_hex(Hex) of
                Raw when byte_size(Raw) =:= 32 -> {ok, Hex, Raw}
            catch _:_ -> {error, invalid_genesis_hash}
            end;
        _ ->
            {error, invalid_genesis_hash}
    catch _:_ ->
        {error, invalid_genesis_hash}
    end.

normalize_seeds(Seeds) ->
    normalize_seeds(Seeds, 0, #{}, []).

normalize_seeds([], 0, _Seen, _AccRev) ->
    {error, invalid_seeds};
normalize_seeds([], _Count, _Seen, AccRev) ->
    {ok, lists:reverse(AccRev)};
normalize_seeds([_ | _], 32, _Seen, _AccRev) ->
    {error, invalid_seeds};
normalize_seeds([{seed, Host0, Port} | Rest], Count, Seen, AccRev)
  when is_integer(Port), Port >= 1, Port =< 65535 ->
    case normalize_host(Host0) of
        {ok, Host} ->
            Endpoint = {Host, Port},
            case maps:is_key(Endpoint, Seen) of
                true -> {error, invalid_seeds};
                false ->
                    normalize_seeds(
                      Rest, Count + 1, Seen#{Endpoint => true},
                      [Endpoint | AccRev])
            end;
        error ->
            {error, invalid_seeds}
    end;
normalize_seeds(_Invalid, _Count, _Seen, _AccRev) ->
    {error, invalid_seeds}.

normalize_host(Host0) ->
    try unicode:characters_to_list(Host0) of
        Host when is_list(Host), Host =/= [] -> {ok, Host};
        _ -> error
    catch _:_ -> error
    end.

local_state_validated(Ns) ->
    Desired = application:get_env(quod, namespace_desired, #{}),
    Content = maps:get(content, Desired, #{}),
    Wanted = maps:is_key(Ns, Content),
    NamespacePid = quod_reg:where({quod_ns, Ns}),
    SimplexPid = quod_reg:where({quod_simplex, Ns}),
    case {Wanted, is_pid(NamespacePid), is_pid(SimplexPid)} of
        {false, false, false} -> not_hosted;
        {false, _, _} -> stopping;
        {true, false, false} -> starting;
        {true, _, false} -> starting;
        {true, _, true} ->
            case quod_simplex:status(Ns) of
                #{syncing := false} -> ready;
                _ -> joining
            end
    end.

validate_initial_terms(Terms) when is_list(Terms) ->
    case first_reserved_term(Terms) of
        none ->
            compile_initial_terms(Terms);
        Term ->
            invalid_initial_term(Term)
    end.

first_reserved_term([]) ->
    none;
first_reserved_term([Term | Rest]) ->
    case reserved_clause_head(clause_head(Term)) of
        true -> Term;
        false -> first_reserved_term(Rest)
    end.

clause_head({':-', Head, _Body}) -> Head;
clause_head(Fact) -> Fact.

reserved_clause_head({consensus_incarnation, _}) -> true;
reserved_clause_head({peer_admitted, _, _, _, _}) -> true;
reserved_clause_head(_) -> false.

compile_initial_terms(Terms) ->
    try quod_prolog:terms_to_diff(Terms) of
        Diff -> {ok, Diff}
    catch
        throw:{genesis_failed, {assert, Term, _InterpreterState}} ->
            invalid_initial_term(Term);
        _Class:_Reason ->
            {error, invalid_initial_terms}
    end.

initial_diff_size(Diff) ->
    try byte_size(term_to_binary(Diff, [deterministic])) of
        Bytes when Bytes =< ?MAX_GENESIS_INITIAL_DIFF_BYTES -> ok;
        _ -> {error, initial_content_too_large}
    catch
        _:_ -> {error, invalid_initial_terms}
    end.

invalid_initial_term(Term) ->
    case safe_error_term(Term) of
        true -> {error, {invalid_initial_term, Term}};
        false -> {error, invalid_initial_terms}
    end.

safe_error_term(Term) ->
    try erlang:external_size(Term) =< ?MAX_ERROR_TERM_BYTES
            andalso portable_term(Term)
    catch _:_ -> false
    end.

portable_term(T) when is_atom(T); is_number(T); is_binary(T) -> true;
portable_term([]) -> true;
portable_term([H | T]) -> portable_term(H) andalso portable_term(T);
portable_term(T) when is_tuple(T) ->
    lists:all(fun portable_term/1, tuple_to_list(T));
portable_term(_) -> false.

root_storage() ->
    Desired = application:get_env(quod, namespace_desired, #{}),
    case Desired of
        #{content := Content} when is_map(Content) ->
            case maps:get(?ROOT_NS, Content, undefined) of
                RootConfig when is_map(RootConfig) ->
                    {ok, maps:with([data_dir, ledger_dir], RootConfig)};
                _ ->
                    {error, root_unavailable}
            end;
        _ ->
            {error, root_unavailable}
    end.

existing_ledger(Ns, Config) ->
    LedgerDir = quod_ledger_store:ledger_dir(Config),
    case quod_ledger_store:open_ro(Ns, LedgerDir) of
        {ok, Store} ->
            Last = quod_ledger_store:last(Store),
            ok = quod_ledger_store:close(Store),
            case Last of
                0 -> created;
                _ -> resumed
            end;
        {error, no_log} ->
            created;
        {error, Reason} ->
            {error, {ledger_read_failed, Reason}}
    end.
