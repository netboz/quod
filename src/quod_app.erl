-module(quod_app).
-moduledoc """
quod application entry point.

Maps deployment environment variables onto the application config so a node can
be configured from its orchestrator (Nomad, compose, ...) without a custom
`sys.config`:

| env var          | effect                                                        |
| ---------------- | ------------------------------------------------------------- |
| `QUOD_PORT`      | QUIC `listen_port` (and the port of this node's `node_id`)    |
| `QUOD_NODE_IP`   | sets `node_id = {QUOD_NODE_IP, QUOD_PORT}` — the dialable id  |
| `QUOD_NAMESPACE` | ontology namespace to join on boot                            |
| `QUOD_SEEDS`     | space/comma-separated `ip:port` bootstrap peers               |

`node_id` MUST be the address peers dial this node at (see `m:quod_brahms`), so
in a cluster it is the node's own IP and the static listener port. With no env
vars set the node behaves exactly as before (loopback defaults, no auto-join).
""".

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = apply_env(),
    {ok, Sup} = quod_sup:start_link(),
    ok = maybe_join(),
    {ok, Sup}.

stop(_State) ->
    ok.

%% --- env -> config (must run BEFORE the transport starts) ----------------

apply_env() ->
    Port = env_int("QUOD_PORT", application:get_env(quod, listen_port, 14567)),
    application:set_env(quod, listen_port, Port),
    case os:getenv("QUOD_NODE_IP") of
        false -> ok;
        ""    -> ok;
        IP    -> application:set_env(quod, node_id, {IP, Port})
    end,
    ok.

%% --- optional namespace join (AFTER the supervisor is up) ----------------

maybe_join() ->
    case os:getenv("QUOD_NAMESPACE") of
        false -> ok;
        ""    -> ok;
        NsStr ->
            Ns    = list_to_binary(NsStr),
            Self  = application:get_env(quod, node_id, default_node_id()),
            Seeds = parse_seeds(os:getenv("QUOD_SEEDS")),
            case quod_brahms:start_namespace(Ns, #{node_id => Self, seed_peers => Seeds}) of
                {ok, _} ->
                    logger:info("quod: joined namespace ~s as ~p (~b seed(s))",
                                [NsStr, Self, length(Seeds)]);
                Error ->
                    logger:error("quod: could not join namespace ~s: ~p", [NsStr, Error])
            end,
            ok
    end.

default_node_id() ->
    {"127.0.0.1", application:get_env(quod, listen_port, 14567)}.

%% --- helpers -------------------------------------------------------------

%% "1.2.3.4:5678 5.6.7.8:5678" (or comma/newline separated) -> [{Host, Port}]
parse_seeds(false) -> [];
parse_seeds(Str)   -> lists:filtermap(fun parse_seed/1, string:lexemes(Str, " ,\t\n")).

parse_seed(Tok) ->
    case string:split(Tok, ":", trailing) of
        [Host, PortStr] when Host =/= "" ->
            case string:to_integer(PortStr) of
                {Port, ""} when Port > 0 -> {true, {Host, Port}};
                _                        -> false
            end;
        _ ->
            false
    end.

env_int(Var, Default) ->
    case os:getenv(Var) of
        false -> Default;
        Str   ->
            case string:to_integer(Str) of
                {N, _} when is_integer(N) -> N;
                _                         -> Default
            end
    end.
