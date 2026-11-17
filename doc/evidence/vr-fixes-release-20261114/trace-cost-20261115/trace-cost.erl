%% One pie's node proof (client_menu, read-only), timed under a parent span that
%% is sampled (as every pie at ratio 1) or not sampled (as 19 pies in 20 at 1 in
%% 20). The sampler is parentbased_traceidratio, so children follow the parent.
Ns = <<"human:65-UXSmsVRF0pjNPJ7mZGfwD8aRlsgoBaf47ODsr22o">>,
Under = fun(Flags, F) ->
    Parent = otel_tracer:non_recording_span(rand:uniform(1 bsl 127), rand:uniform(1 bsl 63), Flags),
    Token = otel_ctx:attach(otel_tracer:set_current_span(otel_ctx:new(), Parent)),
    try F() after otel_ctx:detach(Token) end end,
Pie = fun(E) -> {T, {ok, [_], _}} = timer:tc(fun() -> quod_prolog:prove_ro(Ns, {client_menu, E, {'View'}}) end), T div 1000 end,
Median = fun(L) -> lists:nth((length(L) + 1) div 2, lists:sort(L)) end,
Run = fun(Name, E) ->
    [Pie(E) || _ <- [1, 2]],
    Rows = [{Under(1, fun() -> Pie(E) end), Under(0, fun() -> Pie(E) end)} || _ <- lists:seq(1, 10)],
    {S, U} = lists:unzip(Rows),
    #{space => Name, traced_ms => S, untraced_ms => U, traced_median => Median(S), untraced_median => Median(U)} end,
[Run(<<"Blackhurst">>, <<"01M7DFF09P5K89S2RRC0HHYDCR">>), Run(<<"Sushol">>, <<"01M7GF4JX4J93ACZ2DGPZ8QAVW">>)].
