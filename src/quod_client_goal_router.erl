-module(quod_client_goal_router).
-moduledoc """
Bounded node-to-node transport owner for signed client goals.

This process owns only the fixed channel, exact peer/link/request
correlations, short-lived workers, and volatile remote cursor routes.  Signed
request verification and goal execution live in `quod_client_goal_target`;
cursor continuation lives only in `quod_client_cursor`.
""".

-behaviour(gen_server).

-include("quod_client_goal_limits.hrl").

-export([start_link/0, submit/9, cursor/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-ifdef(TEST).
-export([test_start_link/1, test_submit/10, test_cursor/5, test_stats/1,
         test_cursor_target_result/1, test_submit_target_result/2]).
-endif.

-type owner() :: {session, <<_:256>>, <<_:256>>}.
-type route() :: #{node_key := <<_:256>>, endpoint := term()}.
-type request_result() ::
        {ok, quod_client_goal:evidence(),
         {normalized, quod_client_result:result()}} |
        {error, pre_send | unavailable |
                {uncertain, quod_client_goal:evidence()} |
                {refused, not_ready | busy | rate_limited} |
                invalid_request | invalid_signature | wrong_network |
                wrong_target | expired | not_found | busy}.

-record(s, {
    channel :: binary(),
    subscribed = true :: boolean(),
    open_fun = fun quod_quic:open_link_pinned/3 :: fun(),
    correlations = #{} :: map(),
    inbound = #{} :: map(),
    routes = #{} :: map()
}).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-ifdef(TEST).
test_start_link(OpenFun) when is_function(OpenFun, 3) ->
    gen_server:start_link(?MODULE, {test, OpenFun}, []).

test_submit(Router, Route, Owner, Evidence, RequestBytes, Signature,
            CursorBinding, TraceCarrier, ExpiresMs, TimeoutMs) ->
    call(Router,
         {submit, Route, Owner, Evidence, RequestBytes, Signature,
          CursorBinding, TraceCarrier, ExpiresMs, TimeoutMs}).

test_cursor(Router, Owner, CursorId, Command, TimeoutMs) ->
    call(Router, {cursor, Owner, CursorId, Command, TimeoutMs}).

test_stats(Router) ->
    S = sys:get_state(Router),
    #{correlations => map_size(S#s.correlations),
      inbound => map_size(S#s.inbound),
      routes => map_size(S#s.routes)}.

test_cursor_target_result(Result) ->
    cursor_target_result(Result).

test_submit_target_result(Request, Result) ->
    submit_target_result(Request, Result).
-endif.

-doc "Forward one exact signed request to one exact pinned route.".
-spec submit(route(), owner(), quod_client_goal:evidence(), binary(),
             <<_:512>>, none | <<_:256>>, list(), integer(), timeout()) ->
          request_result().
submit(Route, Owner, Evidence, RequestBytes, Signature, CursorBinding,
       TraceCarrier, ExpiresMs, TimeoutMs) ->
    call({submit, Route, Owner, Evidence, RequestBytes, Signature,
          CursorBinding, TraceCarrier, ExpiresMs, TimeoutMs}).

-doc "Resume one cursor through its exact retained target route.".
-spec cursor(owner(), <<_:256>>, next | accept | stop, timeout()) ->
          request_result().
cursor(Owner, CursorId, Command, TimeoutMs) ->
    call({cursor, Owner, CursorId, Command, TimeoutMs}).

call(Request) ->
    case whereis(?MODULE) of
        Router when is_pid(Router) -> call(Router, Request);
        undefined ->
            {error, pre_send}
    end.

call(Router, Request) when is_pid(Router) ->
    Ref = make_ref(),
    MRef = monitor(process, Router),
    Router ! {'$gen_call', {self(), Ref}, Request},
    await_call(Ref, MRef, request_timeout(Request)).

await_call(Ref, MRef, TimeoutMs) ->
    receive
        {Ref, Reply} ->
            demonitor(MRef, [flush]),
            Reply;
        {'DOWN', MRef, process, _Router, _Reason} ->
            %% An admitted worker replies directly. Give it one short cleanup
            %% turn so router restart cannot erase post-send uncertainty.
            receive {Ref, Reply} -> Reply
            after 1000 -> {error, unavailable}
            end
    after TimeoutMs + 1000 ->
        demonitor(MRef, [flush]),
        {error, unavailable}
    end.

request_timeout({submit, _, _, _, _, _, _, _, _, TimeoutMs})
  when is_integer(TimeoutMs), TimeoutMs > 0 -> TimeoutMs;
request_timeout({cursor, _, _, _, TimeoutMs})
  when is_integer(TimeoutMs), TimeoutMs > 0 -> TimeoutMs;
request_timeout(_Request) -> ?QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS.

init([]) ->
    Channel = quod_client_goal_endpoint:channel(),
    true = quod_reg:subscribe({channel, Channel}),
    {ok, #s{channel = Channel}};
init({test, OpenFun}) ->
    {ok, #s{channel = quod_client_goal_endpoint:channel(),
            subscribed = false, open_fun = OpenFun}}.

handle_call(
  {submit, Route, Owner, Evidence, RequestBytes, Signature, CursorBinding,
   TraceCarrier, ExpiresMs, TimeoutMs}, From, S0) ->
    RequestId = request_id(),
    Request = {submit, RequestId, RequestBytes, Signature,
               CursorBinding, TraceCarrier},
    case validate_submit(Route, Owner, CursorBinding, ExpiresMs, TimeoutMs,
                         Request, S0) of
        {ok, PeerKey, Endpoint, RouteKey, Frame} ->
            Router = self(),
            OpenFun = S0#s.open_fun,
            {Worker, MRef} = spawn_monitor(
                               fun() ->
                                   outbound_open_worker(
                                     Router, From, PeerKey, Endpoint,
                                     Request, Frame, TimeoutMs, RouteKey,
                                     ExpiresMs, Evidence, OpenFun)
                               end),
            Corr = #{worker => Worker, mref => MRef, peer => PeerKey,
                     link => undefined, request => Request,
                     route_key => RouteKey, kind => submit},
            Routes1 = reserve_route(
                        RouteKey, Worker, ExpiresMs, Evidence, S0#s.routes),
            {noreply,
             S0#s{correlations =
                       (S0#s.correlations)#{RequestId => Corr},
                   routes = Routes1}};
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call({cursor, Owner, CursorId, Command, TimeoutMs}, From, S0) ->
    RouteKey = {Owner, CursorId},
    case validate_cursor_request(RouteKey, Command, TimeoutMs, S0) of
        {ok, Route, Request, Frame} ->
            RequestId = quod_client_goal_endpoint:request_id(Request),
            PeerKey = maps:get(peer, Route),
            Link = maps:get(link, Route),
            Router = self(),
            {Worker, MRef} = spawn_monitor(
                               fun() ->
                                   outbound_link_worker(
                                     Router, From, PeerKey, Link,
                                     Request, Frame, TimeoutMs, RouteKey,
                                     #{expires_ms => maps:get(expires_ms, Route),
                                       evidence => maps:get(evidence, Route)})
                               end),
            Corr = #{worker => Worker, mref => MRef, peer => PeerKey,
                     link => Link, request => Request,
                     route_key => RouteKey, kind => {cursor, Command}},
            Route1 = Route#{busy => Worker},
            {noreply,
             S0#s{correlations =
                       (S0#s.correlations)#{RequestId => Corr},
                   routes = (S0#s.routes)#{RouteKey => Route1}}};
        {error, _} = Error ->
            {reply, Error, S0}
    end;
handle_call({bind, Worker, RequestId, PeerKey, Link}, _From, S0) ->
    case maps:get(RequestId, S0#s.correlations, undefined) of
        #{worker := Worker, peer := PeerKey, link := Existing} = Corr
          when Existing =:= undefined; Existing =:= Link ->
            Corr1 = Corr#{link => Link},
            {reply, ok,
             S0#s{correlations =
                       (S0#s.correlations)#{RequestId => Corr1}}};
        _ ->
            {reply, {error, unavailable}, S0}
    end;
handle_call({route_result, Worker, RouteKey, Result, Peer, Link, ExpiresMs},
            _From, S0) ->
    {Reply, S1} = route_result(
                    Worker, RouteKey, Result, Peer, Link, ExpiresMs, S0),
    {reply, Reply, S1};
handle_call(_Request, _From, S) ->
    {reply, {error, bad_request}, S}.

handle_cast(_Message, S) -> {noreply, S}.

handle_info(
  {quod_message, {PeerIdentity, Link}, Channel, Payload},
  S0 = #s{channel = Channel}) when is_pid(Link) ->
    case quod_link:peer_key(PeerIdentity) of
        <<_:256>> = PeerKey ->
            {noreply, route_frame(PeerKey, Link, Payload, S0)};
        undefined ->
            {noreply, S0}
    end;
handle_info({'DOWN', MRef, process, Pid, _Reason}, S0) ->
    {noreply, down(MRef, Pid, S0)};
handle_info({route_expired, RouteKey, Token}, S0) ->
    case maps:get(RouteKey, S0#s.routes, undefined) of
        #{expiry_token := Token} -> {noreply, drop_route(RouteKey, S0)};
        _ -> {noreply, S0}
    end;
handle_info(_Message, S) -> {noreply, S}.

terminate(_Reason, S) ->
    case S#s.subscribed of
        true ->
            _ = try quod_reg:unsubscribe({channel, S#s.channel})
                catch _:_ -> ok
                end;
        false -> ok
    end,
    %% Outbound workers monitor this router and deliver their exact
    %% uncertainty reply directly to the waiting caller.
    maps:foreach(fun(Worker, _Row) -> exit(Worker, shutdown) end,
                 S#s.inbound),
    maps:foreach(fun(_Key, Route) -> cancel_route_timer(Route) end,
                 S#s.routes),
    ok.

validate_submit(Route, Owner, CursorBinding, ExpiresMs, TimeoutMs,
                Request, S) ->
    RouteKey = case CursorBinding of
                   <<_:256>> = CursorId -> {Owner, CursorId};
                   none -> none
               end,
    case {valid_route(Route), valid_owner(Owner),
          valid_deadline(ExpiresMs), valid_timeout(TimeoutMs),
          quod_client_goal_endpoint:encode_request(Request),
          admit_correlation(S), admit_route(RouteKey, S)} of
        {true, true, true, true, {ok, Frame}, ok, ok} ->
            {ok, maps:get(node_key, Route), maps:get(endpoint, Route),
             RouteKey, Frame};
        {_, _, _, _, {error, _}, _, _} -> {error, invalid_request};
        {false, _, _, _, _, _, _} -> {error, invalid_request};
        {_, false, _, _, _, _, _} -> {error, invalid_request};
        {_, _, false, _, _, _, _} -> {error, invalid_request};
        {_, _, _, false, _, _, _} -> {error, invalid_request};
        {_, _, _, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, _, _, {error, _} = Error} -> Error
    end.

validate_cursor_request(RouteKey, Command, TimeoutMs, S) ->
    Request = {cursor, request_id(), element(2, RouteKey), Command},
    case {valid_timeout(TimeoutMs),
          quod_client_goal_endpoint:encode_request(Request),
          admit_correlation(S), maps:get(RouteKey, S#s.routes, undefined)} of
        {true, {ok, Frame}, ok,
         #{state := active, busy := none, link := Link} = Route}
          when is_pid(Link) -> {ok, Route, Request, Frame};
        {true, {ok, _}, ok, #{state := active}} -> {error, busy};
        {true, {ok, _}, ok, _} -> {error, not_found};
        {_, {error, _}, _, _} -> {error, invalid_request};
        {false, _, _, _} -> {error, invalid_request};
        {_, _, {error, _} = Error, _} -> Error
    end.

valid_route(#{node_key := <<_:256>>, endpoint := Endpoint}) ->
    quod_quic:valid_endpoint(Endpoint);
valid_route(_) -> false.

valid_owner({session, <<_:256>>, <<_:256>>}) -> true;
valid_owner(_) -> false.

valid_deadline(Value) -> is_integer(Value) andalso Value >= 0.
valid_timeout(Value) ->
    is_integer(Value) andalso Value > 0 andalso
        Value =< ?QUOD_CLIENT_GOAL_ROUTER_TIMEOUT_MS.

admit_correlation(#s{correlations = Correlations})
  when map_size(Correlations) < ?QUOD_CLIENT_GOAL_MAX_CORRELATIONS -> ok;
admit_correlation(_S) -> {error, busy}.

admit_route(none, _S) -> ok;
admit_route(Key, #s{routes = Routes}) ->
    case {maps:is_key(Key, Routes),
          map_size(Routes) < ?QUOD_CLIENT_GOAL_MAX_CORRELATIONS} of
        {false, true} -> ok;
        {true, _} -> {error, busy};
        {_, false} -> {error, busy}
    end.

reserve_route(none, _Worker, _ExpiresMs, _Evidence, Routes) -> Routes;
reserve_route(Key, Worker, ExpiresMs, Evidence, Routes) ->
    Routes#{Key => #{state => pending, busy => Worker,
                     expires_ms => ExpiresMs, evidence => Evidence}}.

outbound_open_worker(Router, From, Peer, Endpoint, Request, Frame,
                     TimeoutMs, RouteKey, ExpiresMs, Evidence, OpenFun) ->
    CallerMRef = monitor(process, element(1, From)),
    RouterMRef = monitor(process, Router),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    Channel = quod_client_goal_endpoint:channel(),
    OpenRef = OpenFun(Peer, Endpoint, Channel),
    receive
        {link_up, OpenRef, Peer, Channel, Link} ->
            case bind_and_send(Router, Request, Peer, Link, Frame) of
                ok ->
                    outbound_responses(
                      Router, From, CallerMRef, RouterMRef, Peer, Link,
                      Request, Deadline, RouteKey,
                      #{expires_ms => ExpiresMs, evidence => Evidence});
                {error, _} -> reply(From, {error, pre_send})
            end;
        {link_error, OpenRef, Peer, _Channel} ->
            reply(From, {error, pre_send});
        {'DOWN', CallerMRef, process, _Caller, _} -> ok;
        {'DOWN', RouterMRef, process, Router, _} ->
            reply(From, {error, unavailable})
    after remaining(Deadline) ->
        reply(From, {error, pre_send})
    end.

outbound_link_worker(Router, From, Peer, Link, Request, Frame, TimeoutMs,
                     RouteKey, Meta) ->
    CallerMRef = monitor(process, element(1, From)),
    RouterMRef = monitor(process, Router),
    Deadline = quod_time:mono_ms() + TimeoutMs,
    case bind_and_send(Router, Request, Peer, Link, Frame) of
        ok ->
            outbound_responses(
              Router, From, CallerMRef, RouterMRef, Peer, Link, Request,
              Deadline, RouteKey, Meta);
        {error, _} -> reply(From, uncertain_reply(Meta))
    end.

bind_and_send(Router, Request, Peer, Link, Frame) ->
    RequestId = quod_client_goal_endpoint:request_id(Request),
    try gen_server:call(
          Router, {bind, self(), RequestId, Peer, Link}, 5000) of
        ok -> quod_link:send_ordered(Link, Frame), ok;
        {error, _} = Error -> Error
    catch exit:_ -> {error, unavailable}
    end.

outbound_responses(Router, From, CallerMRef, RouterMRef, Peer, Link, Request,
                   Deadline, RouteKey, Meta) ->
    receive
        {router_response, Payload} ->
            case quod_client_goal_endpoint:decode_response(Payload) of
                {ok, Response} ->
                    outbound_response(
                      Router, From, Peer, Link,
                      Request, Response, RouteKey, Meta);
                {error, _} ->
                    reply(From, uncertain_reply(Meta))
            end;
        {'DOWN', CallerMRef, process, _Caller, _} -> ok;
        {'DOWN', RouterMRef, process, Router, _} ->
            reply(From, uncertain_reply(Meta))
    after remaining(Deadline) ->
        reply(From, uncertain_reply(Meta))
    end.

outbound_response(Router, From, Peer, Link, Request, Response, RouteKey,
                  Meta) ->
    case quod_client_goal_endpoint:correlates(Request, Response) of
        false -> reply(From, uncertain_reply(Meta));
        true ->
            case Response of
                {refused, _, Reason} ->
                    reply(From, {error, {refused, Reason}});
                {error, _, Reason} ->
                    reply(From, {error, Reason});
                {result, _, ResultBlob} ->
                    finish_result(
                      Router, From, RouteKey, Request, ResultBlob, Peer,
                      Link, Meta);
                {cursor_result, _, _, ResultBlob} ->
                    finish_result(
                      Router, From, RouteKey, Request, ResultBlob, Peer,
                      Link, Meta)
            end
    end.

finish_result(Router, From, RouteKey, _Request, ResultBlob, Peer, Link,
              #{expires_ms := ExpiresMs, evidence := Evidence}) ->
    case quod_client_result:decode(ResultBlob) of
        {ok, Result} ->
            RouteReply = try gen_server:call(
                      Router,
                      {route_result, self(), RouteKey, Result, Peer, Link,
                       ExpiresMs}, 5000)
                catch exit:_ -> {error, unavailable}
                end,
            case RouteReply of
                ok ->
                    reply(From, {ok, Evidence, {normalized, Result}});
                {error, _} -> reply(From, {error, {uncertain, Evidence}})
            end;
        {error, _} ->
            reply(From, {error, {uncertain, Evidence}})
    end.

reply(From, Reply) -> gen_server:reply(From, Reply), ok.

uncertain_reply(#{evidence := Evidence}) ->
    {error, {uncertain, Evidence}}.

remaining(Deadline) -> erlang:max(0, Deadline - quod_time:mono_ms()).

route_frame(Peer, Link, Payload, S0) ->
    case quod_client_goal_endpoint:route_response(Payload) of
        {ok, Response} ->
            route_response(Peer, Link, Payload, Response, S0);
        {error, _} ->
            route_request(Peer, Link, Payload, S0)
    end.

route_response(Peer, Link, Payload, Response, S) ->
    RequestId = quod_client_goal_endpoint:response_id(Response),
    case maps:get(RequestId, S#s.correlations, undefined) of
        #{worker := Worker, peer := Peer, link := Link} ->
            Worker ! {router_response, Payload},
            S;
        _ -> S
    end.

route_request(Peer, Link, Payload, S0) ->
    case quod_client_goal_endpoint:route_request(Payload) of
        {ok, Request} ->
            case admit_inbound(Peer, S0#s.inbound) of
                true ->
                    {Worker, MRef} = spawn_monitor(
                                       fun() ->
                                           inbound_worker(
                                             Peer, Link, Request)
                                       end),
                    S0#s{inbound =
                              (S0#s.inbound)#{Worker =>
                                                  #{mref => MRef,
                                                    peer => Peer}}};
                false ->
                    send_response(
                      Link,
                      {refused,
                       quod_client_goal_endpoint:request_id(Request), busy}),
                    S0
            end;
        {error, _} -> S0
    end.

admit_inbound(Peer, Inbound) ->
    map_size(Inbound) < ?QUOD_CLIENT_GOAL_MAX_INBOUND_WORKERS andalso
        length([ok || #{peer := Existing} <- maps:values(Inbound),
                      Existing =:= Peer]) <
            ?QUOD_CLIENT_GOAL_MAX_INBOUND_PER_FORWARDER.

inbound_worker(Peer, Link, Request) ->
    %% The router already canonical-decoded and bounded the envelope.  The
    %% target independently verifies the opaque signed request bytes below;
    %% decoding the same outer frame again would add work but no trust check.
    target_request(Peer, Link, Request).

target_request(
  Peer, Link,
  Request = {submit, RequestId, RequestBytes, Signature, CursorBinding,
             Carrier}) ->
    Context = quod_trace:extract(Carrier),
    quod_trace:with_optional_span(
      Context, <<"client.goal.forwarded">>, server,
      #{'peer.key' => binary:encode_hex(Peer, lowercase)},
      fun() ->
          case quod_client_goal_target:prepare_forwarded(
                 RequestBytes, Signature, Peer, Link, CursorBinding) of
              {ok, {Evidence, Goal, Principal, Owner}} ->
                  send_submit_target_result(
                    Link, Request,
                    quod_client_goal_target:execute(
                      Evidence, Goal, Principal, Owner, CursorBinding));
              {error, Reason} ->
                  send_response(Link, preexecution_reply(RequestId, Reason))
          end
      end);
target_request(Peer, Link,
               Request = {cursor, _RequestId, CursorId, Command}) ->
    Result = cursor_target_result(
               quod_client_cursor:command_forwarded(
                 Peer, Link, CursorId, Command)),
    send_result(Link, Request, Result).

cursor_target_result({ok, Evidence, Raw}) ->
    quod_client_result:normalize(Evidence, Raw);
cursor_target_result({error, not_found}) -> {error, cursor_not_found};
cursor_target_result({error, not_ready}) -> {error, cursor_not_ready};
cursor_target_result({error, busy}) -> {error, cursor_busy};
cursor_target_result({error, _}) -> {error, proof_unavailable}.

send_submit_target_result(Link, Request, Result) ->
    case submit_target_result(Request, Result) of
        {result, PublicResult} -> send_result(Link, Request, PublicResult);
        {response, Response} -> send_response(Link, Response)
    end.

%% Every documented target-execution outcome selects one reply. The three
%% availability outcomes remain retryable route refusals; an outcome conflict
%% remains its wire-level terminal error; all other proof results were already
%% normalized by the target executor.
submit_target_result(
  _Request,
  {ok, _Evidence, {normalized, Result}}) ->
    {result, Result};
submit_target_result(
  {submit, RequestId, _, _, _, _},
  {error, busy}) ->
    {response, {refused, RequestId, busy}};
submit_target_result(
  {submit, RequestId, _, _, _, _},
  {error, rebuilding}) ->
    {response, {refused, RequestId, not_ready}};
submit_target_result(
  {submit, RequestId, _, _, _, _},
  {error, client_cursor_unavailable}) ->
    {response, {refused, RequestId, not_ready}};
submit_target_result(
  {submit, RequestId, _, _, _, _},
  {error, operation_conflict}) ->
    {response, {error, RequestId, operation_conflict}}.

send_result(Link, {submit, RequestId, _, _, none, _}, Result) ->
    send_result_response(Link, {result, RequestId, Result});
send_result(Link, {submit, RequestId, _, _, CursorId, _}, Result) ->
    send_result_response(
      Link, {cursor_result, RequestId, CursorId, Result});
send_result(Link, {cursor, RequestId, CursorId, _}, Result) ->
    send_result_response(
      Link, {cursor_result, RequestId, CursorId, Result}).

send_result_response(Link, {Kind, RequestId, Result}) ->
    case quod_client_result:encode(Result) of
        {ok, Blob} -> send_response(Link, {Kind, RequestId, Blob});
        {error, _} ->
            {ok, Blob} = quod_client_result:encode(
                           {error, result_too_large}),
            send_response(Link, {Kind, RequestId, Blob})
    end;
send_result_response(Link, {Kind, RequestId, CursorId, Result}) ->
    case quod_client_result:encode(Result) of
        {ok, Blob} ->
            send_response(Link, {Kind, RequestId, CursorId, Blob});
        {error, _} ->
            {ok, Blob} = quod_client_result:encode(
                           {error, result_too_large}),
            send_response(Link, {Kind, RequestId, CursorId, Blob})
    end.

preexecution_reply(RequestId, client_goal_rate_limited) ->
    {refused, RequestId, rate_limited};
preexecution_reply(RequestId, client_goal_busy) ->
    {refused, RequestId, busy};
preexecution_reply(RequestId, client_auth_unavailable) ->
    {refused, RequestId, not_ready};
preexecution_reply(RequestId, signed_target_unavailable) ->
    {refused, RequestId, not_ready};
preexecution_reply(RequestId, client_symbol_budget_exhausted) ->
    {refused, RequestId, busy};
preexecution_reply(RequestId, atom_limit) ->
    {refused, RequestId, busy};
preexecution_reply(RequestId, invalid_signature) ->
    {error, RequestId, invalid_signature};
preexecution_reply(RequestId, wrong_network) ->
    {error, RequestId, wrong_network};
preexecution_reply(RequestId, wrong_target) ->
    {error, RequestId, wrong_target};
preexecution_reply(RequestId, expired) ->
    {error, RequestId, expired};
preexecution_reply(RequestId, _Reason) ->
    {error, RequestId, invalid_request}.

send_response(Link, Response) ->
    case quod_client_goal_endpoint:encode_response(Response) of
        {ok, Frame} -> quod_link:send_ordered(Link, Frame);
        {error, _} -> ok
    end.

route_result(_Worker, none, _Result, _Peer, _Link, _Expires, S) ->
    {ok, S};
route_result(Worker, RouteKey, Result, Peer, Link, ExpiresMs, S0) ->
    case maps:get(RouteKey, S0#s.routes, undefined) of
        #{state := pending, busy := Worker} ->
            case Result of
                {solution, CursorId, _, _}
                  when CursorId =:= element(2, RouteKey) ->
                    {ok, install_route(
                           RouteKey, Peer, Link, ExpiresMs, S0)};
                _ -> {ok, drop_route(RouteKey, S0)}
            end;
        #{state := active, busy := Worker} ->
            case Result of
                {solution, CursorId, _, _}
                  when CursorId =:= element(2, RouteKey) ->
                    Route = maps:get(RouteKey, S0#s.routes),
                    {ok, S0#s{routes =
                                   (S0#s.routes)#{RouteKey =>
                                                       Route#{busy => none}}}};
                _ -> {ok, drop_route(RouteKey, S0)}
            end;
        _ -> {{error, unavailable}, S0}
    end.

install_route(RouteKey, Peer, Link, ExpiresMs, S0) ->
    Token = make_ref(),
    Delay = erlang:max(0, ExpiresMs - quod_time:now_ms()),
    Timer = erlang:send_after(Delay, self(), {route_expired, RouteKey, Token}),
    LinkMRef = monitor(process, Link),
    Pending = maps:get(RouteKey, S0#s.routes),
    Route = #{state => active, busy => none, peer => Peer,
              link => Link, link_mref => LinkMRef,
              expiry_timer => Timer, expiry_token => Token,
              expires_ms => ExpiresMs,
              evidence => maps:get(evidence, Pending)},
    S0#s{routes = (S0#s.routes)#{RouteKey => Route}}.

drop_route(RouteKey, S0) ->
    case maps:take(RouteKey, S0#s.routes) of
        {Route, Routes1} ->
            cancel_route_timer(Route),
            demonitor_optional(maps:get(link_mref, Route, undefined)),
            S0#s{routes = Routes1};
        error -> S0
    end.

cancel_route_timer(#{expiry_timer := Timer}) ->
    _ = erlang:cancel_timer(Timer), ok;
cancel_route_timer(_Route) -> ok.

demonitor_optional(undefined) -> ok;
demonitor_optional(MRef) -> demonitor(MRef, [flush]), ok.

down(MRef, Pid, S0) ->
    case take_correlation(MRef, Pid, S0#s.correlations) of
        {ok, Corr, Correlations1} ->
            S1 = S0#s{correlations = Correlations1},
            cleanup_worker_route(Pid, maps:get(route_key, Corr), S1);
        error ->
            case maps:take(Pid, S0#s.inbound) of
                {#{mref := MRef}, Inbound1} -> S0#s{inbound = Inbound1};
                error -> drop_link_route(MRef, S0)
            end
    end.

take_correlation(MRef, Pid, Correlations) ->
    case [Id || {Id, #{worker := Worker, mref := Ref}}
                    <- maps:to_list(Correlations),
                Worker =:= Pid, Ref =:= MRef] of
        [Id] ->
            {Corr, Rest} = maps:take(Id, Correlations),
            {ok, Corr, Rest};
        _ -> error
    end.

cleanup_worker_route(_Worker, none, S) -> S;
cleanup_worker_route(Worker, RouteKey, S0) ->
    case maps:get(RouteKey, S0#s.routes, undefined) of
        #{state := pending, busy := Worker} -> drop_route(RouteKey, S0);
        #{state := active, busy := Worker} -> drop_route(RouteKey, S0);
        _ -> S0
    end.

drop_link_route(MRef, S0) ->
    case [Key || {Key, #{link_mref := Ref}} <- maps:to_list(S0#s.routes),
                 Ref =:= MRef] of
        [Key] -> drop_route(Key, S0);
        _ -> S0
    end.

request_id() -> crypto:strong_rand_bytes(
                  ?QUOD_CLIENT_GOAL_REQUEST_ID_BITS div 8).
