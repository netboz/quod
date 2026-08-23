-module(quod_ontology).
-moduledoc """
Runtime creation of a local, self-founded ontology and joining of an existing
ontology through its pinned genesis anchor.

Root-owned creation and node-owned join deliberately reuse the normal namespace
manager, namespace supervision tree, genesis builder, and node storage
placement. A governed
Prolog action is recorded as an ordinary transaction in its controlling
ontology with a typed direct effect, but it adds no catalogue fact. The namespace manager records the
node-local hosting intent beside the ledgers after the exact genesis anchor is
known, so a full application restart resumes only ontologies this node had
deliberately created or joined. Explicit local stop removes that intent.
Joining uses that same lifecycle asynchronously: acceptance starts the existing
catch-up process, and `local_state/1` reports its local progress.

The low-level preparation and execution functions are trusted same-VM
internals; they do not authenticate a remote caller. Public lifecycle requests
are ordinary Prolog goals. Their ontology's normal `can_invoke/4` check and
declared `action/3` prerequisites govern the request before the ordinary
transaction path commits the typed descriptor and the effect journal calls
these internals. `create/2` and `join/3` exist only in TEST as fixture
conveniences around that preparation and execution code.
""".

-include("quod_ingress_limits.hrl").
-include("quod_proof_limits.hrl").
-include("quod_ledger.hrl").

-export([validate_action/1, prepare_action/2, canonical_name/1,
         execute_prepared/1,
         prepared_effect/4, prepared_bytes/1, decode_prepared/1,
         prepare_system_join/3,
         local_state/1, genesis_anchor/1,
         network_identity/0, network_identity/2,
         root_ns/0]).
-ifdef(TEST).
-export([create/2, join/3, prepare_action/1, network_identity/1]).
-endif.
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

-ifdef(TEST).
-type input_option() ::
        {source_file, file:filename()} |
        {source, unicode:chardata()} |
        {terms, [term()]}.
-endif.

-record(lifecycle_request, {
    kind :: create | join,
    namespace :: binary() | undefined,
    payload :: term()
}).

-record(prepared_lifecycle, {
    kind :: create | join,
    namespace :: binary(),
    anchor :: <<_:256>>,
    config :: map(),
    status :: created | joining | resumed
}).

-opaque structural_descriptor() :: #lifecycle_request{}.
-opaque prepared_descriptor() :: #prepared_lifecycle{}.

-ifdef(TEST).
-spec create(term(), [input_option()]) -> creation().
create(Name, Options) ->
    execute_action({create_ontology, Name, Options}).

-spec join(term(), unicode:chardata(), [term()]) -> joining().
join(Name, GenesisHash, Seeds) ->
    execute_action({join_ontology, Name, GenesisHash, Seeds}).
-endif.

-doc """
Validate a typed lifecycle action without reading source paths, compiling
Prolog, inspecting storage, or changing hosting state.
""".
valid_action_shape({create_ontology, _, _}) -> true;
valid_action_shape({join_ontology, _, _, _}) -> true;
valid_action_shape(_) -> false.

-spec validate_action(term()) ->
          {ok, structural_descriptor()} | {error, term()}.
validate_action(Action) ->
    case valid_action_shape(Action) of
        true -> validate_typed_action(Action);
        false -> {error, invalid_action}
    end.

validate_typed_action(Action) ->
    case quod_wire_term:is_ground(Action) of
        true -> validate_ground_action(Action);
        false -> {error, invalid_arguments}
    end.

validate_ground_action({create_ontology, Name, Options}) ->
    case canonical_name(Name) of
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
    case canonical_name(Name) of
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
state. The ordinary action continuation calls this only after its declared
prerequisites. TEST fixture helpers may call it directly, but production
hosting requests enter through the governed predicate. Create sources are
read, parsed, and compiled exactly once into the descriptor; join inputs are
already normalized.
""".
-ifdef(TEST).
-spec prepare_action(structural_descriptor()) ->
          {ok, prepared_descriptor()} | {error, term()}.
prepare_action(Structural) -> prepare_action(Structural, none).
-endif.

-spec prepare_action(structural_descriptor(), term()) ->
          {ok, prepared_descriptor()} | {error, term()}.
prepare_action(
  #lifecycle_request{kind = create, namespace = Ns, payload = Options},
  _Principal) ->
    case split_create_options(Options) of
        {error, _} = Error ->
            Error;
        {ok, SourceOptions, Modules} ->
            case quod_predicates:module_manifest(Modules) of
                {error, _} -> {error, invalid_options};
                {ok, _Manifest} ->
                    case load_options(SourceOptions) of
                        {error, _} = Error ->
                            Error;
                        {ok, InitialTerms} ->
                            case validate_initial_terms(InitialTerms) of
                                {error, _} = Error ->
                                    Error;
                                {ok, InitialDiff} ->
                                    case initial_diff_size(InitialDiff) of
                                        ok ->
                                            prepare_create(
                                              Ns, InitialDiff, Modules);
                                        {error, _} = Error -> Error
                                    end
                            end
                    end
            end
    end;
prepare_action(
  #lifecycle_request{kind = join, namespace = Ns,
                     payload = {RawGenesisHash, SeedPeers}}, _Principal)
  when is_binary(RawGenesisHash), byte_size(RawGenesisHash) =:= 32,
       is_list(SeedPeers) ->
    prepare_join(Ns, RawGenesisHash, SeedPeers);
prepare_action(_InvalidDescriptor, _Principal) ->
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

-ifdef(TEST).
execute_action(Action) ->
    case validate_action(Action) of
        {error, _} = Error ->
            Error;
        {ok, Structural} ->
            case prepare_action(Structural, none) of
                {error, _} = Error -> Error;
                {ok, Prepared} -> execute_prepared(Prepared)
            end
    end.
-endif.

-spec local_state(term()) -> {ok, local_state()} | {error, term()}.
local_state(Name) ->
    case canonical_name(Name) of
        {error, _} = Error -> Error;
        {ok, Ns} -> {ok, local_state_validated(Ns)}
    end.

-doc """
The root namespace name — the identity anchor every network is founded on.

