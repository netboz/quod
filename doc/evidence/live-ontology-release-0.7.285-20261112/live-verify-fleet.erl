S = {surface, <<"#C9D2DB">>, 0, 700, 1000, 1000, []},
P = fun(Ns, G) -> element(1, quod_prolog:prove_ro(Ns, G)) end,
{quod_prolog:applied(<<"quod:root">>), quod_prolog:applied(<<"quod:gui">>), quod_prolog:applied(<<"quod:space">>),
 P(<<"quod:gui">>, {model, [{part, <<"x">>, {corner_box, {'/', 1, 3}, 500, 500}, {transform, 0, 0, 0, 0, 0, 0}, {surfaces, S, S, S}, unlabelled, depicts_nothing}], {'M'}}),
 P(<<"quod:gui">>, {marker_size, 500}),
 P(<<"quod:space">>, {class_eidolon, space, edition, solid, {'R'}}),
 P(<<"quod:space">>, {space_half_depth, infinite, {'H'}}),
 maps:get(node_enrollment, quod_namespace_manager:stats(), none)}.
