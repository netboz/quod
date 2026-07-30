-module(quod_ontology).
-moduledoc """
Runtime creation of a local, self-founded ontology.

Creation deliberately reuses the normal namespace manager, namespace
supervision tree, genesis builder, and root storage placement. It adds no
catalogue or durable hosting manifest: a full application restart forgets the
runtime hosting intent, and calling `create/2` again resumes the existing
ledger.
""".

-export([create/2]).

-define(ROOT_NS, <<"quod:root">>).
-define(MAX_NAMESPACE_BYTES, 128).
-define(MAX_ERROR_TERM_BYTES, 4096).

-type creation() ::
        {ok, created | resumed, binary(), binary()} |
        {error, term()}.

-spec create(term(), [term()]) -> creation().
create(Name, InitialTerms) ->
    case canonical_name(Name) of
        {error, _} = Error ->
            Error;
        {ok, Ns} ->
            case validate_initial_terms(InitialTerms) of
                ok -> create_validated(Ns, InitialTerms);
                {error, _} = Error -> Error
            end
    end.

create_validated(Ns, InitialTerms) ->
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
                           genesis_terms => InitialTerms}),
            case existing_ledger(Ns, Config) of
                {error, _} = Error ->
                    Error;
                Status ->
                    start(Ns, Config, Status)
            end
    end.

start(Ns, Config, Status) ->
    Result =
        try quod_namespace_manager:start_new_content(Ns, Config)
        catch exit:_ -> {error, manager_unavailable}
        end,
    case Result of
        {ok, Pid} when is_pid(Pid) ->
            creation_started(Ns, Config, Status);
        {ok, Pid, _Info} when is_pid(Pid) ->
            creation_started(Ns, Config, Status);
        {error, {already_configured, Ns}} = Error ->
            Error;
        {error, Reason} ->
            {error, {start_failed, Reason}}
    end.

creation_started(Ns, Config, Status) ->
    case quod_simplex:genesis_hash(Ns) of
        Hash when is_binary(Hash), byte_size(Hash) =:= 32 ->
            ok = quod_app:publish_data_dir(Ns, Config),
            {ok, Status, Ns, Hash};
        _ ->
            {error, genesis_unavailable}
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
validate_name(<<"quod">>) ->
    {error, reserved_system_namespace};
validate_name(<<"quod:", _/binary>>) ->
    {error, reserved_system_namespace};
validate_name(Ns) ->
    try unicode:characters_to_binary(Ns, utf8, utf8) of
        Ns -> {ok, Ns};
        _ -> {error, invalid_name}
    catch _:_ ->
        {error, invalid_name}
    end.

validate_initial_terms(Terms) when is_list(Terms) ->
    case first_reserved_term(Terms) of
        none ->
            compile_initial_terms(Terms);
        improper ->
            {error, invalid_initial_terms};
        Term ->
            invalid_initial_term(Term)
    end;
validate_initial_terms(_Terms) ->
    {error, invalid_initial_terms}.

first_reserved_term([]) ->
    none;
first_reserved_term([Term | Rest]) ->
    case reserved_clause_head(clause_head(Term)) of
        true -> Term;
        false -> first_reserved_term(Rest)
    end;
first_reserved_term(_ImproperTail) ->
    improper.

clause_head({':-', Head, _Body}) -> Head;
clause_head(Fact) -> Fact.

reserved_clause_head({consensus_incarnation, _}) -> true;
reserved_clause_head({peer_admitted, _, _, _, _}) -> true;
reserved_clause_head(_) -> false.

compile_initial_terms(Terms) ->
    try quod_prolog:terms_to_diff(Terms) of
        _Diff -> ok
    catch
        throw:{genesis_failed, {assert, Term, _InterpreterState}} ->
            invalid_initial_term(Term);
        _Class:_Reason ->
            {error, invalid_initial_terms}
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
