-module(quod_system_ontology).
-moduledoc """
Process-free root system-ontology catalogue reader and join materializer.

Root commits only exact ontology identities. Predicate modules belong to and
are hash-pinned by each ontology's immutable genesis; live endpoints remain
directory hints. This module never creates an
ontology, owns desired state, or bypasses the normal pinned join path;
`m:quod_namespace_manager` is the sole caller which reconciles the returned
configs.
""".

-export([catalog/0, materialize/2]).
-ifdef(TEST).
-export([materialize/1, validate_rows/1]).
-endif.

-define(ROOT_NS, <<"quod:root">>).

-type descriptor() ::
        #{namespace := binary(), anchor := <<_:256>>}.
-type rejected_row() ::
        #{reason := malformed_system_ontology} |
        #{reason := conflicting_system_ontology,
          namespace := binary(), anchors := [<<_:256>>]}.
-export_type([descriptor/0]).

-spec catalog() ->
          {ok, non_neg_integer(), [descriptor()], #{term() => rejected_row()}} |
          {error, term()}.
catalog() ->
    Namespace = {'SystemNamespace'},
    Anchor = {'SystemAnchor'},
    Row = {system_ontology, Namespace, Anchor},
    Rows = {'SystemOntologies'},
    validate_catalog_proof(
      quod_prolog:prove_ro(?ROOT_NS, {findall, Row, Row, Rows})).

validate_catalog_proof({ok, [Bindings], Height})
  when is_map(Bindings), is_integer(Height), Height >= 0 ->
    case maps:find('SystemOntologies', Bindings) of
        {ok, Rows} ->
            case validate_rows(Rows) of
                {ok, Descriptors, Rejected} ->
                    {ok, Height, Descriptors, Rejected};
                {error, _} = Error -> Error
            end;
        error -> {error, malformed_system_catalogue}
    end;
validate_catalog_proof({error, Reason}) -> {error, Reason};
validate_catalog_proof(fail) -> {error, root_not_ready};
validate_catalog_proof({fail, _}) -> {error, root_not_ready};
validate_catalog_proof(_) -> {error, malformed_system_catalogue}.

-spec validate_rows(term()) ->
          {ok, [descriptor()], #{term() => rejected_row()}} | {error, term()}.
validate_rows(Rows) when is_list(Rows) ->
    validate_rows(Rows, #{}, #{}, #{});
validate_rows(_) ->
    {error, malformed_system_catalogue}.

validate_rows([], Valid, Conflicts, Invalid) ->
    Descriptors =
        [#{namespace => Ns, anchor => Anchor}
         || {Ns, Anchor} <- lists:sort(maps:to_list(Valid))],
    Rejected = maps:fold(
                 fun(Ns, Anchors, Acc) ->
                     Acc#{Ns =>
                              #{reason => conflicting_system_ontology,
                                namespace => Ns,
                                anchors => lists:sort(maps:keys(Anchors))}}
                 end, Invalid, Conflicts),
    {ok, Descriptors, Rejected};
validate_rows([Row | Rest], Valid, Conflicts, Invalid) ->
    case validate_row(Row) of
        {ok, #{namespace := Ns, anchor := Anchor}} ->
            {Valid1, Conflicts1} =
                merge_identity(Ns, Anchor, Valid, Conflicts),
            validate_rows(Rest, Valid1, Conflicts1, Invalid);
        {error, malformed_system_ontology} ->
            Id = {malformed, crypto:hash(
                               sha256, term_to_binary(Row, [deterministic]))},
            validate_rows(
              Rest, Valid, Conflicts,
              Invalid#{Id => #{reason => malformed_system_ontology}})
    end.

merge_identity(Ns, Anchor, Valid, Conflicts) ->
    case maps:get(Ns, Conflicts, undefined) of
        Anchors when is_map(Anchors) ->
            {Valid, Conflicts#{Ns => Anchors#{Anchor => true}}};
        undefined ->
            case maps:get(Ns, Valid, undefined) of
                undefined -> {Valid#{Ns => Anchor}, Conflicts};
                Anchor -> {Valid, Conflicts};
                OtherAnchor ->
                    {maps:remove(Ns, Valid),
                     Conflicts#{Ns => #{OtherAnchor => true,
                                        Anchor => true}}}
            end
    end.

validate_row(
  {system_ontology, Name, <<_:256>> = Anchor}) ->
    case system_namespace(Name) of
        {ok, Ns} -> {ok, #{namespace => Ns, anchor => Anchor}};
        error -> {error, malformed_system_ontology}
    end;
validate_row(_) ->
    {error, malformed_system_ontology}.

system_namespace(Name) ->
    case quod_ontology_name:flatten(Name) of
        <<"quod:", _/binary>> = Ns when Ns =/= ?ROOT_NS ->
            case quod_ontology:canonical_name(Ns) of
                {ok, Ns} -> {ok, Ns};
                {error, _} -> error
            end;
        _ -> error
    end.

-ifdef(TEST).
-spec materialize([descriptor()]) ->
          {ok, #{binary() => map()}, [binary()], #{binary() => term()}} |
          {error, term()}.
materialize(Descriptors) when is_list(Descriptors) ->
    materialize(Descriptors, #{});
materialize(_) ->
    {error, malformed_system_catalogue}.
-endif.

-spec materialize([descriptor()], #{binary() => map()}) ->
          {ok, #{binary() => map()}, [binary()], #{binary() => term()}} |
          {error, term()}.
materialize(Descriptors, Existing)
  when is_list(Descriptors), is_map(Existing) ->
    materialize(Descriptors, Existing, #{}, [], #{});
materialize(_, _) ->
    {error, malformed_system_catalogue}.

materialize([], _Existing, Configs, Pending, Blocked) ->
    {ok, Configs, lists:reverse(Pending), Blocked};
materialize([#{namespace := Ns} = Descriptor | Rest],
            Existing, Configs, Pending, Blocked) ->
    case existing_config(Descriptor, Existing) of
        {ok, Config} ->
            materialize(
              Rest, Existing, Configs#{Ns => Config}, Pending, Blocked);
        none ->
            materialize_new(
              Descriptor, Rest, Existing, Configs, Pending, Blocked)
    end.

materialize_new(#{namespace := Ns} = Descriptor, Rest, Existing,
                Configs, Pending, Blocked) ->
    case materialize_one(Descriptor) of
        {ok, Config} ->
            materialize(
              Rest, Existing, Configs#{Ns => Config}, Pending, Blocked);
        {error, unavailable} ->
            materialize(Rest, Existing, Configs, [Ns | Pending], Blocked);
        {error, Reason} ->
            case retryable(Reason) of
                true ->
                    materialize(
                      Rest, Existing, Configs, [Ns | Pending], Blocked);
                false ->
                    materialize(
                      Rest, Existing, Configs, Pending,
                      Blocked#{Ns => Reason})
            end
    end.

existing_config(#{namespace := Ns, anchor := Anchor}, Existing) ->
    case maps:get(Ns, Existing, undefined) of
        #{genesis_hash := Anchor, system_ontology := true} = Config ->
            {ok, Config};
        _ -> none
    end.

retryable(anchor_conflict) -> true;
retryable(root_unavailable) -> true;
retryable({ledger_read_failed, _}) -> true;
retryable(_) -> false.

materialize_one(#{namespace := Ns, anchor := Anchor}) ->
    case quod_ontology:prepare_system_join(Ns, Anchor, []) of
        {ok, _} = Local -> Local;
        {error, unavailable} ->
            materialize_remote(Ns, Anchor);
        {error, _} = Error -> Error
    end.

materialize_remote(Ns, Anchor) ->
    case route_hints(Ns, Anchor) of
        {ok, Seeds} ->
            quod_ontology:prepare_system_join(Ns, Anchor, Seeds);
        {error, _} = Error -> Error
    end.

route_hints(Ns, Anchor) ->
    case quod_directory:validator_routes(Ns, Anchor) of
        {ok, Routes} when Routes =/= [] ->
            {ok, lists:usort(
                   [Endpoint || #{endpoint := Endpoint} <- Routes])};
        {ok, []} -> {error, unavailable};
        {error, unavailable} -> {error, unavailable};
        {error, Reason} -> {error, Reason}
    end.
