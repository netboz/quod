-module(quod_app).
-moduledoc """
quod application entry point.

Configuration is a **HOCON file** (`config/quod.conf`, or wherever `QUOD_CONF`
points; a release ships `priv/quod.conf`). The file is the primary source; OS
environment variables prefixed `QUOD_` override individual scalar keys, using `__`
to descend the path — e.g. `QUOD_NODE__PORT=15000` overrides `node.port`. (The
`content` section is a LIST and is not env-overridable — deploys render the file.)
See `m:quod_schema` for the shape.

`load_config/0` bridges the file onto the `application` env the transport reads
(`listen_port`, `metrics_port`, `node_id`) and returns the `content` section — a
**list** of ontology blocks; for each, the node runs Brahms membership and founds
(`create`) or joins that namespace. It also **load-or-creates the node's Ed25519
identity** (a side effect: persists `node.key` under the identity dir and sets
`node_pubkey`/`identity_cert`/`identity_key`; the identity dir derives from the first
content entry that SETS a `data_dir` — one node, one identity, however many ontologies).
**With no config file present, the app starts in configuration-free test mode** —
`sys.config` / `application:set_env` drive the transport, no content namespace is
auto-started, and no identity is minted (this is what the multi-node test suite relies on).
""".

-behaviour(application).

-export([start/2, stop/1]).
-export([build_ns_config/1]).
-ifdef(TEST).
-export([load_config/0, root_contacts/1]).
-endif.

