{ok, Beam} = file:read_file("/tmp/quod_source_release.beam"),
{module, quod_source_release} = code:load_binary(quod_source_release, "quod_source_release.erl", Beam),
R = fun(F) -> {ok, B} = file:read_file("/tmp/" ++ F), B end,
[case E of {planned, I, _} -> {planned, I}; Other -> Other end
 || E <- quod_source_release:release(<<"quod:gui">>, R("old-gui_scene.pl"), R("new-gui_scene.pl"), false)].
