-module(quod_refound_operator).
-moduledoc """
One-shot founding steps for a fresh network, loaded into the founder node and
called through `quod eval`. It follows the founding sequence of
`quod_lifecycle_single_path_tests:m1a_foundations/1` and
`doc/godot-foundation-contract.md`: every ontology is created by root's
`create_ontology/3`, checked ready with its module profile, then listed in
root; the user class is listed by the node actor's own signed transaction,
together with the node's hosting delegation. Pins are read from root's
committed catalogue, never typed in. Each step refuses to run twice.
""".
-export([root/0, node/0, agent/0, gui/0, gui_resume/0, controllers/0, names/0, space/0,
         user/0, signed_user_registration/1, submit_saved/2, catalogue/0, gui_assets/0]).

-define(ROOT, <<"quod:root">>).
-define(SYSTEM, [<<"quod:node">>, <<"quod:agent">>, <<"quod:gui">>, <<"quod:controllers">>,
                 <<"quod:names">>, <<"quod:space">>, <<"quod:user">>]).
-define(GUI_FILES, ["quod_gui.pl", "gui_measure.pl", "gui_scene.pl", "gui_tools.pl"]).

root() ->
    {ok, Network} = quod_ontology:network_identity(),
    [] = rows(?ROOT, system_ontology, '_'),
    #{root_anchor => hex(quod_simplex:genesis_hash(?ROOT)), network => hex(Network)}.

node() ->
    {ok, Template} = file:read_file(path("node_instance.pl")),
    Found = found(<<"quod:node">>, ["quod_node.pl"], [{node_identity_template, Template}],
                  [quod_agent_predicates]),
    publish(<<"quod:node">>, true),
    true = quod_reg:subscribe({node_actor, node}),
    Ref = try
        ok = quod_namespace_manager:enroll_node(),
        await_node()
    after quod_reg:unsubscribe({node_actor, node}) end,
    {agent_instance_ref, _, _, me} = Ref,
    %% Enrollment finishes writing its hosting facts after the reference is
    %% bound; the catalogue step checks them.
    Found#{node => text(Ref), enrollment => text(maps:get(node_enrollment, quod_namespace_manager:stats()))}.

agent() -> found_published(<<"quod:agent">>, ["quod_agent.pl"], [], [quod_agent_predicates]).

gui() -> found_published(<<"quod:gui">>, ?GUI_FILES, [], [quod_agent_predicates, quod_gui_predicates]).

