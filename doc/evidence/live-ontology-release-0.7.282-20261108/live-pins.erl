Dir = filename:join(code:priv_dir(quod), "ontologies"),
H = fun(F) -> {ok, B} = file:read_file(filename:join(Dir, F)), crypto:hash(sha256, B) end,
{ok, [#{'D' := T}], _} = quod_prolog:prove_ro(<<"quod:space">>, {space_template_hash, {'D'}}),
{ok, [#{'H' := U}], _} = quod_prolog:prove_ro(<<"quod:user">>, {user_source_component, <<"quod_space.pl">>, {'H'}}),
{ok, [#{'L' := L}], _} = quod_prolog:prove_ro(<<"quod:user">>, {findall, {'H'}, {user_source_component, <<"user_instance.pl">>, {'H'}}, {'L'}}),
[{template_pin_matches, T =:= H("quod_space.pl")}, {user_space_pin_matches, U =:= H("quod_space.pl")}, {user_instance_pins, length(L), L =:= [H("user_instance.pl")]}, {icon_on_gui, element(1, quod_prolog:prove_ro(<<"quod:gui">>, {gui_icon, enter, {'I'}}))}].
