{ok, Beam} = file:read_file("/tmp/quod_source_release.beam"),
{module, quod_source_release} = code:load_binary(quod_source_release, "quod_source_release.erl", Beam),
R = fun(F) -> {ok, B} = file:read_file("/tmp/" ++ F), B end,
Run = fun(Ns, File) -> quod_source_release:release(Ns, R("old-" ++ File), R("new-" ++ File), true) end,
Summ = fun(L) -> [case E of {planned, I, _} -> {planned, I}; Other -> Other end || E <- L] end,
#{scene => Summ(Run(<<"quod:gui">>, "gui_scene.pl")), gui => Summ(Run(<<"quod:gui">>, "menu_caption.pl")), space => Summ(Run(<<"quod:space">>, "quod_space.pl"))}.
