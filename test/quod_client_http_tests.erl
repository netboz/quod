-module(quod_client_http_tests).
-moduledoc """
Handler tests that go through a real listener.

The routes are exercised over HTTPS rather than by calling `init/2` directly,
because the defect worth catching here lives in the seam between the handler and
cowboy. A handler that replies correctly but returns the wrong shape still
delivers its response — cowboy has already sent the bytes — and then crashes its
request process, so **every status assertion passes while every request logs a
crash**. That is exactly the state this module was written against, so the
assertions include the absence of crash reports, not only the responses.
""".

-include_lib("eunit/include/eunit.hrl").
-include("quod_client_goal_limits.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

%% The logger handler used by collect_crashes/1.
-export([log/2]).

-define(PEER, {127, 0, 0, 1}).

signed_goal_result_keeps_parser_variable_names_test() ->
    Evidence = #{request_digest => <<1:256>>,
                 request => #{operation_id => <<2:256>>},
                 variables => [{<<"Person">>, 0}]},
    ?assertEqual(
       {200, #{result => ok, height => 7,
               request_digest => b64url(<<1:256>>),
               operation_id => b64url(<<2:256>>),
               bindings => [#{<<"Person">> => <<"bob">>}]}},
       quod_client_http:signed_goal_result(
         {ok, Evidence,
          {normalized,
           quod_client_result:normalize(Evidence,
                                        {ok, [#{0 => bob}], 7})}})),
    ?assertEqual(
       {409, #{error => read_only}},
       quod_client_http:signed_goal_result(
         {ok, Evidence, {normalized, {error, read_only}}})).

signed_operation_resolution_has_one_pending_and_terminal_shape_test() ->
    Evidence = #{request_digest => <<1:256>>,
                 request => #{operation_id => <<2:256>>}},
    ?assertEqual(
       {202, #{result => operation_outcome, status => pending,
               terminal => false,
               request_digest => b64url(<<1:256>>),
               operation_id => b64url(<<2:256>>)}},
       quod_client_http:signed_goal_result(
         {ok, Evidence, {operation_pending, ignored}})),
    ?assertEqual(
       {200, #{result => operation_outcome, status => committed,
               terminal => true, claim_height => 3, height => 4,
               request_digest => b64url(<<1:256>>),
               operation_id => b64url(<<2:256>>)}},
       quod_client_http:signed_goal_result(
         {ok, Evidence,
          {operation_outcome, #{height => 3},
           #{status => committed, height => 4}}})),
    ?assertEqual(
       {409, #{error => operation_conflict}},
       quod_client_http:signed_goal_result({error, operation_conflict})).

signed_goal_busy_is_not_misreported_as_cursor_contention_test() ->
    ?assertEqual(
       {503, #{error => ontology_busy}},
       quod_client_http:signed_goal_result({error, busy})),
    ?assertEqual(
       {409, #{error => cursor_busy}},
       quod_client_http:signed_goal_result({error, cursor_busy})),
    ?assertEqual(
       {404, #{error => cursor_not_found}},
       quod_client_http:signed_goal_result({error, cursor_not_found})).

signed_dispatch_parent_and_cleanup_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Before = quod_trace:context(),
        Req = #{headers =>
                  #{<<"traceparent">> => trace_parent(),
                    <<"baggage">> => <<"private=must-not-be-carried">>,
                    <<"authorization">> => <<"private-authentication">>}},
        Result = quod_client_http:test_trace_request(
            Req, signed_goal_execute,
            fun() ->
                Carrier = quod_trace:inject(quod_trace:context()),
                ?assertNot(lists:keymember(<<"baggage">>, 1, Carrier)),
                quod_trace:with_span(
                  quod_trace:context(), <<"http.child">>, internal, #{},
                  fun(_) -> {ok, unchanged} end)
            end),
        ?assertEqual({ok, unchanged}, Result),
        ?assertEqual(Before, quod_trace:context()),
        Span = quod_trace_tests:take_span(<<"quod.client.request">>),
        Child = quod_trace_tests:take_span(<<"http.child">>),
        ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736,
                     Span#span.trace_id),
        ?assertEqual(16#00f067aa0ba902b7, Span#span.parent_span_id),
        ?assertEqual(server, Span#span.kind),
        ?assertEqual(Span#span.span_id, Child#span.parent_span_id),
        ?assertEqual(
           #{'quod.client.route' => <<"signed_goal_execute">>},
           otel_attributes:map(Span#span.attributes))
    end).

signed_dispatch_exception_preserves_reply_semantics_test() ->
    quod_trace_tests:with_tracer(fun() ->
        Before = quod_trace:context(),
        Req = #{headers => #{<<"traceparent">> => trace_parent()}},
        Reason = {private_failure, <<"never-export-this-payload">>},
        ?assertThrow(Reason,
          quod_client_http:test_trace_request(
            Req, signed_goal_read, fun() -> throw(Reason) end)),
        ?assertEqual(Before, quod_trace:context()),
        Span = quod_trace_tests:take_span(<<"quod.client.request">>),
        ?assert(Span#span.end_time >= Span#span.start_time),
        ?assertEqual(
           #{'quod.client.route' => <<"signed_goal_read">>,
             'quod.outcome' => <<"http_dispatch">>},
           otel_attributes:map(Span#span.attributes)),
        ?assertEqual(opentelemetry:status(error), Span#span.status)
    end).

client_http_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Port) ->
         [{"health replies and keeps the connection",
           fun() -> health_is_reusable(Port) end},
          {"an API reply does not crash its request process",
           fun() -> api_reply_is_clean(Port) end},
          {"every route honours the handler contract",
           fun() -> routes_are_crash_free(Port) end},
          {"an oversized body is refused",
           fun() -> oversized_body_is_refused(Port) end},
          {"a non-POST is refused",
           fun() -> method_is_enforced(Port) end},
          {"security headers are present",
           fun() -> security_headers_present(Port) end},
          {"sampled HTTP parent reaches the signed request span",
           fun() -> signed_http_parent_is_carried(Port) end}]
     end}.

%% Two requests on ONE connection: cowboy tears the connection down when a
%% handler breaks its contract, so a successful second request is the assertion.
health_is_reusable(Port) ->
    {ok, Connection} = connect(Port),
    ?assertMatch({200, _, <<"ok\n">>}, request(Connection, get, "/health", <<>>)),
    ?assertMatch({200, _, <<"ok\n">>}, request(Connection, get, "/health", <<>>)),
    close(Connection).

api_reply_is_clean(Port) ->
    {ok, Connection} = connect(Port),
    %% Malformed on purpose: the reply's content is not the point, surviving it
    %% is. A bad field is a bad request, never a failed authentication.
    ?assertMatch({400, _, _},
                 request(Connection, post, "/api/auth/challenge", <<"{}">>)),
    ?assertMatch({400, _, _},
                 request(Connection, post, "/api/auth/complete", <<"nonsense">>)),
    ?assertMatch({404, _, _},
                 request(Connection, post, "/api/user/register", <<"{}">>)),
    ?assertMatch({400, _, _},
                 request(Connection, post, "/api/goals/read", <<"{}">>)),
    %% Still usable, so none of those replies killed the stream.
    ?assertMatch({200, _, _}, request(Connection, get, "/health", <<>>)),
    close(Connection).

%% The real signal for a broken handler contract: cowboy sends the response and
%% *then* the request process dies, so only the crash report distinguishes a
%% healthy route from one that raises on every single call.
routes_are_crash_free(Port) ->
    Crashes = collect_crashes(
                fun() ->
                    {ok, Connection} = connect(Port),
                    _ = request(Connection, get, "/health", <<>>),
                    _ = request(Connection, post, "/api/auth/challenge", <<"{}">>),
                    _ = request(Connection, post, "/api/auth/complete", <<"{}">>),
                    _ = request(Connection, post, "/api/user/register", <<"{}">>),
                    _ = request(Connection, post, "/api/goals/read", <<"{}">>),
                    _ = request(Connection, post, "/api/goals/execute", <<"{}">>),
                    _ = request(Connection, post, "/api/goals/outcomes", <<"{}">>),
                    _ = request(Connection, post, "/api/goals/cursors", <<"{}">>),
                    _ = request(Connection, get, "/api/auth/challenge", <<>>),
                    _ = request(Connection, post, "/api/auth/challenge",
                                binary:copy(<<"A">>, 8192)),
                    close(Connection)
                end),
    ?assertEqual([], Crashes).

%% `length` in cowboy_req:read_body/2 is a chunk hint, not a limit, so a body
%% delivered in one piece arrives whole however large it is.
oversized_body_is_refused(Port) ->
    {ok, Connection} = connect(Port),
    Body = <<"{\"public_key\":\"", (binary:copy(<<"A">>, 8192))/binary, "\"}">>,
    ?assertMatch({413, _, _},
                 request(Connection, post, "/api/auth/challenge", Body)),
    %% Pin the independent, larger cap on the signed-goal route as well.  Raw
    %% junk is intentional: body admission must happen before JSON decoding.
    SignedGoalBody = binary:copy(
                       <<"A">>, ?QUOD_CLIENT_GOAL_REQUEST_BYTES * 2),
    ?assertMatch({413, _, _},
                 request(Connection, post, "/api/goals/read", SignedGoalBody)),
    close(Connection).

method_is_enforced(Port) ->
    {ok, Connection} = connect(Port),
    ?assertMatch({405, _, _},
                 request(Connection, get, "/api/auth/challenge", <<>>)),
    close(Connection).

security_headers_present(Port) ->
    {ok, Connection} = connect(Port),
    {200, Headers, _} = request(Connection, get, "/health", <<>>),
    ?assertMatch(#{<<"content-security-policy">> := _}, Headers),
    ?assertEqual(<<"nosniff">>, maps:get(<<"x-content-type-options">>, Headers)),
    close(Connection).

signed_http_parent_is_carried(Port) ->
    quod_trace_tests:with_tracer(fun() ->
        {ok, Connection} = connect(Port),
        try
            %% Malformed goal JSON still follows the real signed HTTP dispatch:
            %% validation refusal must finish the same incoming-parent span.
            ?assertMatch({400, _, _},
              request(Connection, post, "/api/goals/execute", <<"{}">>,
                      [[<<"traceparent: ">>, trace_parent(), <<"\r\n">>],
                       <<"baggage: private=not-a-trace-attribute\r\n">>])),
            Span = quod_trace_tests:take_span(<<"quod.client.request">>),
            ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736,
                         Span#span.trace_id),
            ?assertEqual(16#00f067aa0ba902b7, Span#span.parent_span_id),
            ?assertEqual(true, Span#span.parent_span_is_remote),
            ?assertEqual(server, Span#span.kind),
            ?assertNot(Span#span.is_recording),
            ?assert(Span#span.end_time >= Span#span.start_time),
            ?assertMatch({200, _, _}, request(Connection, get, "/health", <<>>))
        after close(Connection)
        end
    end).

trace_parent() ->
    <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>.

%% ======================================================================
%% harness
%% ======================================================================

%% Run `Fun` with a logger handler attached, and report the error-level reports
%% cowboy emitted while it ran.
collect_crashes(Fun) ->
    Collector = self(),
    Id = list_to_atom("crash-collector-" ++
                          integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(
           Id, ?MODULE, #{level => error, config => #{collector => Collector}}),
    try
        Fun(),
        %% Requests are answered before their process dies, so a crash report
        %% can trail the response it belongs to.
        timer:sleep(100),
        drain()
    after logger:remove_handler(Id)
    end.

drain() ->
    receive {crash_report, Report} -> [Report | drain()]
    after 0 -> []
    end.

%% logger handler callback.
log(#{level := Level, msg := Msg}, #{config := #{collector := Collector}})
  when Level =:= error; Level =:= critical ->
    Collector ! {crash_report, Msg},
    ok;
log(_Event, _Config) ->
    ok.

setup() ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    Dir = tls_dir(),
    {ok, Tls} = quod_client_tls:ensure(Dir),
    {ok, _} = quod_client_auth:start_link(
                #{network_id => <<16#10:256>>, node_key => <<16#11:256>>}),
    {ok, started} =
        quod_http_listener:start(
          #{name => ?MODULE, ip => ?PEER, port => 0, routes => routes(),
            stream_handlers => [quod_http_headers_h], tls => Tls}),
    ranch:get_port(?MODULE).

cleanup(_Port) ->
    quod_http_listener:stop(?MODULE),
    case whereis(quod_client_auth) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            MRef = monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', MRef, process, Pid, _} -> ok after 5000 -> ok end
    end.

routes() ->
    [{'_', [{"/health", quod_client_http, health},
            {"/api/auth/challenge", quod_client_http, auth_challenge},
            {"/api/auth/complete", quod_client_http, auth_complete},
            {"/api/goals/read", quod_client_http, signed_goal_read},
            {"/api/goals/execute", quod_client_http, signed_goal_execute},
            {"/api/goals/outcomes", quod_client_http, signed_goal_outcome},
            {"/api/goals/cursors", quod_client_http, signed_goal_cursor},
            {"/api/goals/cursors/:id/next", quod_client_http,
             signed_cursor_next},
            {"/api/goals/cursors/:id/accept", quod_client_http,
             signed_cursor_accept},
            {"/api/goals/cursors/:id", quod_client_http,
             signed_cursor_stop}]}].

tls_dir() ->
    Dir = filename:join(["/tmp", "quod-client-http-tests",
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

%% A hand-written HTTP/1.1 exchange rather than an HTTP client dependency: the
%% point of these tests is precisely what a client library hides — whether the
%% connection survives a response — so the socket stays visible.
connect(Port) ->
    %% Self-signed by design; these tests are about the handler, not the chain.
    ssl:connect("127.0.0.1", Port,
                [binary, {active, false}, {verify, verify_none}], 5000).

close(Socket) -> ssl:close(Socket).

request(Socket, Method, Path, Body) ->
    request(Socket, Method, Path, Body, []).

request(Socket, Method, Path, Body, TraceHeaders) ->
    Verb = case Method of get -> <<"GET">>; post -> <<"POST">> end,
    Request = [Verb, <<" ">>, Path, <<" HTTP/1.1\r\nhost: localhost\r\n">>,
               <<"content-type: application/json\r\n">>,
               TraceHeaders,
               <<"content-length: ">>, integer_to_binary(byte_size(Body)),
               <<"\r\n\r\n">>, Body],
    ok = ssl:send(Socket, Request),
    read_response(Socket).

read_response(Socket) ->
    {Head, Rest} = read_until_headers(Socket, <<>>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, Status | _] = binary:split(StatusLine, <<" ">>, [global]),
    Headers = maps:from_list([header(L) || L <- HeaderLines, L =/= <<>>]),
    Length = binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)),
    {binary_to_integer(Status), Headers, read_body(Socket, Rest, Length)}.

read_until_headers(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] -> {Head, Rest};
        [_] ->
            {ok, More} = ssl:recv(Socket, 0, 5000),
            read_until_headers(Socket, <<Acc/binary, More/binary>>)
    end.

read_body(_Socket, Acc, Length) when byte_size(Acc) >= Length ->
    binary:part(Acc, 0, Length);
read_body(Socket, Acc, Length) ->
    {ok, More} = ssl:recv(Socket, 0, 5000),
    read_body(Socket, <<Acc/binary, More/binary>>, Length).

header(Line) ->
    [Name, Value] = binary:split(Line, <<": ">>),
    {string:lowercase(Name), Value}.

b64url(Bytes) ->
    base64:encode(Bytes, #{mode => urlsafe, padding => false}).
