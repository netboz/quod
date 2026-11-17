{ok, Beam} = file:read_file("/tmp/quod_source_release.beam"),
{module, quod_source_release} = code:load_binary(quod_source_release, "quod_source_release.erl", Beam),
R = fun(F) -> {ok, B} = file:read_file("/tmp/" ++ F), B end,
Run = fun(Ns, File) -> quod_source_release:release(Ns, R("old-" ++ File), R("new-" ++ File), false) end,
Scene = Run(<<"quod:gui">>, "gui_scene.pl"),
Gui = Run(<<"quod:gui">>, "menu_caption.pl"),
Space = Run(<<"quod:space">>, "quod_space.pl"),
#{scene => Scene, gui => Gui, space => Space}.
