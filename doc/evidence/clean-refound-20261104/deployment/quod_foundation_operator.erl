-module(quod_foundation_operator).
-export([found/4, publish/3, enrolled_node/0, node_ref/0, root_admin/0,
         signed_user_registration/2, submit_saved/2, catalogue/0]).

-define(ROOT, <<"quod:root">>).

found(Ns, Files, Terms, Modules) when is_binary(Ns), is_list(Files),
                                      is_list(Terms), is_list(Modules) ->
    {ok, not_hosted} = quod_ontology:local_state(Ns),
    true = quod_reg:subscribe({runtime, Ns}),
    try
        Sources = [source_file(File) || File <- Files],
        Goal = {create_ontology, Ns,
                Sources ++ [{terms, Terms}, {external_predicate_modules, Modules}], {'Anchor'}},
        {ok, [#{'Anchor' := Anchor}], _} = quod_prolog:execute(?ROOT, Goal),
        ok = await_ready(Ns),
        Anchor = quod_simplex:genesis_hash(Ns),
        {ok, Expected} = quod_predicates:module_manifest(Modules),
        {ok, [#{'Profile' := Expected}], _} =
            quod_prolog:prove_ro(Ns, {external_predicate_modules, {'Profile'}}),
        #{namespace => Ns, anchor => binary:encode_hex(Anchor),
          sources => maps:from_list(
              [{list_to_binary(F), binary:encode_hex(source_hash(F))} || F <- Files])}
    after quod_reg:unsubscribe({runtime, Ns}) end.

publish(Ns, Anchor, Creation) when is_binary(Ns), byte_size(Anchor) =:= 32,
                                   is_boolean(Creation) ->
    {ok, ready} = quod_ontology:local_state(Ns),
    Anchor = quod_simplex:genesis_hash(Ns),
    [] = rows(?ROOT, system_ontology, Ns),
    Facts = [{assertz, {system_ontology, Ns, Anchor}}] ++
        case Creation of true -> [{assertz, {ontology_creation_policy, Ns, Anchor}}];
                         false -> [] end,
    {ok, [_], _} = quod_prolog:execute(?ROOT, {transaction, conj(Facts)}),
    [Anchor] = rows(?ROOT, system_ontology, Ns),
    case Creation of true -> [Anchor] = rows(?ROOT, ontology_creation_policy, Ns);
                     false -> ok end,
    #{namespace => Ns, published => true, anchor => binary:encode_hex(Anchor)}.

enrolled_node() ->
    true = quod_reg:subscribe({node_actor, node}),
    try
        ok = quod_namespace_manager:enroll_node(),
        Ref = await_node(),
        #{reference => iolist_to_binary(io_lib:format("~0p", [Ref])),
          manager => iolist_to_binary(io_lib:format("~0p", [quod_namespace_manager:stats()]))}
    after quod_reg:unsubscribe({node_actor, node}) end.

node_ref() ->
    {ok, Ref} = quod_node_actor:reference(), Ref.

root_admin() ->
    Ref = node_ref(),
    {fail, _} = quod_prolog:prove_ro(?ROOT, {root_administrator_agent, Ref}),
    {ok, [_], _} = quod_prolog:execute(?ROOT,
        {transaction, {assertz, {root_administrator_agent, Ref}}}),
    {ok, [_], _} = quod_prolog:prove_ro(?ROOT, {root_administrator_agent, Ref}),
    #{root_administrator => true}.

signed_user_registration(Anchor, Operation) when byte_size(Anchor) =:= 32,
                                                  byte_size(Operation) =:= 32 ->
    Ns = <<"quod:user">>,
    {ok, ready} = quod_ontology:local_state(Ns),
    Anchor = quod_simplex:genesis_hash(Ns),
    Node = node_ref(),
    {agent_instance_ref, NodeNs, _, _} = Node,
    [] = rows(?ROOT, system_ontology, Ns),
    [] = rows(?ROOT, ontology_creation_policy, Ns),
    [] = rows(NodeNs, ontology_hosting_policy, Ns),
    Goal = {transaction, conj([
        {'::', ?ROOT, {transaction, conj([
            {assertz, {system_ontology, Ns, Anchor}},
            {assertz, {ontology_creation_policy, Ns, Anchor}}])}},
        {assertz, {ontology_hosting_policy, Ns, Anchor}}])},
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(
        execute, Goal, Operation, quod_time:now_ms() + 30000),
    #{request => base64:encode(Bytes), signature => base64:encode(Signature),
      operation => binary:encode_hex(Operation)}.

submit_saved(Bytes64, Signature64) ->
    Bytes = base64:decode(Bytes64), Signature = base64:decode(Signature64),
    Result = quod_client_goal_ingress:submit(Bytes, Signature),
    Status = case Result of
        {ok, _, {normalized, {committed, _, _}}} -> committed;
        _ -> not_committed
    end,
    #{status => Status, result => iolist_to_binary(io_lib:format("~0p", [Result]))}.

catalogue() ->
    Expected = lists:sort([<<"quod:node">>, <<"quod:agent">>, <<"quod:gui">>,
                           <<"quod:controllers">>, <<"quod:space">>, <<"quod:user">>]),
    {ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
    #{} = Rejected,
    Expected = lists:sort([Ns || #{namespace := Ns} <- Descriptors]),
    [] = [{Ns, State} || #{namespace := Ns} <- Descriptors,
                         {ok, State} <- [quod_ontology:local_state(Ns)], State =/= ready],
    Node = node_ref(),
    #{height => Height, names => Expected, anchors =>
        maps:from_list([{Ns, binary:encode_hex(Anchor)} || #{namespace := Ns, anchor := Anchor} <- Descriptors]),
      node => iolist_to_binary(io_lib:format("~0p", [Node]))}.

source_file(File) ->
    Path = filename:join([code:priv_dir(quod), "ontologies", File]),
    {source_file, list_to_binary(Path), source_hash(File)}.

source_hash(File) ->
    Path = filename:join([code:priv_dir(quod), "ontologies", File]),
    {ok, Bytes} = file:read_file(Path), crypto:hash(sha256, Bytes).

rows(Ontology, Predicate, Key) ->
    {ok, [#{'Rows' := Result}], _} = quod_prolog:prove_ro(Ontology,
        {findall, {'Value'}, {Predicate, Key, {'Value'}}, {'Rows'}}),
    Result.

conj([Goal]) -> Goal;
conj([Goal | More]) -> {',', Goal, conj(More)}.

await_ready(Ns) ->
    case quod_ontology:local_state(Ns) of
        {ok, ready} -> ok;
        _ -> receive _ -> await_ready(Ns) end
    end.

await_node() ->
    case quod_node_actor:reference() of
        {ok, Ref} -> Ref;
        _ -> receive _ -> await_node() end
    end.
