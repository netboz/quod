Ns = <<"human:65-UXSmsVRF0pjNPJ7mZGfwD8aRlsgoBaf47ODsr22o">>,
P = fun(Goal) -> case quod_prolog:prove_ro(Ns, Goal) of {ok, [#{'R' := R}], _} -> R; O -> O end end,
[{E, N, T} || {t, E, T} <- P({findall, {t, {'E'}, {'T'}}, {attribute, {'E'}, transform, {'T'}}, {'R'}}),
              N <- [case P({findall, {'N'}, {attribute, E, name, {'N'}}, {'R'}}) of [X] -> X; _ -> none end]].
