#!/usr/bin/env escript
%%! +S 4:4 +SDio 2 +SDcpu 2
main([MetadataPath]) ->
    code:add_paths(filelib:wildcard("_build/test/lib/*/ebin")),
    code:add_patha("_build/test/lib/quod/test"),
    application:load(quod),
    Owner = self(),
    spawn(fun() -> case io:get_line("") of "stop\n" -> Owner ! stop; _ -> ok end end),
    quod_lifecycle_single_path_tests:preview_worlds(MetadataPath).
