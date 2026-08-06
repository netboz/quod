-module(quod_schema).
-moduledoc """
HOCON config **schema** for quod.

The config **file** (`config/quod.conf`, overridable by `$QUOD_CONF`) is the primary
source of configuration. OS environment variables prefixed `QUOD_` override individual
scalar keys, using `__` to descend the path — e.g. `QUOD_NODE__PORT=15000` overrides
`node.port` (the `content` LIST is not env-overridable; deploys render the file). Env
override is applied during `m:hocon_tconf` check (see `quod_app:load_config/0`).

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
    , {explorer, hoconsc:mk(hoconsc:ref(?MODULE, explorer), #{default => #{}})}
    , {identity, hoconsc:mk(hoconsc:ref(?MODULE, identity), #{default => #{}})}
    , {directory, hoconsc:mk(hoconsc:ref(?MODULE, directory), #{default => #{}})}
      %% A LIST: a node may host several ontologies side by side (each entry founds or
      %% joins one namespace, with its own mode/genesis/anchor). One entry is the common case.
    , {content,  hoconsc:mk(hoconsc:array(hoconsc:ref(?MODULE, content)), #{default => [#{}]})}
    ].

fields(node) ->
    %% `port` is the ADVERTISED p2p endpoint (what peers dial + the link-header hint).
    %% `bind_port` is where QUIC actually LISTENS locally; 0 ⇒ same as `port`. They differ
    %% only under bridge networking + portmap, where the container binds a fixed internal
    %% port while advertising the dynamic HOST port Nomad mapped to it (see deploy/quod.nomad).
    [ {ip,        hoconsc:mk(binary(),  #{default => <<"127.0.0.1">>})}
    , {port,      hoconsc:mk(integer(), #{default => 14567})}
    , {bind_port, hoconsc:mk(integer(), #{default => 0})}
    %% QUIC liveness: a peer we haven't heard from for `idle_timeout_ms` is dropped, while
    %% `keepalive_ms` PINGs probe an otherwise-quiet-but-alive link. Detection ≈ the two summed
    %% (~2.5s at the defaults). Tuned for a trusted low-RTT LAN; raise both for a lossier/WAN
    %% path. Keep `keepalive_ms` well below `idle_timeout_ms` (else a healthy link false-closes).
    , {idle_timeout_ms, hoconsc:mk(integer(), #{default => 2000})}
    , {keepalive_ms,    hoconsc:mk(integer(), #{default => 500})}
    ];
fields(metrics) ->
    [ {port, hoconsc:mk(integer(), #{default => 14568})}
    ];
fields(explorer) ->
    %% The optional web explorer (quod_explorer). OFF by default: it is an unauthenticated web
    %% surface whose prove endpoint WRITES, so enabling it — and especially widening `ip` past
    %% loopback — is a deliberate operator choice, not a fleet default.
    [ {enabled, hoconsc:mk(boolean(), #{default => false})}
    , {ip,      hoconsc:mk(binary(),  #{default => <<"127.0.0.1">>})}
    , {port,    hoconsc:mk(integer(), #{default => 14569})}
    ];
fields(identity) ->
    %% The node's Ed25519 keypair (its `node_id` is the pubkey) is generated on first
    %% boot and persisted under `dir`. `dir = ""` ⇒ `<content.data_dir>/identity` (or the
    %% quod_simplex user_cache default), so identity shares the ledger's durability domain.
    [ {dir, hoconsc:mk(binary(), #{default => <<"">>})}
    ];
fields(directory) ->
    [ {allowlist,
       hoconsc:mk(
         hoconsc:array(hoconsc:ref(?MODULE, directory_allow)),
         #{default => []})}
    , {direct_seeds,
       hoconsc:mk(
         hoconsc:array(hoconsc:ref(?MODULE, directory_direct)),
         #{default => []})}
    ];
fields(directory_allow) ->
    [ {namespace, hoconsc:mk(binary())}
    , {node_keys, hoconsc:mk(hoconsc:array(binary()), #{default => []})}
    ];
fields(directory_direct) ->
    [ {namespace, hoconsc:mk(binary())}
    , {seeds, hoconsc:mk(hoconsc:array(binary()), #{default => []})}
    ];
fields(content) ->
    %% One ontology this node founds (create) or joins at boot — `content` is a LIST of
    %% these. `genesis_file` is read once by the founder at create; `data_dir = ""` ⇒
    %% quod_simplex's default. Ontologies may share one data_dir: the ledger store keeps
    %% each namespace in its own subdirectory (quod_ledger_store:ns_dir/2).
    [ {namespace,    hoconsc:mk(binary(), #{default => <<"quod:root">>})}
    , {mode,         hoconsc:mk(hoconsc:enum([create, join]), #{default => create})}
    , {role,         hoconsc:mk(hoconsc:enum([member, replica]), #{default => member})}
    , {genesis_file, hoconsc:mk(binary(), #{default => <<"ontologies/quod_root.pl">>})}
    , {data_dir,     hoconsc:mk(binary(), #{default => <<"">>})}
      %% Optional FAST-LOCAL home for the block ledger only. The chain is replicated by
      %% consensus (a node that loses its ledger re-syncs trustlessly from peers), so it
      %% does not need the durable volume; identity + vote journal REMAIN under data_dir.
      %% "" => the ledger shares data_dir (the previous behaviour).
    , {ledger_dir,   hoconsc:mk(binary(), #{default => <<"">>})}
    , {seeds,        hoconsc:mk(hoconsc:array(binary()), #{default => []})}
    , {max_proof_workers,
       hoconsc:mk(integer(), #{default => 64, validator => fun(N) -> N > 0 end})}
    , {max_scope_workers,
       hoconsc:mk(integer(), #{default => 64, validator => fun(N) -> N > 0 end})}
    , {proof_timeout_ms,
       hoconsc:mk(integer(), #{default => 60000, validator => fun(N) -> N > 0 end})}
    , {transaction_ttl_ms,
       hoconsc:mk(integer(), #{default => 30000, validator => fun(N) -> N > 0 end})}
      %% Time the proposer keeps a newly-opened block available for more ordinary
      %% transactions. 0 seals immediately; 25 ms is the measured fleet default.
    , {batch_window_ms,
       hoconsc:mk(integer(),
                  #{default => 25,
                    validator => fun(N) -> N >= 0 andalso N =< 1000 end})}
    , {scope_timeout_ms,
       hoconsc:mk(integer(), #{default => 60000, validator => fun(N) -> N > 0 end})}
    , {scope_step_timeout_ms,
       hoconsc:mk(integer(), #{default => 30000, validator => fun(N) -> N > 0 end})}
      %% Expensive per-event/per-substep Prometheus probes for short diagnostic runs.
      %% Disabled by default because they execute inside the serial consensus process.
    , {detailed_consensus_metrics, hoconsc:mk(boolean(), #{default => false})}
      %% `mode=join` REQUIRES this: the out-of-band trust anchor — the founder's genesis
      %% block hash as a 64-char hex string, copied from the founder's boot log (see
      %% `quod_app`). Empty for a `create` node. It is what makes catch-up trustless: a
      %% joiner verifies the whole downloaded history against this one pinned fingerprint.
    , {genesis_hash, hoconsc:mk(binary(), #{default => <<"">>})}
    ].
