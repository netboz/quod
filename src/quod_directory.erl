-module(quod_directory).
-moduledoc """
Live ontology-route directory.

The directory is network-observed soft state: three protected ETS indexes owned
by this process, rebuilt after restart, and never written to consensus. Proof
workers call `resolve/1` / `directory_hosts/1` directly; those
read paths never call this gen_server and therefore remain available while its
mailbox is busy.

Signed fact-backed generations replace one node actor's complete public
descriptor set atomically. High-water marks outlive leased routes so a late
generation cannot resurrect an expired endpoint. Local private contacts are
derived from committed node-actor facts and never enter public answers.

When a writer turn makes a confirmed validator route usable for the exact
identity `{Namespace, GenesisAnchor}`, the owner publishes the bounded event
`{directory_route_available, Identity}` on the
`{directory_route, Identity}` property. The event carries no route or endpoint
data; subscribers always reread this one ordinary projection.
""".

-behaviour(gen_server).

-include("quod_directory_limits.hrl").

-export([start_link/0, start_link/1]).
-export([resolve/1, validator_routes/2, directory_hosts/1,
         install_generation/1, install_private_projection/1,
         expire/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(KEY, {directory, node}).
-define(ROUTES, quod_directory_routes).
-define(HIGHWATER, quod_directory_highwater).
-define(KNOWN, quod_directory_known).

-define(DEFAULT_EXPIRE_TICK_MS, 1000).
-record(s, {
    routes,
    highwater,
    known,
    ttl_ms = ?DIRECTORY_ROUTE_TTL_MS,
    expire_tick_ms = ?DEFAULT_EXPIRE_TICK_MS
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    start_link(application:get_env(quod, directory, #{})).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(quod_reg:via(?KEY), ?MODULE, Opts, []).

-doc """
Resolve `Namespace` from the local indexes.

Returns `unknown` only when the namespace has never been learned/configured.
`{known, []}` means it is known but every live route has expired. Route order
is deterministic by node key and endpoint.
""".
-spec resolve(binary()) -> unknown | {known, [map()]}.
resolve(Ns) when is_binary(Ns) ->
    try
        Now = quod_time:mono_ms(),
        Rows = ets:lookup(?ROUTES, Ns),
        Routes = lists:sort(
                   fun route_before/2,
                   lists:flatmap(
                     fun(Row) -> expand_route(Row, Now) end,
                     [Row || Row <- Rows, route_active(Row, Now)])),
        case Routes of
            [] ->
                case ets:member(?KNOWN, Ns) of
                    true -> {known, []};
                    false -> unknown
                end;
            _ ->
                {known, Routes}
        end
    catch
        error:badarg -> unknown
    end;
resolve(_) ->
    unknown.

-doc """
Return confirmed validator routes for one exact anchored ontology identity.

Any simultaneously advertised confirmed validator anchor conflict fails the
whole lookup.  Callers must not filter the desired anchor first: doing so
would let a split directory view silently choose one of two incompatible
ontologies with the same namespace.
""".
-spec validator_routes(binary(), <<_:256>>) ->
          {ok, [map()]} | {error, unavailable | anchor_conflict}.
validator_routes(Ns, <<_:256>> = Anchor) when is_binary(Ns) ->
    case resolve(Ns) of
        {known, Routes} ->
            Eligible =
                [Route
                 || #{status := confirmed, role := validator,
                      node_key := <<_:256>>,
                      genesis_anchor := <<_:256>>} = Route <- Routes],
            Anchors = lists:usort(
                        [A || #{genesis_anchor := A} <- Eligible]),
            case Anchors of
                [Anchor] ->
                    {ok, [R || #{genesis_anchor := A} = R <- Eligible,
                               A =:= Anchor]};
                [] ->
                    {error, unavailable};
                _ ->
                    {error, anchor_conflict}
            end;
        _ ->
            {error, unavailable}
    end;
validator_routes(_Ns, _Anchor) ->
    {error, unavailable}.

-doc """
Active public system hosts for the ground namespace, in deterministic key order.
Private seeds are deliberately excluded.
""".
-spec directory_hosts(binary()) ->
          [{<<_:256>>, binary(), term(), inet:port_number()}].
directory_hosts(Ns) when is_binary(Ns) ->
    try
        Now = quod_time:mono_ms(),
        [{GenesisAnchor, NodeKey, Host, Port}
         || {NodeKey, GenesisAnchor, Host, Port} <-
                lists:sort(
                  [{NodeKey, GenesisAnchor, Host, Port}
                   || {_Ns, system, _RouteKey, NodeKey,
                       {Host, Port}, confirmed,
                       GenesisAnchor, _Role, Expiry, _Epoch, _Sequence}
                          <- ets:lookup(?ROUTES, Ns),
                      Expiry > Now])]
    catch
        error:badarg -> []
    end;
directory_hosts(_) ->
    [].


-doc "Expire system routes at or before `Now`; high-water/known indexes remain.".
-spec expire(integer()) -> ok.
expire(Now) ->
    gen_server:call(quod_reg:via(?KEY), {expire, Now}).

-spec stats() -> map().
stats() ->
    try #{routes => ets:info(?ROUTES, size),
          highwater => ets:info(?HIGHWATER, size),
          known => ets:info(?KNOWN, size)}
    catch error:badarg -> #{routes => 0, highwater => 0, known => 0}
    end.

-doc "Atomically install one already-certified complete directory generation.".
-spec install_generation(map()) -> {ok, integer()} | {error, term()}.
install_generation(Generation) when is_map(Generation) ->
    gen_server:call(
      quod_reg:via(?KEY),
      {install_generation, Generation, quod_time:mono_ms()});
install_generation(_) -> {error, bad_generation}.

-doc "Replace the local committed private-contact projection atomically.".
-spec install_private_projection([map()]) -> ok | {error, term()}.
install_private_projection(Rows) when is_list(Rows) ->
    gen_server:call(quod_reg:via(?KEY), {install_private_projection, Rows});
install_private_projection(_) -> {error, bad_private_projection}.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    case config(Opts) of
        {ok, #{ttl_ms := Ttl, expire_tick_ms := Tick}} ->
            Routes = ets:new(?ROUTES, [named_table, protected, duplicate_bag,
                                       {read_concurrency, true}]),
            Highwater = ets:new(?HIGHWATER, [named_table, protected, set,
                                             {read_concurrency, true}]),
            Known = ets:new(?KNOWN, [named_table, protected, set,
                                     {read_concurrency, true}]),
            _ = erlang:send_after(Tick, self(), expire_tick),
            {ok, #s{routes = Routes, highwater = Highwater, known = Known,
                    ttl_ms = Ttl, expire_tick_ms = Tick}};
        {error, Reason} -> {stop, {bad_directory_config, Reason}}
    end.

handle_call({install_generation, Generation, Now}, _From, S) ->
    case accept_generation(Generation, Now, S) of
        {ok, Expiry, S1} -> {reply, {ok, Expiry}, S1};
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call({install_private_projection, Rows}, _From, S) ->
    case replace_private_projection(Rows, S) of
        {ok, S1} -> {reply, ok, S1};
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call({expire, Now}, _From, S) when is_integer(Now) ->
    {reply, ok, expire_routes(Now, S)};
handle_call(_Request, _From, S) ->
    {reply, {error, unknown_call}, S}.


handle_cast(_Message, S) ->
    {noreply, S}.

handle_info(expire_tick, S = #s{expire_tick_ms = Tick}) ->
    _ = erlang:send_after(Tick, self(), expire_tick),
    {noreply, expire_routes(quod_time:mono_ms(), S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%%%===================================================================
%%% authenticated generations
%%%===================================================================

accept_generation(Generation, Now, S = #s{highwater = Highwater}) ->
    try
        Author = quod_directory_generation:author(Generation),
        NodeKey = quod_directory_generation:node_key(Generation),
        Endpoint = quod_directory_generation:endpoint(Generation),
        Epoch = quod_directory_generation:epoch(Generation),
        Sequence = quod_directory_generation:generation(Generation),
        Hosted0 = quod_directory_generation:hosted(Generation),
        Hosted = [{Ns, Anchor, Role}
                  || {Ns, Anchor, Role, _Source} <- Hosted0],
        case highwater_newer(Author, Epoch, Sequence, Highwater) of
            false -> {error, stale_generation};
            true ->
                OldRows = generation_rows_for_author(Author, S#s.routes),
                {S1, Expiry} = install_generation_now(
                                 Author, NodeKey, Endpoint, Hosted, Epoch,
                                 Sequence, Now, OldRows, S),
                {ok, Expiry, S1}
        end
    catch _:_ -> {error, bad_generation}
    end.

install_generation_now(Author, NodeKey, Endpoint, Hosted, Epoch, Sequence,
                       Now, OldRows,
                       S = #s{routes = Routes, highwater = Highwater,
                              known = Known, ttl_ms = Ttl}) ->
    Namespaces = lists:usort(
                   affected_namespaces(Hosted, OldRows) ++
                   private_namespaces_for_author(Author, Routes)),
    Before = usable_identities(Namespaces, Routes, Now),
    Expiry = Now + Ttl,
    true = ets:insert(
             Routes,
             [{Ns, system, {generation, Author}, NodeKey, Endpoint,
               confirmed, Anchor, Role, Expiry, Epoch, Sequence}
              || {Ns, Anchor, Role} <- Hosted]),
    lists:foreach(fun(Row) -> true = ets:delete_object(Routes, Row) end,
                  OldRows),
    true = ets:insert(Known, [{Ns} || {Ns, _, _} <- Hosted]),
    true = ets:insert(Highwater, {Author, Epoch, Sequence}),
    notify_usable_identities(Namespaces, Hosted, Before, Now, S),
    {S, Expiry}.

generation_rows_for_author(Author, Routes) ->
    ets:match_object(
      Routes,
      {'_', system, {generation, Author}, '_', '_', '_', '_', '_',
       '_', '_', '_'}).

highwater_newer(Author, Epoch, Sequence, Highwater) ->
    case ets:lookup(Highwater, Author) of
        [] -> true;
        [{Author, OldEpoch, OldSequence}] ->
            Epoch > OldEpoch orelse
                (Epoch =:= OldEpoch andalso Sequence > OldSequence)
    end.

replace_private_projection(Rows, S = #s{routes = Routes, known = Known}) ->
    case normalize_private_projection(Rows, []) of
        {ok, Normalized} ->
            Old = ets:match_object(
                    Routes, {'_', private, '_', '_', '_', '_', '_', '_',
                             '_', '_', '_'}),
            New = [{Ns, private, {private, HostRef}, HostRef, undefined,
                    confirmed, Anchor, validator, infinity, 0, 0}
                   || #{namespace := Ns, anchor := Anchor,
                        host_node_ref := HostRef} <- Normalized],
            Namespaces = lists:usort(
                           [Ns || {Ns, private, _, _, _, _, _, _, _, _, _}
                                      <- Old ++ New]),
            Before = usable_identities(Namespaces, Routes,
                                       quod_time:mono_ms()),
            true = ets:insert(Routes, New),
            lists:foreach(fun(Row) -> true = ets:delete_object(Routes, Row) end,
                          Old -- New),
            true = ets:insert(Known,
                              [{maps:get(namespace, Row)} || Row <- Normalized]),
            notify_usable_identities(Namespaces, [], Before,
                                     quod_time:mono_ms(), S),
            {ok, S};
        error -> {error, bad_private_projection}
    end.

normalize_private_projection([], Acc) ->
    {ok, lists:usort(Acc)};
normalize_private_projection(
  [#{namespace := Ns, anchor := <<_:256>>,
     host_node_ref := {agent_instance_ref, HostNs, <<_:256>>, _}} = Row | Rest],
  Acc) when is_binary(Ns), is_binary(HostNs) ->
    normalize_private_projection(Rest, [Row | Acc]);
normalize_private_projection(_, _) -> error.

%%%===================================================================
%%% expiry + readers
%%%===================================================================

expire_routes(Now, S = #s{routes = Routes}) ->
    Expiring = ets:select(
                 Routes,
                 [{{'_', system, '_', '_', '_', '_', '_', '_', '$1',
                    '_', '_'},
                   [{'=<', '$1', Now}], ['$_']}]),
    Namespaces = lists:usort([Ns || {Ns, system, _, _, _, _, _, _, _, _, _}
                                        <- Expiring]),
    %% At this mailbox turn the selected rows are already inactive by wall
    %% clock, although they still make the raw route set ambiguous. Compare
    %% the pre-deletion route set with the post-deletion live view so expiry
    %% itself emits the edge for an identity released from an anchor conflict.
    Before = usable_identities_before_expiry(Namespaces, Routes),
    _ = ets:select_delete(
          Routes,
          [{{'_', system, '_', '_', '_', '_', '_', '_', '$1', '_', '_'},
            [{'=<', '$1', Now}], [true]}]),
    notify_usable_identities(Namespaces, [], Before, Now, S),
    S.

affected_namespaces(Hosted, OldRows) ->
    lists:usort(
      [Ns || {Ns, _Anchor, _Role} <- Hosted] ++
      [Ns || {Ns, system, _, _, _, _, _, _, _, _, _} <- OldRows]).

private_namespaces_for_author({node_actor, Blob}, Routes) ->
    case quod_agent_ref:decode(Blob) of
        {ok, #{reference := HostRef}} ->
            [Ns || {Ns, private, {private, Ref}, Ref, undefined, confirmed,
                    _Anchor, validator, infinity, 0, 0}
                       <- ets:tab2list(Routes), Ref =:= HostRef];
        _ -> []
    end;
private_namespaces_for_author(_, _Routes) -> [].

notify_usable_identities(Namespaces, Installed, Before, Now,
                         #s{routes = Routes}) ->
    After = usable_identities(Namespaces, Routes, Now),
    InstalledValidators =
        lists:usort([{Ns, Anchor}
                     || {Ns, Anchor, validator} <- Installed]),
    NewlyAvailable = ordsets:subtract(After, Before),
    Notify = ordsets:intersection(
               After, ordsets:union(InstalledValidators, NewlyAvailable)),
    lists:foreach(fun publish_route_available/1, Notify),
    ok.


publish_route_available(Identity) ->
    _ = quod_reg:publish(
          {directory_route, Identity},
          {directory_route_available, Identity}),
    ok.

usable_identities(Namespaces, Routes, Now) ->
    lists:flatmap(
      fun(Ns) ->
          Anchors = lists:usort(
                      [Anchor || Row <- ets:lookup(Routes, Ns),
                                 route_active(Row, Now),
                                 #{status := confirmed, role := validator,
                                   genesis_anchor := <<_:256>> = Anchor}
                                     <- expand_route(Row, Now)]),
          case Anchors of
              [Anchor] -> [{Ns, Anchor}];
              _ -> []
          end
      end, Namespaces).

usable_identities_before_expiry(Namespaces, Routes) ->
    lists:flatmap(
      fun(Ns) ->
          Anchors = lists:usort(
                      [Anchor
                       || {_Ns, _Scope, _RouteKey, <<_:256>>, _Endpoint,
                           confirmed, <<_:256>> = Anchor, validator,
                           _Expiry, _Epoch, _Sequence}
                              <- ets:lookup(Routes, Ns)]),
          case Anchors of
              [Anchor] -> [{Ns, Anchor}];
              _ -> []
          end
      end, Namespaces).

route_active({_Ns, system, _Key, _NodeKey, _Endpoint, _Status,
              _Anchor, _Role, Expiry, _Epoch, _Sequence}, Now) ->
    Expiry > Now;
route_active({_Ns, private, _Key, _HostRef, undefined, confirmed,
              _Anchor, validator, infinity, 0, 0}, _Now) -> true.

expand_route({Ns, private, _Key,
              {agent_instance_ref, HostNs, HostAnchor, _} = HostRef,
              undefined, confirmed, Anchor, validator, infinity, 0, 0}, Now) ->
    [#{namespace => Ns, scope => private, node_key => NodeKey,
       endpoint => Endpoint, status => confirmed,
       genesis_anchor => Anchor, role => validator, expiry => infinity,
       epoch => Epoch, sequence => Sequence, host_node_ref => HostRef}
     || {HostNs0, system, _RouteKey, NodeKey, Endpoint, confirmed,
         HostAnchor0, validator, _Expiry, Epoch, Sequence} = Row
            <- ets:lookup(?ROUTES, HostNs),
        HostNs0 =:= HostNs, HostAnchor0 =:= HostAnchor,
        route_active(Row, Now)];
expand_route(Row, _Now) -> [route_map(Row)].

route_map({Ns, Scope, _RouteKey, NodeKey, Endpoint, Status,
           GenesisAnchor, Role, Expiry, Epoch, Sequence}) ->
    #{namespace => Ns, scope => Scope, node_key => NodeKey,
      endpoint => Endpoint, status => Status,
      genesis_anchor => GenesisAnchor, role => Role, expiry => Expiry,
      epoch => Epoch, sequence => Sequence}.

route_before(A, B) ->
    route_order(A) < route_order(B).

route_order(#{scope := system, node_key := NodeKey, endpoint := Endpoint}) ->
    {1, NodeKey, Endpoint};
route_order(#{scope := private, node_key := NodeKey, endpoint := Endpoint}) ->
    {0, NodeKey, Endpoint}.

%%%===================================================================
%%% configuration
%%%===================================================================

config(Opts) when is_map(Opts) ->
    Ttl = maps:get(ttl_ms, Opts, ?DIRECTORY_ROUTE_TTL_MS),
    Tick = maps:get(expire_tick_ms, Opts, ?DEFAULT_EXPIRE_TICK_MS),
    case is_integer(Ttl) andalso Ttl > 0 andalso
         is_integer(Tick) andalso Tick > 0 of
        true -> {ok, #{ttl_ms => Ttl, expire_tick_ms => Tick}};
        false -> {error, bad_config}
    end;
config(_) -> {error, bad_config}.
