Ns = <<"human:65-UXSmsVRF0pjNPJ7mZGfwD8aRlsgoBaf47ODsr22o">>,
P = fun(Goal) -> case quod_prolog:prove_ro(Ns, Goal) of {ok, [#{'R' := R}], _} -> R; O -> O end end,
Short = fun({entity_ref, _, _, E}) -> E; ({agent_instance_ref, _, _, E}) -> {agent, E}; (X) -> X end,
#{placements => [{Short(D), Short(S), T} || {p, D, S, T} <- P({findall, {p, {'D'}, {'S'}, {'T'}}, {space_placement, {'D'}, {'S'}, {'T'}}, {'R'}})]}.
