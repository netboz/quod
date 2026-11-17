{ok, Beam} = file:read_file("/tmp/quod_source_release.beam"),
{module, quod_source_release} = code:load_binary(quod_source_release, "quod_source_release.erl", Beam),
Dir = filename:join(code:priv_dir(quod), "ontologies"),
R = fun(F) -> {ok, B} = file:read_file(F), B end,
Gui = quod_source_release:release(<<"quod:gui">>, R("/tmp/old-quod_gui.pl"), R(filename:join(Dir, "quod_gui.pl")), false),
Space = quod_source_release:release(<<"quod:space">>, R("/tmp/old-quod_space.pl"), R(filename:join(Dir, "quod_space.pl")), false),
Pins = quod_source_release:apply_pins(<<"quod:space">>, <<"quod:user">>, [<<"user_instance.pl">>, <<"agent_instance.pl">>, <<"quod_space.pl">>, <<"gui_instance.pl">>]),
Check = [{G, element(1, quod_prolog:prove_ro(Ns, G))} || {Ns, G} <- [{<<"quod:gui">>, {gui_icon, attention, {'I'}}}, {<<"quod:space">>, {space_icon, enter, {'I'}}}, {<<"quod:space">>, {space_half_depth, infinite, {'H'}}}]],
io:format("~p~n", [#{gui => Gui, space => Space, pins => [{K, element(1, V)} || {K, V} <- Pins], check => Check}]), ok.