Exported so callers stop re-declaring the literal while resolving the network
identity and system-ontology catalogue.
""".
-spec root_ns() -> binary().
root_ns() -> ?ROOT_NS.

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

-doc "Return the exact root anchor that separates this Quod network.".
-spec network_identity() -> {ok, <<_:256>>} | {error, term()}.
network_identity() ->
    genesis_anchor(root_ns()).

-ifdef(TEST).
-doc "Return the network identity only when a validated record requires it.".
-spec network_identity(boolean()) ->
          {ok, none | <<_:256>>} | {error, term()}.
network_identity(true) -> network_identity();
network_identity(false) -> {ok, none}.
-endif.

-doc "Return the network identity from the validation target when it is the root.".
-spec network_identity(boolean(), {binary(), <<_:256>>}) ->
          {ok, none | <<_:256>>} | {error, term()}.
network_identity(false, {_Ns, <<_:256>>}) ->
    {ok, none};
network_identity(true, {?ROOT_NS, <<_:256>> = RootAnchor}) ->
    %% The root anchor is the network identity. Deriving it from the record
    %% avoids a circular lookup while the root itself is being replayed.
    {ok, RootAnchor};
network_identity(true, {_Ns, <<_:256>>}) ->
    network_identity().

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
normalize_option_shapes(
  [{external_predicate_modules, Modules} | Rest], AccRev) ->
    case quod_predicates:valid_module_names(Modules) of
        true ->
            normalize_option_shapes(
              Rest, [{external_predicate_modules, Modules} | AccRev]);
        false -> {error, invalid_options}
    end;
normalize_option_shapes(_ImproperOrInvalid, _AccRev) ->
    {error, invalid_options}.

split_create_options(Options) ->
    split_create_options(Options, [], undefined).

split_create_options([], SourceRev, undefined) ->
    {ok, lists:reverse(SourceRev), []};
split_create_options([], SourceRev, Modules) ->
    {ok, lists:reverse(SourceRev), Modules};
split_create_options(
  [{external_predicate_modules, Modules} | Rest], SourceRev, undefined) ->
    split_create_options(Rest, SourceRev, Modules);
split_create_options(
  [{external_predicate_modules, _Modules} | _Rest], _SourceRev, _Existing) ->
    {error, invalid_options};
split_create_options([Option | Rest], SourceRev, Modules) ->
    split_create_options(Rest, [Option | SourceRev], Modules).

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
    end.

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

prepare_create(Ns, InitialDiff, Modules) ->
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
                           genesis_diff => InitialDiff,
                           external_predicate_modules => Modules}),
            case existing_ledger(Ns, Config) of
                {error, _} = Error ->
                    Error;
                {resumed, ExistingAnchor} ->
                    prepare_create_existing(
                      Ns, ExistingAnchor,
                      Config#{genesis_hash => ExistingAnchor}, resumed);
                created ->
                    NodeId = maps:get(node_id, Config),
                    case quod_simplex:prepare_genesis(Config, Ns, NodeId) of
                        {error, _} = Error ->
                            Error;
                        {ok, Entry, Anchor} ->
                            FrozenConfig =
                                Config#{prepared_genesis_entry => Entry,
                                        genesis_hash => Anchor},
                            prepare_create_existing(
                              Ns, Anchor, FrozenConfig, created)
                    end
            end
    end.

prepare_create_existing(Ns, Anchor, Config, Status) ->
                    %% An author need not supply a `can_invoke/4` clause:
                    %% founding injects the bodyless host-entry default, so the
                    %% ontology can always answer its own host and is never born
                    %% locked out. Author clauses layer restrictions on remote
                    %% and cross-ontology callers.
                    {ok,
                     #prepared_lifecycle{
                        kind = create, namespace = Ns, anchor = Anchor,
                        config = Config, status = Status}}.

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
                        kind = join, namespace = Ns,
                        anchor = RawGenesisHash, config = Config,
                        status = joining}};
                {resumed, RawGenesisHash} ->
                    {ok,
                     #prepared_lifecycle{
                        kind = join, namespace = Ns,
                        anchor = RawGenesisHash, config = Config,
                        status = resumed}};
                {resumed, _DifferentAnchor} ->
                    {error, genesis_mismatch}
            end
    end.

-doc """
Prepare the normal pinned join configuration for a root-catalogued system
ontology.  Registration never creates an ontology: callers must supply its
already-known exact genesis anchor and certified route hints (or resume its
existing local ledger).
""".
-spec prepare_system_join(binary(), <<_:256>>, [term()]) ->
          {ok, map()} | {error, term()}.
prepare_system_join(Ns, Anchor, SeedPeers)
  when is_binary(Ns), is_list(SeedPeers) ->
    case prepare_join(Ns, Anchor, SeedPeers) of
        {ok, #prepared_lifecycle{status = resumed, config = Config}} ->
            {ok, Config#{system_ontology => true}};
        {ok, #prepared_lifecycle{status = joining, config = Config}}
          when SeedPeers =/= [] ->
            {ok, Config#{system_ontology => true}};
        {ok, #prepared_lifecycle{status = joining}} ->
            {error, unavailable};
        {error, _} = Error -> Error
    end.

-doc "Build the closed public descriptor for one exact private preparation.".
-spec prepared_effect(term(), prepared_descriptor(), <<_:256>>,
                      {node, <<_:256>>} | {user, <<_:256>>}) ->
          {ok, quod_effect:effect()} | {error, term()}.
prepared_effect(Action,
                #prepared_lifecycle{kind = Kind, namespace = Ns,
                                    anchor = Anchor} = Prepared,
                <<_:256>> = Executor, Actor) ->
    case {quod_durable_term:encode_goal(Action), prepared_bytes(Prepared)} of
        {{ok, ActionBytes}, {ok, PreparedBytes}} ->
            Effect =
                {quod_direct_effect, 1, local_durable, ontology_lifecycle,
                 Kind, crypto:strong_rand_bytes(32), Executor, Actor,
                 {Ns, Anchor}, crypto:hash(sha256, ActionBytes),
                 crypto:hash(sha256, PreparedBytes)},
            case quod_effect:validate(Effect) of
                true -> {ok, Effect};
                false -> {error, invalid_direct_effect}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end;
prepared_effect(_Action, _Prepared, _Executor, _Actor) ->
    {error, invalid_direct_effect}.

-doc "Canonical bounded bytes retained only in the local prepared-action journal.".
-spec prepared_bytes(prepared_descriptor()) -> {ok, binary()} | {error, term()}.
prepared_bytes(#prepared_lifecycle{} = Prepared) ->
    Bytes = term_to_binary({quod_prepared_lifecycle, 1, Prepared},
                           [deterministic]),
    case byte_size(Bytes) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES of
        true -> {ok, Bytes};
        false -> {error, initial_content_too_large}
    end;
prepared_bytes(_) -> {error, invalid_action}.

-doc "Decode and validate one exact journal-owned private preparation.".
-spec decode_prepared(binary()) ->
          {ok, prepared_descriptor()} | {error, invalid_action}.
decode_prepared(Bytes)
  when is_binary(Bytes), byte_size(Bytes) =< ?QUOD_MAX_PREPARED_EFFECT_BYTES ->
    %% These bytes were created locally before hand-off and are accepted by
    %% the journal only when their SHA-256 digest matches the certified public
    %% effect descriptor. They may legitimately contain atoms introduced by
    %% the prepared genesis which do not exist yet after a full VM restart.
    try binary_to_term(Bytes) of
        {quod_prepared_lifecycle, 1, #prepared_lifecycle{} = Prepared} ->
            case prepared_bytes(Prepared) of
                {ok, Bytes} -> {ok, Prepared};
                _ -> {error, invalid_action}
            end;
        _ -> {error, invalid_action}
    catch _:_ -> {error, invalid_action}
    end;
decode_prepared(_) -> {error, invalid_action}.

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
reserved_clause_head({external_predicate_modules, _}) -> true;
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
            Result = case Last of
                         0 -> created;
                         _ -> existing_ledger_anchor(Store)
                     end,
            ok = quod_ledger_store:close(Store),
            Result;
        {error, no_log} ->
            created;
        {error, Reason} ->
            {error, {ledger_read_failed, Reason}}
    end.

existing_ledger_anchor(Store) ->
    case quod_ledger_store:read_at(Store, 1) of
        {ok, #entry{} = Entry} ->
            case quod_simplex:block_from_entry(Entry) of
                {ok, Block} -> {resumed, quod_simplex:block_hash(Block)};
                error -> {error, {ledger_read_failed, invalid_genesis}}
            end;
        _ ->
            {error, {ledger_read_failed, missing_genesis}}
    end.
