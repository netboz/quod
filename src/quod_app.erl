-module(quod_app).
-moduledoc """
quod application entry point.

Configuration is a **HOCON file** (`config/quod.conf`, or wherever `QUOD_CONF`
points; a release ships `priv/quod.conf`). The file is the primary source; OS
environment variables prefixed `QUOD_` override individual keys, using `__` to
descend the path — e.g. `QUOD_CONTENT__MODE=join` overrides `content.mode`,
`QUOD_NODE__PORT=15000` overrides `node.port`. See `m:quod_schema` for the shape.

`load_config/0` bridges the file onto the `application` env the transport reads
(`listen_port`, `metrics_port`, `node_id`) and returns the `content` section, which
drives Brahms membership and the content namespace this node founds (`create`) or
joins. It also **load-or-creates the node's Ed25519 identity** (a side effect:
persists `node.key` under the identity dir and sets `node_pubkey`/`identity_cert`/
`identity_key`). **With no config file present, the app starts in legacy mode** —
`sys.config` / `application:set_env` drive the transport, no content namespace is
auto-started, and no identity is minted (this is what the multi-node test SUITE relies on).
""".

-behaviour(application).

-export([start/2, stop/1]).
-ifdef(TEST).
-export([build_ns_config/1, load_config/0]).
-endif.

start(_StartType, _StartArgs) ->
    Content   = load_config(),
    {ok, Sup} = quod_sup:start_link(),
    ok = maybe_join(Content),
    ok = maybe_start_ns(Content),
    {ok, Sup}.

stop(_State) ->
    ok.

%% --- config: HOCON file primary, QUOD_ env vars override individual keys -----