%% The founder was stopped (OOM) after root committed quod:gui's creation and
%% before the checks and the listing: run those, never a second creation.
gui_resume() ->
    Ns = <<"quod:gui">>, Modules = [quod_agent_predicates, quod_gui_predicates],
    [] = rows(?ROOT, system_ontology, Ns),
    true = quod_reg:subscribe({runtime, Ns}),
    try ok = await_ready(Ns) after quod_reg:unsubscribe({runtime, Ns}) end,
    {ok, Expected} = quod_predicates:module_manifest(Modules),
    {ok, [#{'Profile' := Expected}], _} = quod_prolog:prove_ro(Ns, {external_predicate_modules, {'Profile'}}),
    publish(Ns, false),
    #{namespace => Ns, anchor => hex(quod_simplex:genesis_hash(Ns)),
      sources => maps:from_list([{list_to_binary(F), hex(source_hash(F))} || F <- ?GUI_FILES])}.

controllers() ->
    found_published(<<"quod:controllers">>, ["quod_controllers.pl"],
                    [{gui_vocabulary, <<"quod:gui">>, pin(<<"quod:gui">>)}], [quod_agent_predicates]).

%% The space class draws its default names here.
names() -> found_published(<<"quod:names">>, ["quod_names.pl"], [], []).

space() -> found_published(<<"quod:space">>, ["quod_space.pl"], gui_pins(), [quod_agent_predicates]).

%% Found the user class and make the node actor root's administrator. Its
%% listing is the separate signed step below.
user() ->
    Node = node_ref(),
    Pins = gui_pins() ++ [{agent_vocabulary, <<"quod:agent">>, pin(<<"quod:agent">>)},
        {controllers_vocabulary, <<"quod:controllers">>, pin(<<"quod:controllers">>)},
        {space_vocabulary, <<"quod:space">>, pin(<<"quod:space">>)}],
    Found = found(<<"quod:user">>, ["quod_user.pl"], Pins ++ [{signup_host, Node}], [quod_agent_predicates]),
    fail = quod_prolog:prove_ro(?ROOT, {root_administrator_agent, Node}),
    {ok, [_], _} = quod_prolog:execute(?ROOT, {transaction, {assertz, {root_administrator_agent, Node}}}),
    {ok, [_], _} = quod_prolog:prove_ro(?ROOT, {root_administrator_agent, Node}),
    Found#{root_administrator => true}.

%% The node actor's own transaction lists the user class in root and writes
%% the node's hosting delegation for it, atomically. Returned unsent: the
%% exact bytes are kept before the single submission.
signed_user_registration(Operation) when byte_size(Operation) =:= 32 ->
    Ns = <<"quod:user">>,
    {ok, ready} = quod_ontology:local_state(Ns),
    Anchor = quod_simplex:genesis_hash(Ns),
    {agent_instance_ref, NodeNs, _, _} = node_ref(),
    [] = rows(?ROOT, system_ontology, Ns),
    [] = rows(?ROOT, ontology_creation_policy, Ns),
    [] = rows(NodeNs, ontology_hosting_policy, Ns),
    Goal = {transaction, conj([
        {'::', ?ROOT, {transaction, conj([
            {assertz, {system_ontology, Ns, Anchor}},
            {assertz, {ontology_creation_policy, Ns, Anchor}}])}},
        {assertz, {ontology_hosting_policy, Ns, Anchor}}])},
    {ok, Bytes, Signature} = quod_node_actor:signed_goal(execute, Goal, Operation, quod_time:now_ms() + 30000),
    #{request => base64:encode(Bytes), signature => base64:encode(Signature), operation => hex(Operation)}.

submit_saved(Bytes64, Signature64) ->
    Result = quod_client_goal_ingress:submit(base64:decode(Bytes64), base64:decode(Signature64)),
    Status = case Result of
        {ok, _, {normalized, {committed, _, _}}} -> committed;
        _ -> not_committed
    end,
    #{status => Status, result => text(Result)}.

catalogue() ->
    {ok, Height, Descriptors, Rejected} = quod_system_ontology:catalog(),
    #{} = Rejected, 0 = map_size(Rejected),
    Expected = lists:sort(?SYSTEM),
    Expected = lists:sort([Ns || #{namespace := Ns} <- Descriptors]),
    [] = [{Ns, State} || #{namespace := Ns} <- Descriptors,
                         {ok, State} <- [quod_ontology:local_state(Ns)], State =/= ready],
    Node = node_ref(),
    {agent_instance_ref, NodeNs, NodeAnchor, me} = Node,
    complete = maps:get(node_enrollment, quod_namespace_manager:stats()),
    {ok, [_], _} = quod_prolog:prove_ro(NodeNs, {hosts_ontology, Node, NodeNs, NodeAnchor, discoverable}),
    [UserAnchor] = rows(NodeNs, ontology_hosting_policy, <<"quod:user">>),
    UserAnchor = pin(<<"quod:user">>),
    {ok, [#{'N' := Places}], _} = quod_prolog:prove_ro(<<"quod:names">>,
        {count, {'_'}, <<"place">>, {'_'}, {'N'}}),
    #{height => Height, names => Expected, place_names => Places, user_hosting => true, node_hosting => true, enrollment => complete,
      anchors => maps:from_list([{Ns, hex(Anchor)} || #{namespace := Ns, anchor := Anchor} <- Descriptors]),
      node => text(Node)}.

%% Every icon of quod:gui reads back by its digest.
gui_assets() ->
    Gui = <<"quod:gui">>,
    {ok, [#{'Rows' := Assets}], _} = quod_prolog:prove_ro(Gui,
        {findall, {asset, {'D'}, {'M'}, {'B'}}, {gui_asset, {'D'}, {'M'}, {'B'}}, {'Rows'}}),
    [] = [D || {asset, D, _, B} <- Assets,
               string:lowercase(binary:encode_hex(crypto:hash(sha256, B))) =/= D],
    #{assets => length(Assets), bytes => lists:sum([byte_size(B) || {asset, _, _, B} <- Assets])}.

found_published(Ns, Files, Terms, Modules) ->
    Found = found(Ns, Files, Terms, Modules), publish(Ns, false), Found.

found(Ns, Files, Terms, Modules) ->
    {ok, not_hosted} = quod_ontology:local_state(Ns),
    true = quod_reg:subscribe({runtime, Ns}),
    try
        Sources = [{source_file, list_to_binary(path(F)), source_hash(F)} || F <- Files],
        {ok, [#{'Anchor' := Anchor}], _} = quod_prolog:execute(?ROOT,
            {create_ontology, Ns, Sources ++ [{terms, Terms}, {external_predicate_modules, Modules}], {'Anchor'}}),
        ok = await_ready(Ns),
        Anchor = quod_simplex:genesis_hash(Ns),
        {ok, Expected} = quod_predicates:module_manifest(Modules),
        {ok, [#{'Profile' := Expected}], _} = quod_prolog:prove_ro(Ns, {external_predicate_modules, {'Profile'}}),
        #{namespace => Ns, anchor => hex(Anchor),
          sources => maps:from_list([{list_to_binary(F), hex(source_hash(F))} || F <- Files])}
    after quod_reg:unsubscribe({runtime, Ns}) end.

publish(Ns, Creation) ->
    {ok, ready} = quod_ontology:local_state(Ns),
    Anchor = quod_simplex:genesis_hash(Ns),
    [] = rows(?ROOT, system_ontology, Ns),
    Facts = [{assertz, {system_ontology, Ns, Anchor}}] ++
        case Creation of true -> [{assertz, {ontology_creation_policy, Ns, Anchor}}]; false -> [] end,
    {ok, [_], _} = quod_prolog:execute(?ROOT, {transaction, conj(Facts)}),
    [Anchor] = rows(?ROOT, system_ontology, Ns),
    ok.

%% The anchor root lists for a system ontology already founded here.
pin(Ns) ->
    [Anchor] = rows(?ROOT, system_ontology, Ns),
    Anchor = quod_simplex:genesis_hash(Ns), Anchor.

gui_pins() ->
    Gui = pin(<<"quod:gui">>),
    [{gui_vocabulary, <<"quod:gui">>, Gui}, {measure_vocabulary, <<"quod:gui">>, Gui},
     {rendering_vocabulary, <<"quod:gui">>, Gui}, {modelling_vocabulary, <<"quod:gui">>, Gui}].

node_ref() -> {ok, Ref} = quod_node_actor:reference(), Ref.

path(File) -> filename:join([code:priv_dir(quod), "ontologies", File]).
source_hash(File) -> {ok, Bytes} = file:read_file(path(File)), crypto:hash(sha256, Bytes).

rows(Ontology, Predicate, '_') ->
    {ok, [#{'Rows' := Result}], _} = quod_prolog:prove_ro(Ontology,
        {findall, {'K'}, {Predicate, {'K'}, {'_'}}, {'Rows'}}),
    Result;
rows(Ontology, Predicate, Key) ->
    {ok, [#{'Rows' := Result}], _} = quod_prolog:prove_ro(Ontology,
        {findall, {'Value'}, {Predicate, Key, {'Value'}}, {'Rows'}}),
    Result.

conj([Goal]) -> Goal;
conj([Goal | More]) -> {',', Goal, conj(More)}.

await_ready(Ns) ->
    case quod_ontology:local_state(Ns) of
        {ok, ready} -> ok;
        _ -> receive _ -> await_ready(Ns) after 60000 -> {error, {not_ready, Ns}} end
    end.

await_node() ->
    case quod_node_actor:reference() of
        {ok, Ref} -> Ref;
        _ -> receive _ -> await_node() after 60000 -> error(node_actor_not_bound) end
    end.

hex(Binary) -> binary:encode_hex(Binary).
text(Term) -> iolist_to_binary(io_lib:format("~0p", [Term])).
