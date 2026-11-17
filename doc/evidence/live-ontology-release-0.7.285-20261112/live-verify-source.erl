{ok, Beam} = file:read_file("/tmp/quod_source_release.beam"),
{module, M} = code:load_binary(quod_source_release, "quod_source_release.erl", Beam),
R = fun(F) -> {ok, B} = file:read_file("/tmp/" ++ F), B end,
Ind = fun I({':-', H, _}) -> I(H); I(H) when is_atom(H) -> {H, 0}; I(H) -> {element(1, H), tuple_size(H) - 1} end,
Each = fun(Ns, Cs) -> [M:plain(M:render(Ns, [C])) || C <- Cs] end,
Group = fun(Ns, Text) -> lists:foldl(fun(C, A) -> maps:update_with(Ind(C), fun(L) -> L ++ [C] end, [C], A) end, #{}, M:clauses(Ns, Text)) end,
Sub = fun S([], _) -> true; S(_, []) -> false; S([X | Xs], [X | Ys]) -> S(Xs, Ys); S(Xs, [_ | Ys]) -> S(Xs, Ys) end,
Check = fun(Ns, File) ->
    Old = Group(Ns, R("old-" ++ File)), New = Group(Ns, R("new-" ++ File)),
    [begin
        Stored = case M:predicate_source(Ns, I) of <<>> -> []; T -> Each(Ns, M:clauses(Ns, T)) end,
        N = Each(Ns, maps:get(I, New, [])), O = Each(Ns, maps:get(I, Old, [])),
        Gone = [C || C <- O, not lists:member(C, N), lists:member(C, Stored)],
        {I, Sub(N, Stored), Gone =:= [], length(N), length(Stored)}
     end || I <- lists:usort(maps:keys(Old) ++ maps:keys(New))]
end,
[begin Rows = Check(Ns, F), {F, length(Rows), [X || X = {_, A, B, _, _} <- Rows, not (A andalso B)]} end || {Ns, F} <- [{<<"quod:gui">>, "gui_scene.pl"}, {<<"quod:gui">>, "menu_caption.pl"}, {<<"quod:space">>, "quod_space.pl"}]].