start(_StartType, _StartArgs) ->
    ok = quiet_transport_logging(),
    Content   = load_config(),
    ok = tag_node_logs(),
    %% A full application start is the lifecycle barrier: control starts before
    %% the dynamic namespace children and must not recover a partial hosted set
    %% from an earlier in-VM run. A control-child restart after this barrier
    %% sees `true` and safely re-derives the live set.
    application:set_env(quod, directory_tracking, false),
    %% Desired dynamic children survive their own supervisor/manager restarts,
    %% but a full application start is a new lifecycle and rebuilds intent from
    %% the freshly loaded content configuration below.
    application:set_env(
      quod, namespace_desired,
      #{content => #{}, brahms => #{}}),
    {ok, Sup} = quod_sup:start_link(),
    ok = maybe_join(Content),
    ok = maybe_start_ns(Content),
    ok = maybe_start_directory_tracking(Content),
    {ok, Sup}.

stop(_State) ->
    ok.

%% Stamp this node's id into the primary logger metadata so every JSON log line
%% carries `node_id` — the 30-node fleet's warnings become attributable per
%% instance in Loki (`{job="docker"} |~ "quod\\[quod:" | json | node_id="kp_..."`).
%% Uses the Ed25519 pubkey short-id (same identity the Prometheus `node_id` label
%% uses); falls back to the BEAM node name in configuration-free test mode where no identity
%% is minted. Runs after `load_config/0`, which is what sets `node_pubkey`.
tag_node_logs() ->
    Id = case application:get_env(quod, node_pubkey) of
             {ok, Pub} when is_binary(Pub) -> quod_identity:short(Pub);
             _                             -> atom_to_binary(node(), utf8)
         end,
    _ = logger:update_primary_config(#{metadata => #{node_id => Id}}),
    ok.

%% The pure-Erlang `quic` transport logs one INFO line per received packet
%% (`short_header_packet`). Under load that floods the default `logger_std_h`
%% handler faster than its sink drains; the handler's overload protection then
%% stalls the node's stdout, so genuine warnings/errors never reach the
%% nomad/docker log files that promtail ships to Loki. Raise the quic
%% application's log level to `notice` at boot: keep its warnings/errors, drop
%% the per-packet info/debug torrent. Best-effort — a `{error, {not_loaded,_}}`
%% (quic somehow not yet loaded) is harmless, so it is ignored.
quiet_transport_logging() ->
    _ = logger:set_application_level(quic, notice),
    ok.

%% --- config: HOCON file primary, QUOD_ env vars override individual keys -----

%% Returns the `content` config map, or `none` when no config file is present
%% (configuration-free test mode — see the moduledoc).
load_config() ->
    case conf_path() of
        none -> none;
        Path ->
            os:putenv("HOCON_ENV_OVERRIDE_PREFIX", "QUOD_"),
            ok = drop_content_env_overrides(),
            {ok, Raw} = hocon:load(Path),
            Cfg = hocon_tconf:check_plain(quod_schema, Raw,
                                          #{atom_key => true, apply_override_envs => true}),
            apply_transport_env(Cfg),
            apply_identity(Cfg),
            apply_directory(Cfg),
            Blocks = maps:get(content, Cfg),
            Blocks
    end.

%% `content` is a LIST; hocon's env override cannot address array elements — a leftover
%% QUOD_CONTENT__* var (the pre-list override style) would REPLACE the whole rendered list
%% with a one-key map and crash the schema check with a misleading {bad_array_index,..}.
%% Strip any such var loudly instead: the file is authoritative for `content`.
drop_content_env_overrides() ->
    _ = [begin
             logger:warning("quod: ignoring stale env override ~s (content is a LIST; "
                            "edit the config file instead)", [K]),
             os:unsetenv(K)
         end || {K, _V} <- os:env(), string:prefix(K, "QUOD_CONTENT__") =/= nomatch],
    ok.

%% Load-or-create the node's Ed25519 identity and expose it in the application env
%% (`node_pubkey`, the DER `identity_cert`, the `identity_key`). The pubkey becomes the
%% `node_id` and the cert/key drive transport mutual TLS and signed directory records. A node
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
%% `content` is a LIST of ontology blocks; the node identity (one per node) anchors to the
%% first entry that SETS a data_dir — order-independent in the normal shape where every
%% entry shares one dir (the ledger store keeps each namespace in its own subdirectory),
%% and never fooled by a dir-less entry sitting first.
content_data_dir(Cfg) ->
    Dirs = [maps:get(data_dir, B, <<>>) || B <- maps:get(content, Cfg, [])],
    case [D || D <- Dirs, D =/= <<>>] of
        [Dir | _] -> binary_to_list(Dir);
        []        -> filename:join(filename:basedir(user_cache, "quod"), "data")
    end.

%% Build the operator-controlled directory configuration. System publication
%% uses exact namespace/key allowlists; private routes are namespace-scoped
%% local seeds. Directory control reuses the root ontology's own join contacts
%% for endpoint discovery; they grant no authority and are not a second
%% directory-bootstrap configuration.
apply_directory(Cfg) ->
    Raw = maps:get(directory, Cfg, #{}),
    AllowEntries = maps:get(allowlist, Raw, []),
    DirectEntries = maps:get(direct_seeds, Raw, []),
    ensure_distinct(
      directory_allowlist_namespace,
      [maps:get(namespace, Entry) || Entry <- AllowEntries]),
    ensure_distinct(
      directory_direct_namespace,
      [maps:get(namespace, Entry) || Entry <- DirectEntries]),
    Allowlist = directory_allowlist(AllowEntries),
    DirectSeeds =
        maps:from_list(
          [{maps:get(namespace, Entry),
            required_endpoints(
              {directory_direct_seeds, maps:get(namespace, Entry)},
              maps:get(seeds, Entry, []))}
           || Entry <- DirectEntries]),
    application:set_env(
      quod, directory,
      #{allowlist => Allowlist,
        direct_seeds => DirectSeeds,
        root_contacts => root_contacts(Cfg),
        identity_dir => identity_dir(Cfg)}),
    ok.

root_contacts(Cfg) ->
    Roots =
        [Block
         || Block <- maps:get(content, Cfg, []),
            maps:get(namespace, Block) =:= <<"quod:root">>],
    case Roots of
        [] ->
            [];
        [Root] ->
            recovery_contacts(maps:get(seeds, Root, []));
        _ ->
            error({duplicate_content_namespace, <<"quod:root">>})
    end.

directory_allowlist(Entries) ->
    maps:from_list(
      [{maps:get(namespace, Entry),
        [decode_node_key(Key) || Key <- maps:get(node_keys, Entry, [])]}
       || Entry <- Entries]).

decode_node_key(Hex) when is_binary(Hex), byte_size(Hex) =:= 64 ->
    try
        <<Key:32/binary>> = binary:decode_hex(Hex),
        Key
    catch
        _:_ -> error({bad_directory_node_key, Hex})
    end;
decode_node_key(Value) ->
    error({bad_directory_node_key, Value}).

required_endpoints(Label, Values) ->
    Parsed = lists:filtermap(fun parse_seed/1, Values),
    case length(Parsed) =:= length(Values) of
        true -> lists:usort(Parsed);
        false -> error({bad_directory_endpoint, Label})
    end.

%% Root content seeds are operational recovery hints, with the same tolerance
%% as the seeds used by consensus and Brahms. They carry no directory authority:
%% an authenticated key is promoted only after the local root proof approves it.
%% A transient empty Consul template entry must therefore not abort node boot.
recovery_contacts(Values) ->
    lists:usort(
      lists:filtermap(
        fun(Value) ->
            case parse_seed(Value) of
                {true, Endpoint} -> {true, Endpoint};
                false ->
                    logger:warning(
                      "quod: ignoring invalid root recovery contact: ~p",
                      [Value]),
                    false
            end
        end, Values)).

ensure_distinct(Label, Values) ->
    case length(Values) =:= length(lists:usort(Values)) of
        true -> ok;
        false -> error({duplicate_directory_entry, Label})
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
    Ex = maps:get(explorer, Cfg),
    application:set_env(quod, explorer_enabled, maps:get(enabled, Ex, false)),
    application:set_env(quod, explorer_ip, parse_ip(maps:get(ip, Ex, <<"127.0.0.1">>))),
    application:set_env(quod, explorer_port, maps:get(port, Ex)),
    application:set_env(quod, node_addr, {Ip, Port}),   %% advertised endpoint the transport announces
    application:set_env(quod, node_id, {Ip, Port}),     %% Brahms' address-flavoured id (distinct from node_pubkey)
    application:set_env(quod, quic_idle_timeout_ms, maps:get(idle_timeout_ms, Node)),  %% dead-peer detection tuning
    application:set_env(quod, quic_keepalive_ms, maps:get(keepalive_ms, Node)),
    ok.

%% Parse a configured bind IP (`explorer.ip`) into an inet address tuple; loopback on anything
%% unparseable, so a typo can never accidentally widen the viewer to all interfaces.
parse_ip(Bin) when is_binary(Bin) ->
    case inet:parse_address(binary_to_list(Bin)) of
        {ok, Addr} -> Addr;
        _          -> {127, 0, 0, 1}
    end;
parse_ip(_) -> {127, 0, 0, 1}.

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

%% --- Brahms membership (one instance per configured ontology) ----------------

maybe_join(none) -> ok;
maybe_join(Blocks) ->
    lists:foreach(fun join_block/1, Blocks).

join_block(Content) ->
    Ns    = maps:get(namespace, Content),
    Self  = application:get_env(quod, node_id, default_node_id()),
    Seeds = content_seeds(Content),
    PopulationIdentity = case {application:get_env(quod, node_pubkey),
                               application:get_env(quod, identity_key)} of
                             {{ok, Pub}, {ok, Key}} -> #{pubkey => Pub, key => Key};
                             _ -> undefined
                         end,
    case quod_brahms:start_namespace(Ns, #{node_id => Self, seed_peers => Seeds,
                                            population_identity => PopulationIdentity}) of
        {ok, _} ->
            logger:info("quod[~s]: brahms up as ~p (~b seed(s))", [Ns, Self, length(Seeds)]);
        Error ->
            logger:error("quod[~s]: brahms start failed: ~p", [Ns, Error])
    end,
    ok.

%% --- content namespaces (create founds + serves; create failure is fatal) ----

maybe_start_ns(none) -> ok;
maybe_start_ns(Blocks) ->
    ok = validate_blocks(Blocks),
    lists:foreach(fun start_ns_block/1, Blocks).

maybe_start_directory_tracking(none) ->
    ok;
maybe_start_directory_tracking(_Blocks) ->
    case quod_directory_control:start_tracking() of
        ok -> ok;
        {error, Reason} -> error({directory_tracking_failed, Reason})
    end.

%% Boot-config sanity for the content LIST — loud failures instead of a silently wrong
%% network: duplicate namespaces (two blocks would fight over one committee), and a
%% non-root entry that inherited the ROOT defaults — a bare `{ namespace = "animals" }`
%% would otherwise FOUND `animals` seeded with quod_root.pl's content, which is always
%% an operator mistake (each per-element schema default is root-flavoured).
validate_blocks(Blocks) ->
    Names = [maps:get(namespace, B) || B <- Blocks],
    case Names -- lists:usort(Names) of
        []   -> ok;
        Dups -> error({content_duplicate_namespace, Dups})
    end,
    lists:foreach(fun check_block_defaults/1, Blocks).

check_block_defaults(#{namespace := <<"quod:root">>}) -> ok;
check_block_defaults(B = #{namespace := Ns}) ->
    case {maps:get(mode, B), maps:get(genesis_file, B, <<>>)} of
        {create, <<"ontologies/quod_root.pl">>} ->
            error({content_block_inherited_root_defaults, Ns});
        _ -> ok
    end.

start_ns_block(Content) ->
    {Ns, NsCfg} = build_ns_config(Content),
    Mode = maps:get(mode, NsCfg),
    case quod_ns_sup:start_namespace(Ns, NsCfg) of
        {ok, _} ->
            logger:info("quod[~s]: content namespace up (mode=~p)", [Ns, Mode]),
            log_genesis_anchor(Ns, Mode);
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

%% After a founder (create) stands up its namespace, log its genesis block hash — the anchor a mode=join
%% node must pin in `content.genesis_hash`. Logged at `notice` so it stands out in the boot log: this is
%% how the operator gets the out-of-band trust anchor to hand to joiners (the one fact a joiner can't
%% safely download). A join node logs nothing here.
log_genesis_anchor(Ns, create) ->
    case quod_simplex:genesis_hash(Ns) of
        H when is_binary(H) ->
            logger:notice("quod[~s]: genesis anchor — pin as content.genesis_hash on joiners: ~s",
                          [Ns, binary:encode_hex(H)]);
        _ -> ok
    end;
log_genesis_anchor(_Ns, _Mode) -> ok.

%% Build the per-namespace config map for quod_ns_sup:start_namespace/2. The ledger's
%% `node_id` is the node's PUBKEY (from `apply_identity`) — its stable identity; the address
%% is only a seed/hint (`seed_peers`, the link header). With no identity it falls back to the
%% address (the configuration-free test path). Brahms keeps using the address
%% (see `maybe_join`).
build_ns_config(Content) ->
    Ns   = maps:get(namespace, Content),
    Self = application:get_env(quod, node_pubkey,
                               application:get_env(quod, node_id, default_node_id())),
    Base = #{node_id    => Self,
             mode       => maps:get(mode, Content),
             role       => maps:get(role, Content, member),
             max_proof_workers => maps:get(max_proof_workers, Content, 64),
             max_scope_workers => maps:get(max_scope_workers, Content, 64),
             proof_timeout_ms => maps:get(proof_timeout_ms, Content, 60000),
             transaction_ttl_ms =>
                 maps:get(transaction_ttl_ms, Content, 30000),
             batch_window_ms => maps:get(batch_window_ms, Content, 25),
             scope_timeout_ms => maps:get(scope_timeout_ms, Content, 60000),
             scope_step_timeout_ms => maps:get(scope_step_timeout_ms, Content, 30000),
             detailed_consensus_metrics =>
                 maps:get(detailed_consensus_metrics, Content, false),
             seed_peers => content_seeds(Content)},
    {Ns, with_genesis_hash(Content,
          with_genesis_file(Content,
            with_ledger_dir(Content, with_data_dir(Content, Base))))}.

with_data_dir(Content, Base) ->
    case maps:get(data_dir, Content, <<>>) of
        <<>> -> Base;
        Dir  -> Base#{data_dir => binary_to_list(Dir)}
    end.

with_ledger_dir(Content, Base) ->
    case maps:get(ledger_dir, Content, <<>>) of
        <<>> -> Base;
        Dir  -> Base#{ledger_dir => binary_to_list(Dir)}
    end.

%% The `mode=join` trust anchor: a 64-char hex string in config (`content.genesis_hash`, copied from the
%% founder's boot log) decoded to the raw 32-byte block hash `quod_simplex` pins. Absent/blank ⇒ not
%% forwarded (a `create` node needs none; a `join` node without it is fail-fast'd by `valid_cfg`, which
%% is the correct loud failure — never a silent TOFU). A malformed hex value is treated as absent.
with_genesis_hash(Content, Base) ->
    case maps:get(genesis_hash, Content, <<>>) of
        <<>> -> Base;
        Hex  -> try Base#{genesis_hash => binary:decode_hex(Hex)}
                catch _:_ -> logger:error("quod: content.genesis_hash is not valid hex: ~p", [Hex]), Base
                end
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
