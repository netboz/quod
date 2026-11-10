%% Operator tooling, loaded into a running node: bring one ontology's stored
%% clauses from an old source text to a new one through the ordinary
%% complete-source edit (gui_tools prolog_edit_goal), one predicate at a time,
%% as the node's own authority. Nothing here is shipped code.
-module(quod_source_release).
-export([plan/3, apply/4, pins/3, predicate_source/2, release/4, apply_pins/3, clauses/2, render/2, plain/1]).

-define(GUI, <<"quod:gui">>).
-define(ROOT, <<"quod:root">>).

%% Clauses of a source text, grouped by predicate indicator, in order.
grouped(Ns, Text) ->
    {ok, [#{'Clauses' := Clauses}], _} = quod_prolog:prove_ro(Ns, {'$quod_program_source', {'Clauses'}, Text}),
    lists:foldl(fun(Clause, Acc) ->
        I = indicator(Clause),
        maps:update_with(I, fun(L) -> L ++ [Clause] end, [Clause], Acc)
    end, #{}, Clauses).

indicator({':-', Head, _}) -> indicator(Head);
indicator(Head) when is_atom(Head) -> {Head, 0};
indicator(Head) when is_tuple(Head) -> {element(1, Head), tuple_size(Head) - 1}.

%% Rendering names variables after their numbers, so every clause is renumbered
%% from zero in order of first occurrence before rendering, as stored text is.
render(Ns, Clauses) ->
    {ok, [#{'Text' := Text}], _} = quod_prolog:prove_ro(Ns, {'$quod_program_source', [canonical(C) || C <- Clauses], {'Text'}}),
    Text.
canonical(Clause) -> element(1, canonical(Clause, #{})).
canonical({N}, Seen) when is_integer(N) ->
    case Seen of #{N := K} -> {{K}, Seen}; _ -> K = map_size(Seen), {{K}, Seen#{N => K}} end;
canonical(T, Seen) when is_tuple(T) ->
    {L, Seen1} = canonical(tuple_to_list(T), Seen), {list_to_tuple(L), Seen1};
canonical([H | T], Seen) -> {H1, S1} = canonical(H, Seen), {T1, S2} = canonical(T, S1), {[H1 | T1], S2};
canonical(X, Seen) -> {X, Seen}.

%% The stored canonical source of one predicate in Ns; empty when absent. A
%% fact the editor asserted renders as `head :- true.`; a file's fact renders
%% plain. Both are the same clause, so stored text is read in the plain form.
predicate_source(Ns, {Name, Arity}) ->
    case quod_prolog:prove_ro(Ns, {prolog_introspection, {source, {'/', Name, Arity}}, {'Source'}}) of
        {ok, [#{'Source' := Source}], _} -> binary:replace(Source, <<" :- true.">>, <<".">>, [global]);
        _ -> <<>>
    end.

%% Every predicate whose clause list differs between the two texts, with the
%% draft text the editor must receive. Clauses are compared by their own
%% canonical rendering, one at a time, so neither variable numbering across a
%% file nor the stored form of a fact matters: the stored list loses the old
%% file's clauses and gains the new file's where the old ones stood, or at
%% the end when the predicate was new here.
plan(Ns, OldText, NewText) ->
    Old = grouped(Ns, OldText), New = grouped(Ns, NewText),
    Each = fun(Clauses) -> [plain(render(Ns, [C])) || C <- Clauses] end,
    [begin
         Before = predicate_source(Ns, I),
         Stored = case Before of <<>> -> []; _ -> Each(clauses(Ns, Before)) end,
         OldEach = Each(maps:get(I, Old, [])), NewEach = Each(maps:get(I, New, [])),
         Kept = [C || C <- Stored, not lists:member(C, OldEach)],
         %% Only clauses the stored text lacks are added, so a second run changes nothing.
         Fresh = [C || C <- NewEach, not lists:member(C, Kept)],
         Target = case [K || K <- lists:seq(1, length(Stored)), lists:member(lists:nth(K, Stored), OldEach)] of
             [] -> Kept ++ Fresh;
             [First | _] -> {Head, Tail} = lists:split(First - 1, Stored),
                            [C || C <- Head, not lists:member(C, OldEach)] ++ Fresh ++ [C || C <- Tail, not lists:member(C, OldEach)]
         end,
         #{indicator => I, before => Before,
           draft => case Target =:= Stored of true -> unchanged; false -> iolist_to_binary(Target) end}
     end || I <- lists:usort(maps:keys(Old) ++ maps:keys(New)), Each(maps:get(I, Old, [])) =/= Each(maps:get(I, New, []))].

clauses(Ns, Text) ->
    {ok, [#{'Clauses' := Clauses}], _} = quod_prolog:prove_ro(Ns, {'$quod_program_source', {'Clauses'}, Text}),
    Clauses.
plain(Text) -> binary:replace(Text, <<" :- true.">>, <<".">>, [global]).

%% Apply one planned predicate edit: the editor builds the guarded transaction
%% for the exact target identity; the node runs it from root as its own agent.
apply(Ns, Anchor, #{indicator := {Name, Arity}, before := Before, draft := Draft}, DryRun) when is_binary(Draft) ->
    Target = {ontology_ref, Ns, Anchor},
    case quod_prolog:prove_ro(?GUI, {prolog_edit_goal, Target, {'/', Name, Arity}, Before, Draft, {'Edit'}}) of
        {ok, [#{'Edit' := Edit}], _} ->
            case DryRun of
                true -> {planned, {Name, Arity}, Edit};
                false ->
                    case quod_prolog:execute(?ROOT, named_variables(Edit)) of
                        {ok, _, _} -> {applied, {Name, Arity}};
                        Other -> {failed, {Name, Arity}, Other}
                    end
            end;
        {fail, Reasons} -> {edit_goal_failed, {Name, Arity}, lists:last(Reasons)};
        Other -> {edit_goal_failed, {Name, Arity}, Other}
    end;
apply(_, _, #{indicator := I, draft := unchanged}, _) -> {unchanged, I};
apply(_, _, #{indicator := I, draft := {error, Reason}}, _) -> {skipped, I, Reason}.

%% A proof answer carries its unbound variables as {N}; a goal to execute
%% needs them as named variables, or the result bindings cannot be encoded.
named_variables({N}) when is_integer(N) -> {list_to_atom("_V" ++ integer_to_list(N))};
named_variables(T) when is_tuple(T) -> list_to_tuple([named_variables(E) || E <- tuple_to_list(T)]);
named_variables([H | T]) -> [named_variables(H) | named_variables(T)];
named_variables(X) -> X.

%% The digests the system ontologies pin for the files handed to new accounts,
%% recomputed from this node's own priv copies.
pins(SpaceNs, UserNs, Files) ->
    Dir = filename:join(code:priv_dir(quod), "ontologies"),
    Digest = fun(File) -> {ok, B} = file:read_file(filename:join(Dir, File)), crypto:hash(sha256, B) end,
    Space = Digest("quod_space.pl"),
    #{space_template_hash => binary:encode_hex(Space),
      current_space_template_hash => quod_prolog:prove_ro(SpaceNs, {space_template_hash, {'D'}}),
      current_user_components => quod_prolog:prove_ro(UserNs, {findall, {'-', {'F'}, {'H'}}, {user_source_component, {'F'}, {'H'}}, {'L'}}),
      new_user_components => [{F, binary:encode_hex(Digest(F))} || F <- Files]}.

%% Apply a whole plan, new predicates first so edited bodies never refer to a
%% symbol the ontology does not hold yet.
release(Ns, OldText, NewText, DryRun) ->
    Anchor = quod_simplex:genesis_hash(Ns),
    [apply(Ns, Anchor, E, DryRun) || E <- lists:reverse(plan(Ns, OldText, NewText))].

%% Re-pin the account source components and the space template to the files
%% this node now serves; one transaction per ontology, as the node's agent.
apply_pins(SpaceNs, UserNs, Files) ->
    Dir = filename:join(code:priv_dir(quod), "ontologies"),
    Digest = fun(File) -> {ok, B} = file:read_file(filename:join(Dir, File)), crypto:hash(sha256, B) end,
    Space = Digest(<<"quod_space.pl">>),
    Conj = fun C([G]) -> G; C([G | Rest]) -> {',', G, C(Rest)} end,
    In = fun(Ns, Goal) -> {'::', Ns, {',', {current_ontology_identity, Ns, quod_simplex:genesis_hash(Ns)}, {transaction, Goal}}} end,
    SpaceGoal = In(SpaceNs, Conj([{retract, {space_template_hash, {'_'}}}, {assertz, {space_template_hash, Space}}])),
    UserGoal = In(UserNs, Conj([{retract, {space_source_digest, {'_'}}}, {assertz, {space_source_digest, Space}}
                              | lists:append([[{retract, {user_source_component, F, {'_'}}}, {assertz, {user_source_component, F, Digest(F)}}] || F <- Files])])),
    [{space_pin, quod_prolog:execute(?ROOT, SpaceGoal)}, {user_pins, quod_prolog:execute(?ROOT, UserGoal)}].
