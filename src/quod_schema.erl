-module(quod_schema).
-moduledoc """
HOCON config **schema** for quod.

The config **file** (`config/quod.conf`, overridable by `$QUOD_CONF`) is the primary
source of configuration. OS environment variables prefixed `QUOD_` override individual
keys, using `__` to descend the path — e.g. `QUOD_CONTENT__MODE=join` overrides
`content.mode`, `QUOD_NODE__PORT=15000` overrides `node.port`. Env override is applied
during `m:hocon_tconf` check (see `quod_app:load_config/0`).

String values are `binary()` (HOCON's native string), converted to lists in the boot
code where the rest of the system expects `{Host, Port}` / file paths.
""".

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).
-export([namespace/0, roots/0, fields/1]).

namespace() -> quod.

%% Each root defaults to `#{}` so an absent block falls back to its field defaults
%% (a config with no `node {}` still yields node.ip/port defaults).
roots() ->
    [ {node,     hoconsc:mk(hoconsc:ref(?MODULE, node),     #{default => #{}})}
    , {metrics,  hoconsc:mk(hoconsc:ref(?MODULE, metrics),  #{default => #{}})}
    , {identity, hoconsc:mk(hoconsc:ref(?MODULE, identity), #{default => #{}})}
    , {content,  hoconsc:mk(hoconsc:ref(?MODULE, content),  #{default => #{}})}
    ].

fields(node) ->
    %% `port` is the ADVERTISED p2p endpoint (what peers dial + the link-header hint).
    %% `bind_port` is where QUIC actually LISTENS locally; 0 ⇒ same as `port`. They differ
    %% only under bridge networking + portmap, where the container binds a fixed internal
    %% port while advertising the dynamic HOST port Nomad mapped to it (see deploy/quod.nomad).
    [ {ip,        hoconsc:mk(binary(),  #{default => <<"127.0.0.1">>})}
    , {port,      hoconsc:mk(integer(), #{default => 14567})}
    , {bind_port, hoconsc:mk(integer(), #{default => 0})}
    ];
fields(metrics) ->
    [ {port, hoconsc:mk(integer(), #{default => 14568})}
    ];
fields(identity) ->
    %% The node's Ed25519 keypair (its `node_id` is the pubkey) is generated on first
    %% boot and persisted under `dir`. `dir = ""` ⇒ `<content.data_dir>/identity` (or the
    %% quod_simplex user_cache default), so identity shares the ledger's durability domain.
    [ {dir, hoconsc:mk(binary(), #{default => <<"">>})}
    ];
fields(content) ->
    %% A node founds (create) or joins one content namespace at boot. `genesis_file`
    %% is read once by the founder at create; `data_dir = ""` ⇒ quod_simplex's default.
    [ {namespace,    hoconsc:mk(binary(), #{default => <<"quod:root">>})}
    , {mode,         hoconsc:mk(hoconsc:enum([create, join]), #{default => create})}
    , {role,         hoconsc:mk(hoconsc:enum([member, replica]), #{default => member})}
    , {genesis_file, hoconsc:mk(binary(), #{default => <<"ontologies/quod_root.pl">>})}
    , {data_dir,     hoconsc:mk(binary(), #{default => <<"">>})}
    , {seeds,        hoconsc:mk(hoconsc:array(binary()), #{default => []})}
    ].
