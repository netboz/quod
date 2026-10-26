-module(quod_fleet_probe).
-export([run/1]).

run(Anchors) ->
    Deadline = quod_time:mono_ms() + 300000,
    lists:foreach(fun({Ns, Anchor}) ->
        true = quod_reg:subscribe({runtime, Ns}),
        try ready(Ns, Deadline)
        after quod_reg:unsubscribe({runtime, Ns}) end,
        Anchor = quod_simplex:genesis_hash(Ns)
    end, lists:sort(maps:to_list(Anchors))),
    true = quod_reg:subscribe({node_actor, node}),
    Principal = try principal(Deadline)
                after quod_reg:unsubscribe({node_actor, node}) end,
    {agent, Blob} = Principal,
    {ok, #{identity := {ActorNs, ActorAnchor}, reference := Ref}} = quod_agent_ref:decode(Blob),
    {ok, Dir} = application:get_env(quod, identity_dir),
    {ok, Blob} = quod_identity:load_node_actor_pointer(Dir),
    {ok, Ref} = quod_agent_ref:materialize_principal(Principal),
    {ok, [_], _} = quod_prolog:prove_ro(ActorNs,
        {hosts_ontology, Ref, ActorNs, ActorAnchor, discoverable}),
    {ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
    0 = map_size(Rejected),
    System = maps:remove(<<"quod:root">>, Anchors),
    System = maps:from_list([{Ns,A} || #{namespace := Ns,anchor := A} <- Descriptors]),
    Profiles = maps:from_list([begin
        Expected = case Ns of <<"quod:gui">> -> [quod_agent_predicates,quod_gui_predicates];
                              _ -> [quod_agent_predicates] end,
        {ok,[#{'Manifest' := Manifest}],_} = quod_prolog:prove_ro(Ns,{external_predicate_modules,{'Manifest'}}),
        Expected = [M || {M,<<_:256>>} <- Manifest],
        {Ns,Expected}
    end || #{namespace := Ns} <- Descriptors]),
    RootStats = quod_simplex:stats(<<"quod:root">>),
    {Count, Bytes} = quod_effect_journal:limits(),
    {ok,[#{'Count' := Count,'Bytes' := Bytes}],_} = quod_prolog:prove_ro(
        <<"quod:root">>, {effect_custody_limits,{'Count'},{'Bytes'}}),
    #{node_enrollment := complete} = Manager = quod_namespace_manager:stats(),
    {ok, #{provider := none}} = application:get_env(quod, agent_vault),
    true = is_pid(quod_reg:where({agent_vault,node})),
    #{version => list_to_binary(element(2,application:get_key(quod,vsn))),
      anchors => maps:map(fun(_,A) -> binary:encode_hex(A) end, Anchors),
      catalogue_count => length(Descriptors), catalogue_height => Height,
      all_ready => true, rejected_count => 0, module_profiles => Profiles,
      root_committee_size => length(quod_simplex:committee(<<"quod:root">>)),
      root_committed => maps:get(committed,RootStats),
      root_applied => maps:get(last_applied,RootStats),
      custody_limits => #{count => Count, prepared_bytes => Bytes},
      manager => Manager, vault_ready => true, vault_provider => none,
      principal => #{namespace => ActorNs, anchor => binary:encode_hex(ActorAnchor),
                     pointer => stored, self_hosting => committed}}.

ready(Ns, Deadline) ->
    case quod_ontology:local_state(Ns) of
        {ok,ready} -> ok;
        State -> receive _ -> ready(Ns,Deadline)
                 after max(0,Deadline-quod_time:mono_ms()) -> error({runtime_timeout,Ns,State}) end
    end.

principal(Deadline) ->
    case quod_node_actor:principal() of
        {ok,P} -> P;
        _ -> receive _ -> principal(Deadline)
             after max(0,Deadline-quod_time:mono_ms()) -> error(node_principal_timeout) end
    end.