%% Returns the `content` config map, or `none` when no config file is present
%% (legacy mode — see the moduledoc).
load_config() ->
    case conf_path() of
        none -> none;
        Path ->
            os:putenv("HOCON_ENV_OVERRIDE_PREFIX", "QUOD_"),
            {ok, Raw} = hocon:load(Path),
            Cfg = hocon_tconf:check_plain(quod_schema, Raw,
                                          #{atom_key => true, apply_override_envs => true}),
            apply_transport_env(Cfg),
            apply_identity(Cfg),
            maps:get(content, Cfg)
    end.

%% Load-or-create the node's Ed25519 identity and expose it in the application env
%% (`node_pubkey`, the DER `identity_cert`, the `identity_key`). The pubkey becomes the
%% `node_id` and the cert/key drive transport mutual TLS (wired in later steps). A node
%% with no identity is useless, so a failure here is fatal — fail-fast like genesis.
apply_identity(Cfg) ->
    Dir = identity_dir(Cfg),
    case quod_identity:ensure(Dir) of
        {ok, #{pubkey := Pub, cert := Cert, key := Key}} ->
            application:set_env(quod, node_pubkey, Pub),
            application:set_env(quod, identity_cert, Cert),
            application:set_env(quod, identity_key, Key),
            logger:info("quod: node identity ~s (~s)", [quod_identity:short(Pub), Dir]);
        {error, Reason} ->
            %% Fatal — a node with no identity is useless. Log first (like every other
            %% boot failure) so the operator sees a quod-tagged line, not just the crash.
            logger:error("quod: node identity load/create failed in ~s: ~p", [Dir, Reason]),
            error({identity_failed, Reason})
    end.

%% `identity.dir` if set, else `<data_dir>/identity` — i.e. INSIDE the same dir the ledger
%% resolves (`data_dir/1`), so identity always shares the ledger's durability domain and
%% survives a host move. Both fall back to the same `<user_cache>/quod/data` default.
identity_dir(Cfg) ->
    case maps:get(dir, maps:get(identity, Cfg, #{}), <<>>) of
        <<>> -> filename:join(content_data_dir(Cfg), "identity");
        Dir  -> binary_to_list(Dir)
    end.

%% The resolved content data dir (mirrors quod_simplex/quod_ledger_store's data_dir default).
content_data_dir(Cfg) ->
    case maps:get(data_dir, maps:get(content, Cfg, #{}), <<>>) of
        <<>>    -> filename:join(filename:basedir(user_cache, "quod"), "data");
        DataDir -> binary_to_list(DataDir)
    end.

%% Bridge HOCON `node`/`metrics` onto the application env the transport reads.
apply_transport_env(Cfg) ->
    Node = maps:get(node, Cfg),
    Ip   = binary_to_list(maps:get(ip, Node)),
    Port = maps:get(port, Node),                          %% advertised (header hint / peers dial)
    Bind = case maps:get(bind_port, Node, 0) of           %% local QUIC bind; may differ under bridge+portmap
               0 -> Port;
               B -> B
           end,
    application:set_env(quod, listen_port, Bind),
    application:set_env(quod, metrics_port, maps:get(port, maps:get(metrics, Cfg))),
    application:set_env(quod, node_id, {Ip, Port}),
    ok.

conf_path() ->
    case os:getenv("QUOD_CONF") of
        P when is_list(P), P =/= "" -> regular_or_none(P);
        _ -> regular_or_none(filename:join(code:priv_dir(quod), "quod.conf"))
    end.

regular_or_none(Path) ->
    case filelib:is_regular(Path) of
        true  -> Path;
        false -> none
    end.

%% --- Brahms membership (when a content namespace is configured) --------------

maybe_join(none) -> ok;
maybe_join(Content) ->
    Ns    = maps:get(namespace, Content),
    Self  = application:get_env(quod, node_id, default_node_id()),
    Seeds = content_seeds(Content),
    case quod_brahms:start_namespace(Ns, #{node_id => Self, seed_peers => Seeds}) of
        {ok, _} ->
            logger:info("quod[~s]: brahms up as ~p (~b seed(s))", [Ns, Self, length(Seeds)]);
        Error ->
            logger:error("quod[~s]: brahms start failed: ~p", [Ns, Error])
    end,
    ok.

%% --- content namespace (create founds + serves root; create failure is fatal) -

maybe_start_ns(none) -> ok;
maybe_start_ns(Content) ->
    {Ns, NsCfg} = build_ns_config(Content),
    Mode = maps:get(mode, NsCfg),
    case quod_ns_sup:start_namespace(Ns, NsCfg) of
        {ok, _} ->
            logger:info("quod[~s]: content namespace up (mode=~p)", [Ns, Mode]);
        {error, {already_started, _}} ->
            ok;
        Error when Mode =:= create ->
            %% Founding the network failed (e.g. a bad genesis .pl). A node with no
            %% root is useless — stop the app rather than run half-born.
            error({content_namespace_create_failed, Ns, Error});
        Error ->
            logger:error("quod[~s]: content namespace start failed: ~p", [Ns, Error])
    end,
    ok.

%% Build the per-namespace config map for quod_ns_sup:start_namespace/2. The ledger's
%% `node_id` is the node's PUBKEY (from `apply_identity`) — its stable identity; the address
%% is only a seed/hint (`seed_peers`, the link header). With no identity it falls back to the
%% address (the legacy/test path). Brahms keeps using the address (see `maybe_join`).
build_ns_config(Content) ->
    Ns   = maps:get(namespace, Content),
    Self = application:get_env(quod, node_pubkey,
                               application:get_env(quod, node_id, default_node_id())),
    Base = #{node_id    => Self,
             mode       => maps:get(mode, Content),
             role       => maps:get(role, Content, member),
             seed_peers => content_seeds(Content)},
    {Ns, with_genesis_file(Content, with_data_dir(Content, Base))}.

with_data_dir(Content, Base) ->
    case maps:get(data_dir, Content, <<>>) of
        <<>> -> Base;
        Dir  -> Base#{data_dir => binary_to_list(Dir)}
    end.

with_genesis_file(Content, Base) ->
    case maps:get(genesis_file, Content, <<>>) of
        <<>> -> Base;
        Rel  -> Base#{genesis_file => filename:join(code:priv_dir(quod), binary_to_list(Rel))}
    end.

content_seeds(Content) ->
    lists:filtermap(fun parse_seed/1, maps:get(seeds, Content, [])).

default_node_id() ->
    {"127.0.0.1", application:get_env(quod, listen_port, 14567)}.

%% --- helpers -----------------------------------------------------------------

%% a HOCON seed entry `<<"host:port">>` -> {Host, Port}
parse_seed(Bin) when is_binary(Bin) -> parse_seed(binary_to_list(Bin));
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
