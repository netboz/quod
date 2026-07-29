-module(quod_directory).
-moduledoc """
Live ontology-route directory.

The directory is network-observed soft state: three protected ETS indexes owned
by this process, rebuilt after restart, and never written to consensus. Proof
workers and ask workers call `resolve/1` / `directory_hosts/1` directly; those
read paths never call this gen_server and therefore remain available while its
mailbox is busy.

System advertisements replace one node's complete current namespace set
without exposing an empty intermediate state to lock-free readers. The writer
enforces exact per-namespace allowlists, strict epoch/sequence freshness,
expiry and hard capacity bounds. High-water marks outlive routes so a late
renewal cannot resurrect an expired endpoint.

Private direct seeds are local-only. They begin `provisional`, become
`confirmed` after the scoped TOFU transport exchange, take precedence over
system routes, and never appear through the Prolog-facing `directory_hosts/1`.
""".

-behaviour(gen_server).

-include("quod_directory_limits.hrl").

-export([start_link/0, start_link/1]).
-export([resolve/1, directory_hosts/1,
         add_direct_seed/2, confirm_direct_seed/3,
         install_record/5, expire/1, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(KEY, {directory, node}).
-define(ROUTES, quod_directory_routes).
-define(HIGHWATER, quod_directory_highwater).
-define(KNOWN, quod_directory_known).

-define(DEFAULT_RENEW_MIN_MS, 5000).
-define(DEFAULT_EXPIRE_TICK_MS, 1000).
-define(DEFAULT_MAX_ROUTES_PER_NS, 8).
-define(DEFAULT_MAX_ROUTES, 2048).
-record(s, {
    routes,
    highwater,
    known,
    allowlist = #{},
    allowed_keys = #{},
    ttl_ms = ?DIRECTORY_ROUTE_TTL_MS,
    renew_min_ms = ?DEFAULT_RENEW_MIN_MS,
    expire_tick_ms = ?DEFAULT_EXPIRE_TICK_MS,
    max_namespaces = ?DIRECTORY_MAX_NAMESPACES,
    max_routes_per_ns = ?DEFAULT_MAX_ROUTES_PER_NS,
    max_routes = ?DEFAULT_MAX_ROUTES,
    last_accept = #{}
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
is deterministic: confirmed direct, provisional direct, then system.
""".
-spec resolve(binary()) -> unknown | {known, [map()]}.
resolve(Ns) when is_binary(Ns) ->
    try
        Now = quod_time:mono_ms(),
        Rows = ets:lookup(?ROUTES, Ns),
        Routes = lists:sort(
                   fun route_before/2,
                   [route_map(Row) || Row <- Rows, route_active(Row, Now)]),
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
Active public system hosts for the ground namespace, in deterministic key order.
Private seeds are deliberately excluded.
""".
-spec directory_hosts(binary()) -> [{binary(), term(), inet:port_number()}].
directory_hosts(Ns) when is_binary(Ns) ->
    try
        Now = quod_time:mono_ms(),
        lists:sort(
          [{NodeKey, Host, Port}
           || {_Ns, system, _RouteKey, NodeKey, {Host, Port}, confirmed,
               Expiry, _Epoch, _Sequence} <- ets:lookup(?ROUTES, Ns),
              Expiry > Now])
    catch
        error:badarg -> []
    end;
directory_hosts(_) ->
    [].

-spec add_direct_seed(binary(), term()) -> ok | {error, term()}.
add_direct_seed(Ns, Endpoint) ->
    gen_server:call(quod_reg:via(?KEY), {add_direct_seed, Ns, Endpoint}).

-spec confirm_direct_seed(binary(), term(), binary()) -> ok | {error, term()}.
confirm_direct_seed(Ns, Endpoint, NodeKey) ->
    gen_server:call(
      quod_reg:via(?KEY), {confirm_direct_seed, Ns, Endpoint, NodeKey}).

-doc """
Install one authenticated node's complete current system-namespace set.
Signature/wire verification is performed by the control-plane decoder before
this call; this writer independently rechecks shape, exact allowlist,
freshness, rate and capacity before changing any index. The returned deadline
is the exact receiver-local lease expiry installed in the route table.
""".
-spec install_record(binary(), term(), [binary()], non_neg_integer(),
                     non_neg_integer()) ->
          {ok, integer()} | {error, term()}.
install_record(NodeKey, Endpoint, Namespaces, Epoch, Sequence) ->
    gen_server:call(
      quod_reg:via(?KEY),
      {install_record, NodeKey, Endpoint, Namespaces, Epoch, Sequence,
       quod_time:mono_ms()}).

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

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    case config(Opts) of
        {ok, Cfg} ->
            Routes = ets:new(
                       ?ROUTES, [named_table, protected, duplicate_bag,
                                 {read_concurrency, true}]),
            Highwater = ets:new(
                           ?HIGHWATER, [named_table, protected, set,
                                        {read_concurrency, true}]),
            Known = ets:new(
                      ?KNOWN, [named_table, protected, set,
                               {read_concurrency, true}]),
            Tick = maps:get(expire_tick_ms, Cfg),
            _ = erlang:send_after(Tick, self(), expire_tick),
            S0 = #s{routes = Routes, highwater = Highwater, known = Known,
                    allowlist = maps:get(allowlist, Cfg),
                    allowed_keys = maps:get(allowed_keys, Cfg),
                    ttl_ms = maps:get(ttl_ms, Cfg),
                    renew_min_ms = maps:get(renew_min_ms, Cfg),
                    expire_tick_ms = Tick,
                    max_namespaces = maps:get(max_namespaces, Cfg),
                    max_routes_per_ns = maps:get(max_routes_per_ns, Cfg),
                    max_routes = maps:get(max_routes, Cfg)},
            case install_direct_seeds(maps:get(direct_seeds, Cfg), S0) of
                {ok, S1} -> {ok, S1};
                {error, Reason} ->
                    {stop, {bad_directory_direct_seeds, Reason}}
            end;
        {error, Reason} ->
            {stop, {bad_directory_config, Reason}}
    end.

handle_call({add_direct_seed, Ns, Endpoint}, _From, S) ->
    case add_seed(Ns, Endpoint, S) of
        {ok, S1} -> {reply, ok, S1};
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call({confirm_direct_seed, Ns, Endpoint, NodeKey}, _From, S) ->
    case confirm_seed(Ns, Endpoint, NodeKey, S) of
        {ok, S1} -> {reply, ok, S1};
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call({install_record, NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now},
            _From, S) ->
    case accept_record(NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now, S) of
        {ok, Expiry, S1} -> {reply, {ok, Expiry}, S1};
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
%%% private seeds
%%%===================================================================

add_seed(Ns, Endpoint, S = #s{routes = Routes, known = Known}) ->
    case {quod_directory_auth:valid_namespace(Ns),
          quod_quic:valid_endpoint(Endpoint)} of
        {true, true} ->
            RouteKey = {direct_seed, Endpoint},
            case has_route(Routes, Ns, direct, RouteKey) of
                true ->
                    {ok, S};
                false ->
                    case capacity_for_seed(Ns, S) of
                        ok ->
                            true = ets:insert(
                                     Routes,
                                     {Ns, direct, RouteKey, undefined, Endpoint,
                                      provisional, infinity, 0, 0}),
                            true = ets:insert(Known, {Ns}),
                            {ok, S};
                        {error, _} = Error ->
                            Error
                    end
            end;
        _ ->
            {error, bad_seed}
    end.

confirm_seed(Ns, Endpoint, NodeKey, S = #s{routes = Routes})
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32 ->
    RouteKey = {direct_seed, Endpoint},
    case ets:match_object(
           Routes,
           {Ns, direct, RouteKey, '_', Endpoint, '_', infinity, '_', '_'}) of
        [OldRow] ->
            %% Keep the seed continuously visible to lock-free readers while
            %% promoting it. The confirmed row sorts before the provisional
            %% row during the tiny overlap.
            true = ets:insert(
                     Routes,
                     {Ns, direct, RouteKey, NodeKey, Endpoint,
                      confirmed, infinity, 0, 0}),
            true = ets:delete_object(Routes, OldRow),
            {ok, S};
        [] ->
            {error, unknown_seed}
    end;
confirm_seed(_Ns, _Endpoint, _NodeKey, _S) ->
    {error, bad_node_key}.

capacity_for_seed(Ns, #s{routes = Routes, known = Known,
                         max_routes_per_ns = PerNs, max_routes = Max}) ->
    case {ets:info(Routes, size) < Max,
          length(ets:lookup(Routes, Ns)) < PerNs,
          ets:member(Known, Ns) orelse ets:info(Known, size) < Max} of
        {true, true, true} -> ok;
        {false, _, _} -> {error, directory_full};
        {_, false, _} -> {error, namespace_full};
        {_, _, false} -> {error, directory_full}
    end.

%%%===================================================================
%%% authenticated system records
%%%===================================================================

accept_record(NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now, S) ->
    case record_shape(NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now, S) of
        {ok, Unique} ->
            case preflight_record(NodeKey, Unique, Epoch, Sequence, Now, S) of
                {ok, OldRows} ->
                    {S1, Expiry} = install_record_now(
                                     NodeKey, Endpoint, Unique, Epoch,
                                     Sequence, Now, OldRows, S),
                    {ok, Expiry, S1};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

record_shape(NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now,
             #s{max_namespaces = MaxNamespaces})
  when is_binary(NodeKey), byte_size(NodeKey) =:= 32,
       is_integer(Epoch), Epoch >= 0,
       is_integer(Sequence), Sequence >= 0, is_integer(Now) ->
    case {quod_quic:valid_endpoint(Endpoint),
          quod_directory_auth:validate_namespaces(
            Namespaces, MaxNamespaces)} of
        {true, {ok, Unique}} -> {ok, Unique};
        _ -> {error, bad_record}
    end;
record_shape(_NodeKey, _Endpoint, _Namespaces, _Epoch, _Sequence, _Now, _S) ->
    {error, bad_record}.

preflight_record(NodeKey, Namespaces, Epoch, Sequence, Now,
                 S = #s{allowlist = Allowlist, highwater = Highwater,
                        allowed_keys = AllowedKeys,
                        last_accept = LastAccept, renew_min_ms = MinRenew,
                        max_routes = MaxRoutes, known = Known}) ->
    Authorized =
        case Namespaces of
            [] -> maps:is_key(NodeKey, AllowedKeys) orelse
                      ets:member(Highwater, NodeKey);
            _ -> lists:all(
                   fun(Ns) ->
                       quod_directory_auth:allowed(NodeKey, Ns, Allowlist)
                   end, Namespaces)
        end,
    case Authorized of
        false ->
            {error, not_allowed};
        true ->
            case highwater_newer(NodeKey, Epoch, Sequence, Highwater) of
                false ->
                    {error, stale_record};
                true ->
                    case maps:get(NodeKey, LastAccept, undefined) of
                        Last when is_integer(Last), Now - Last < MinRenew ->
                            {error, rate_limited};
                        _ ->
                            OldRows = system_rows_for_node(NodeKey, S#s.routes),
                            RouteCount = ets:info(S#s.routes, size) - length(OldRows)
                                         + length(Namespaces),
                            NewKnown =
                                length([Ns || Ns <- Namespaces,
                                             not ets:member(Known, Ns)]),
                            case {RouteCount =< MaxRoutes,
                                  ets:info(Known, size) + NewKnown =< MaxRoutes,
                                  highwater_capacity(NodeKey, Highwater, MaxRoutes),
                                  namespaces_have_capacity(
                                    Namespaces, NodeKey, S)} of
                                {true, true, true, true} -> {ok, OldRows};
                                {_, _, _, false} -> {error, namespace_full};
                                _ -> {error, directory_full}
                            end
                    end
            end
    end.

install_record_now(NodeKey, Endpoint, Namespaces, Epoch, Sequence, Now, OldRows,
                   S = #s{routes = Routes, highwater = Highwater, known = Known,
                          ttl_ms = Ttl, last_accept = LastAccept}) ->
    Expiry = Now + Ttl,
    %% Readers access ETS without crossing this process. Publish the complete
    %% replacement first, then remove the exact old generation, so a concurrent
    %% read can see a harmless overlap but never a renewal-induced route gap.
    true = ets:insert(
             Routes,
             [{Ns, system, {system, NodeKey}, NodeKey, Endpoint,
               confirmed, Expiry, Epoch, Sequence}
              || Ns <- Namespaces]),
    lists:foreach(fun(Row) -> true = ets:delete_object(Routes, Row) end,
                  OldRows),
    true = ets:insert(Known, [{Ns} || Ns <- Namespaces]),
    true = ets:insert(Highwater, {NodeKey, Epoch, Sequence}),
    {S#s{last_accept = LastAccept#{NodeKey => Now}}, Expiry}.

highwater_newer(NodeKey, Epoch, Sequence, Highwater) ->
    case ets:lookup(Highwater, NodeKey) of
        [] -> true;
        [{NodeKey, OldEpoch, OldSequence}] ->
            Epoch > OldEpoch orelse
                (Epoch =:= OldEpoch andalso Sequence > OldSequence)
    end.

highwater_capacity(NodeKey, Highwater, Max) ->
    ets:member(Highwater, NodeKey) orelse ets:info(Highwater, size) < Max.

namespaces_have_capacity(Namespaces, NodeKey,
                         #s{routes = Routes, max_routes_per_ns = Max}) ->
    lists:all(
      fun(Ns) ->
          Rows = ets:lookup(Routes, Ns),
          Existing = length(
                       [ok || {_Ns, system, _Key, K, _Endpoint, _Status,
                                _Expiry, _Epoch, _Sequence} <- Rows,
                              K =:= NodeKey]),
          length(Rows) - Existing + 1 =< Max
      end, Namespaces).

system_rows_for_node(NodeKey, Routes) ->
    ets:match_object(
      Routes,
      {'_', system, {system, NodeKey}, NodeKey, '_', '_', '_', '_', '_'}).

%%%===================================================================
%%% expiry + direct readers
%%%===================================================================

expire_routes(Now, S = #s{routes = Routes}) ->
    _ = ets:select_delete(
          Routes,
          [{{'_', system, '_', '_', '_', '_', '$1', '_', '_'},
            [{'=<', '$1', Now}], [true]}]),
    S.

route_active({_Ns, direct, _Key, _NodeKey, _Endpoint, _Status,
              infinity, _Epoch, _Sequence}, _Now) ->
    true;
route_active({_Ns, system, _Key, _NodeKey, _Endpoint, _Status,
              Expiry, _Epoch, _Sequence}, Now) ->
    Expiry > Now.

route_map({Ns, Scope, _RouteKey, NodeKey, Endpoint, Status,
           Expiry, Epoch, Sequence}) ->
    #{namespace => Ns, scope => Scope, node_key => NodeKey,
      endpoint => Endpoint, status => Status, expiry => Expiry,
      epoch => Epoch, sequence => Sequence}.

route_before(A, B) ->
    route_order(A) < route_order(B).

route_order(#{scope := direct, status := confirmed, endpoint := Endpoint}) ->
    {0, Endpoint};
route_order(#{scope := direct, status := provisional, endpoint := Endpoint}) ->
    {1, Endpoint};
route_order(#{scope := system, node_key := NodeKey, endpoint := Endpoint}) ->
    {2, NodeKey, Endpoint}.

has_route(Routes, Ns, Scope, RouteKey) ->
    ets:match_object(
      Routes, {Ns, Scope, RouteKey, '_', '_', '_', '_', '_', '_'}) =/= [].

%%%===================================================================
%%% configuration
%%%===================================================================

config(Opts) ->
    case {quod_directory_auth:normalize_allowlist(
            maps:get(allowlist, Opts, #{})),
          normalize_direct_seeds(maps:get(direct_seeds, Opts, #{}))} of
        {{ok, Allowlist}, {ok, DirectSeeds}} ->
            AllowedKeys = quod_directory_auth:node_key_index(Allowlist),
            Cfg = #{allowlist => Allowlist,
                    allowed_keys => AllowedKeys,
                    direct_seeds => DirectSeeds,
                    ttl_ms =>
                        maps:get(ttl_ms, Opts, ?DIRECTORY_ROUTE_TTL_MS),
                    renew_min_ms =>
                        maps:get(renew_min_ms, Opts, ?DEFAULT_RENEW_MIN_MS),
                    expire_tick_ms =>
                        maps:get(expire_tick_ms, Opts, ?DEFAULT_EXPIRE_TICK_MS),
                    max_namespaces =>
                        maps:get(max_namespaces, Opts,
                                 ?DIRECTORY_MAX_NAMESPACES),
                    max_routes_per_ns =>
                        maps:get(max_routes_per_ns, Opts,
                                 ?DEFAULT_MAX_ROUTES_PER_NS),
                    max_routes =>
                        maps:get(max_routes, Opts, ?DEFAULT_MAX_ROUTES)},
            case valid_config(Cfg) of
                true -> {ok, Cfg};
                false -> {error, bad_limits}
            end;
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error
    end.

valid_config(#{allowlist := Allowlist, allowed_keys := AllowedKeys,
               direct_seeds := DirectSeeds,
               ttl_ms := Ttl, renew_min_ms := MinRenew,
               expire_tick_ms := Tick, max_namespaces := MaxNs,
               max_routes_per_ns := PerNs, max_routes := Max}) ->
    lists:all(fun(N) -> is_integer(N) andalso N > 0 end,
              [Ttl, MinRenew, Tick, MaxNs, PerNs, Max]) andalso
        MaxNs =< ?DIRECTORY_MAX_NAMESPACES andalso
        PerNs =< ?DEFAULT_MAX_ROUTES_PER_NS andalso
        Max =< ?DEFAULT_MAX_ROUTES andalso
        map_size(Allowlist) =< Max andalso
        map_size(AllowedKeys) =< Max andalso
        direct_seed_count(DirectSeeds) =< Max andalso
        lists:all(
          fun(Endpoints) -> length(Endpoints) =< PerNs end,
          maps:values(DirectSeeds)).

normalize_direct_seeds(Seeds) when is_map(Seeds) ->
    try
        Pairs =
            [{Ns, lists:usort(Endpoints)}
             || {Ns, Endpoints} <- maps:to_list(Seeds),
                quod_directory_auth:valid_namespace(Ns),
                is_list(Endpoints),
                lists:all(fun quod_quic:valid_endpoint/1, Endpoints)],
        case length(Pairs) =:= map_size(Seeds) of
            true -> {ok, maps:from_list(Pairs)};
            false -> {error, bad_direct_seeds}
        end
    catch
        _:_ -> {error, bad_direct_seeds}
    end;
normalize_direct_seeds(_) ->
    {error, bad_direct_seeds}.

direct_seed_count(DirectSeeds) ->
    lists:sum([length(Endpoints) || Endpoints <- maps:values(DirectSeeds)]).

install_direct_seeds(DirectSeeds, S) ->
    lists:foldl(
      fun({Ns, Endpoint}, {ok, Acc}) ->
              add_seed(Ns, Endpoint, Acc);
         (_Seed, {error, _} = Error) ->
              Error
      end,
      {ok, S},
      [{Ns, Endpoint}
       || {Ns, Endpoints} <- maps:to_list(DirectSeeds),
          Endpoint <- Endpoints]).
