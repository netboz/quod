variable "image_tag" {
  type        = string
  default     = "0.7.59"
  description = "Quod image tag in the cluster registry. Routine upgrades resume the existing anchored quod-node host volumes."
}

variable "image_registry" {
  type        = string
  default     = "192.168.1.11:5000"
  description = "Registry hostname and port containing the Quod image."
}

variable "node_count" {
  type        = number
  default     = 8
  description = "Steady-state fleet size (join mode). Ignored when bootstrap=true, which always starts exactly one founder."
}

variable "cloud_node_count" {
  type        = number
  default     = 2
  description = "Cloud satellites (join mode, `cloud`-class clients over the tailnet). Forced to 0 on a founding deploy — a satellite never founds. May exceed the cloud-client count: satellites stack on one host, each isolated by a per-alloc data_dir subdir (NOMAD_ALLOC_INDEX)."
}

variable "max_proof_workers" {
  type        = number
  default     = 64
  description = "Maximum concurrent client proof workers per ontology and allocation. Excess calls receive busy."
}

variable "max_ask_workers" {
  type        = number
  default     = 64
  description = "Maximum concurrent foreign-answer workers per ontology and allocation. Excess asks receive busy."
}

variable "proof_timeout_ms" {
  type        = number
  default     = 60000
  description = "Absolute lifetime of a client proof, including cross-ontology waits."
}

variable "transaction_ttl_ms" {
  type        = number
  default     = 30000
  description = "How long a proved write waits locally for a final applied/rejected outcome. Expiry returns outcome_unknown and does not cancel consensus."
}

variable "batch_window_ms" {
  type        = number
  default     = 25
  description = "Per-ontology time in milliseconds to collect ordinary transactions into one block. 0 seals immediately; 25 is the measured fleet default."
}

variable "ask_timeout_ms" {
  type        = number
  default     = 60000
  description = "Absolute lifetime of a served foreign ask, even while it continues producing answers."
}

variable "ask_step_timeout_ms" {
  type        = number
  default     = 30000
  description = "No-progress timeout while a served ask derives one answer."
}

variable "detailed_consensus_metrics" {
  type        = bool
  default     = false
  description = "Enable expensive per-event consensus timing and mailbox probes for a short diagnostic run. Keep false during normal operation and throughput tests."
}

variable "directory_node_keys" {
  type        = list(string)
  default     = []
  description = "Exact Ed25519 node-key allowlist for the discoverable quod:root directory. Supply the persistent fleet keys as 64-character hex strings; empty disables shared publication without weakening validation."
}

variable "cross_ontology_enabled" {
  type        = bool
  default     = false
  description = "Opt in to the two-host remote-read benchmark topology. It adds one source and one target demo ontology on distinct quod-node allocation indexes; it never changes quod:root."
}

variable "cross_ontology_source_namespace" {
  type        = string
  default     = "quod:bench_source"
  description = "Namespace hosted by cross_ontology_source_alloc_index for the remote-read benchmark."
}

variable "cross_ontology_target_namespace" {
  type        = string
  default     = "quod:bench_target"
  description = "Namespace hosted by cross_ontology_target_alloc_index for the remote-read benchmark."
}

variable "cross_ontology_source_alloc_index" {
  type        = number
  default     = 0
  description = "quod-node allocation index that hosts the benchmark source ontology. It must differ from the target index."
}

variable "cross_ontology_target_alloc_index" {
  type        = number
  default     = 1
  description = "quod-node allocation index that hosts the benchmark target ontology. It must differ from the source index."
}

variable "cross_ontology_source_node_keys" {
  type        = list(string)
  default     = []
  description = "Exact persistent Ed25519 public key(s) allowed to advertise the benchmark source namespace. Supply the key of the selected source allocation."
}

variable "cross_ontology_target_node_keys" {
  type        = list(string)
  default     = []
  description = "Exact persistent Ed25519 public key(s) allowed to advertise the benchmark target namespace. Supply the key of the selected target allocation."
}

variable "otel_exporter_otlp_endpoint" {
  type        = string
  default     = "http://192.168.1.11:4318"
  description = "Reachable OTLP/HTTP endpoint for Tempo. Use an address routable from both home and cloud allocations; do not rely on host-local Consul DNS inside bridge containers."
}

variable "genesis_hash" {
  type        = string
  default     = ""
  description = "Pinned slot-1 block hash (the trust anchor). REQUIRED for a steady-state (join) deploy; leave empty ONLY together with -var bootstrap=true when founding a fresh fleet."
}

# Founding a brand-new fleet is DESTRUCTIVE (count=1, mode=create — a fresh volume re-founds genesis).
# It fires ONLY when BOTH `bootstrap=true` AND `genesis_hash` is empty. Two independent guards:
#   - a routine deploy that forgets `-var genesis_hash` stays bootstrap=false ⇒ join, non-destructive;
#   - passing `-var bootstrap=true` by mistake on an ANCHORED fleet (genesis_hash set) still forces join —
#     the pinned anchor wins, so no single flag can collapse or re-found a live fleet.
variable "bootstrap" {
  type        = bool
  default     = false
  description = "Found a fresh fleet: with an EMPTY genesis_hash this forces count=1 and mode=create. Ignored (join) whenever genesis_hash is set. Never use on an anchored fleet."
}

# One homogeneous fleet, one durable volume family, one rolling-update domain.
#
# Fresh bootstrap (the ONLY destructive action — gated on the explicit `-var bootstrap=true`):
#   1. Stop the job and delete every dynamic host volume named
#      quod-node-local[N]. If cloud satellites have run, wipe their
#      quod-node-cloud allocation subdirectories too. See
#      doc/consensus-signatures.md for the canonical persistence contract.
#   2. Recreate quod-node-local[0..N-1] with `nomad volume create` from
#      deploy/volumes/quod-node-local.hcl, assigning the indices round-robin
#      across the ready compute-node IDs.
#   3. nomad job run -var image_tag=TAG -var bootstrap=true deploy/quod.nomad
#      bootstrap=true forces count=1 and mode=create — one founder writes a
#      fresh random incarnation into genesis.
#   4. Read the `genesis anchor` hash from that allocation's log.
#   5. nomad job run -var image_tag=TAG -var node_count=N \
#        -var genesis_hash=HEX deploy/quod.nomad
#      bootstrap defaults false ⇒ EVERY allocation runs in join mode. Allocation
#      zero resumes its durable ledger; every new allocation catches up as an
#      observer and must then be admitted through the root ontology. All later
#      deploys (image bumps, scaling) use this same anchored join-mode form.
#
# SAFETY: because founding is gated on `bootstrap` (a bool defaulting false), NOT on
# an empty genesis_hash, a routine `nomad job run` that forgets `-var genesis_hash`
# can never collapse the fleet to one node or re-found a divergent chain — it stays a
# non-destructive join-mode deploy (mode=join never writes genesis; existing volumes
# just resume). Set `bootstrap=true` ONLY against empty host volumes.
#
# The `update` stanza applies per task group: `max_parallel=1` rolls the home fleet one
# node at a time, and the (count=1) cloud group independently.
# No permanent allocation has a root/founder role after bootstrap.
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  group "quod-node" {
    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    # Create (count=1, founding) requires BOTH signals to agree: the explicit bootstrap opt-in AND an
    # empty anchor. A pinned genesis_hash ALWAYS forces join (count=node_count) even if bootstrap=true is
    # passed by mistake — so no single flag can re-found an anchored fleet.
    count = (var.bootstrap && var.genesis_hash == "") ? 1 : var.node_count

    spread {
      attribute = "${node.unique.name}"
    }

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
      port "explorer" { to = 14569 }
    }

    # Fast LOCAL storage: a per-alloc dynamic host volume (mkdir plugin) on each compute
    # node's local disk. This carries EVERYTHING
    # for the node — identity, vote journal, and the block ledger — on one fast disk, so
    # every consensus sync is local. Safe because the durability domains are unified: a
    # host that survives keeps all three (restart resumes with its votes remembered); a
    # host that dies loses all three together, so the node can only return as a fresh
    # validator (no identity kept while votes are lost — the equivocation hazard cannot
    # arise). Each indexed dynamic volume is explicitly created and pinned to a compute
    # node from deploy/volumes/quod-node-local.hcl before the job runs; ordinary
    # reschedules reuse it, while a deliberate re-found deletes and recreates every
    # instance.
    volume "quod-data" {
      type      = "host"
      source    = "quod-node-local"
      per_alloc = true
    }

    # Start-gate: an allocation may start once it can REACH a current fleet member (its port
    # is open) — NOT once a member is fully CAUGHT UP. Waiting for "caught up" deadlocks a
    # whole-fleet reboot: every node boots un-caught-up and waits for a neighbour that can
    # never become ready until it too is allowed to start. Reachability breaks that — allocation
    # zero (the resume-anchor) always starts, the rest wait only until zero's port opens, then
    # everyone comes up together and catches up as a group (which already works — see the load
    # test's over-f recovery). SAFETY is unaffected: this peer is used ONLY to decide "start
    # now"; recovery re-picks its OWN cert-verified contacts (quod_simplex recovery +
    # quod_catchup verify_forward), so a merely-reachable peer can never feed this node bad
    # data, and an un-caught-up node still can't vote until an honest quorum confirms it.
    # `|any` lists members regardless of Consul health so a cold-started (not-yet-passing)
    # peer still counts; we probe EVERY listed member so one dead entry can't wedge startup.
    # Skip the wait for the founding deploy (genesis_hash empty) or allocation zero.
    task "wait-for-peer" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        # ALL current members (|any = regardless of Consul health), one host:port per line, so a
        # cold-started peer that is up but not yet caught up still counts. Re-rendered as members
        # register; the gate script re-reads it each loop.
        data        = <<-EOT
{{- range service "quod-metrics|any" }}
{{ .Address }}:{{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/peers"
        change_mode = "noop"
      }

      config {
        # Use OUR image from the local registry (referenced by IP — no public DNS lookup), so the recovery
        # start-gate depends on NOTHING external. alpine-from-Docker-Hub stranded a compute node that could
        # not resolve Docker Hub — exactly the connectivity a real outage recovery must not require. The
        # quod image has an ENTRYPOINT, so override it; curl (already in the image) replaces nc, and a
        # 200 from a peer's /metrics is a strictly better "peer is up" signal than a bare open port.
        image      = "${var.image_registry}/quod:${var.image_tag}"
        force_pull = true
        entrypoint = ["/bin/sh", "-c"]
        args = [
          "if [ -z '${var.genesis_hash}' ] || [ \"$NOMAD_ALLOC_INDEX\" = 0 ]; then echo 'anchor allocation, no peer required'; exit 0; fi; while :; do while IFS=: read -r H P; do if [ -n \"$H\" ] && [ -n \"$P\" ] && curl -s -o /dev/null --max-time 2 \"http://$H:$P/metrics\"; then echo \"peer reachable at $H:$P\"; exit 0; fi; done < \"$NOMAD_TASK_DIR/peers\"; echo 'no peer reachable yet, sleeping 2s'; sleep 2; done"
        ]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }

    task "quod" {
      driver = "docker"

      config {
        image      = "${var.image_registry}/quod:${var.image_tag}"
        force_pull = true
        ports      = ["p2p", "metrics", "explorer"]
      }

      volume_mount {
        volume      = "quod-data"
        destination = "/quod/data"
        read_only   = false
      }

      template {
        data        = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
# The web explorer is off by DEFAULT (unauthenticated surface whose prove endpoint writes); the fleet
# opts in explicitly and binds all interfaces so Nomad's quod-explorer /health check can reach it. This
# is a private cluster; do not copy `ip = "0.0.0.0"` to an internet-exposed deployment.
explorer {
  enabled = true
  ip      = "0.0.0.0"
  port    = 14569
}
directory {
  allowlist = [
    {
      namespace = "quod:root"
      node_keys = [
%{for node_key in var.directory_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
%{if var.cross_ontology_enabled~}
    {
      namespace = "${var.cross_ontology_source_namespace}"
      node_keys = [
%{for node_key in var.cross_ontology_source_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
    {
      namespace = "${var.cross_ontology_target_namespace}"
      node_keys = [
%{for node_key in var.cross_ontology_target_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
%{endif~}
  ]
}
# `content` is a LIST: further ontologies are added as extra entries, each with its own
# mode/anchor (founded once by a single create deploy, then joined fleet-wide with the
# logged anchor — same two-phase dance as quod:root; they share /quod/data, the ledger
# keeps one subdirectory per namespace).
content = [
  {
    namespace = "quod:root"
    # data_dir is the fast local host volume mounted at /quod/data — identity, vote
    # journal, and ledger all live here now, so ledger_dir (the 0.7.36 Ceph workaround)
    # is no longer needed.
    data_dir  = "/quod/data"
    max_proof_workers = ${var.max_proof_workers}
    max_ask_workers = ${var.max_ask_workers}
    proof_timeout_ms = ${var.proof_timeout_ms}
    transaction_ttl_ms = ${var.transaction_ttl_ms}
    batch_window_ms = ${var.batch_window_ms}
    ask_timeout_ms = ${var.ask_timeout_ms}
    ask_step_timeout_ms = ${var.ask_step_timeout_ms}
    detailed_consensus_metrics = ${var.detailed_consensus_metrics}
%{if var.bootstrap && var.genesis_hash == ""}
    mode         = create
    genesis_file = "ontologies/quod_root.pl"
    seeds        = []
%{else}
    mode         = join
    genesis_hash = "${var.genesis_hash}"
    seeds        = [
{{- range service "quod" }}
      "{{ .Address }}:{{ .Port }}",
{{- end }}
    ]
%{endif}
  }
%{if var.cross_ontology_enabled~}
{{- if eq (env "NOMAD_ALLOC_INDEX") "${var.cross_ontology_source_alloc_index}" }}
  , {
    namespace = "${var.cross_ontology_source_namespace}"
    mode         = create
    genesis_file = "ontologies/cross_benchmark_source.pl"
    data_dir     = "/quod/data"
    seeds        = []
    max_proof_workers = ${var.max_proof_workers}
    max_ask_workers = ${var.max_ask_workers}
    proof_timeout_ms = ${var.proof_timeout_ms}
    ask_timeout_ms = ${var.ask_timeout_ms}
    ask_step_timeout_ms = ${var.ask_step_timeout_ms}
  }
{{- end }}
{{- if eq (env "NOMAD_ALLOC_INDEX") "${var.cross_ontology_target_alloc_index}" }}
  , {
    namespace = "${var.cross_ontology_target_namespace}"
    mode         = create
    genesis_file = "ontologies/cross_benchmark_target.pl"
    data_dir     = "/quod/data"
    seeds        = []
    max_proof_workers = ${var.max_proof_workers}
    max_ask_workers = ${var.max_ask_workers}
    proof_timeout_ms = ${var.proof_timeout_ms}
    ask_timeout_ms = ${var.ask_timeout_ms}
    ask_step_timeout_ms = ${var.ask_step_timeout_ms}
  }
{{- end }}
%{endif~}
]
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "noop"
      }

      template {
        data        = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
OTEL_SERVICE_NAME=quod
OTEL_RESOURCE_ATTRIBUTES=service.namespace=quod,deployment.environment=nomad,service.instance.id={{ env "NOMAD_ALLOC_ID" }}
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=${var.otel_exporter_otlp_endpoint}
OTEL_EXPORTER_OTLP_PROTOCOL=http_protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.05
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }

      service {
        name = "quod"
        port = "p2p"
        tags = ["quod", "content", "quic", "p2p"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus"]

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }

        check {
          name     = "consensus-ready"
          type     = "script"
          command  = "/bin/sh"
          args     = ["-ec", "curl -fsS --max-time 2 http://127.0.0.1:14568/metrics | awk '$1 ~ /^quod_consensus_syncing\\{/ { seen=1; if ($2 != 0) bad=1 } END { exit !(seen && !bad) }'"]
          interval = "5s"
          timeout  = "5s"
        }
      }

      service {
        name = "quod-explorer"
        port = "explorer"
        tags = ["quod", "explorer", "web"]

        check {
          type     = "http"
          path     = "/health"
          interval = "15s"
          timeout  = "3s"
        }
      }

      kill_signal  = "SIGTERM"
      kill_timeout = "30s"
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }
  }

  # Cloud satellite(s): same node software, same join semantics, placed on `cloud`-class
  # clients (VMs reached over the tailnet). Deltas from quod-node, all forced by the WAN seam:
  #   - host volume, with no network-storage dependency across the tunnel;
  #   - ALWAYS join mode with NO allocation-zero exemption — a satellite is never the
  #     resume-anchor and never founds (count drops to 0 on a founding deploy);
  #   - satellites MAY stack on one cloud host (no distinct_hosts): each alloc isolates its
  #     state under data_dir = /quod/data/${NOMAD_ALLOC_INDEX} on the shared host volume, so
  #     two satellites on the same host never share an identity key or a ledger dir.
  # The cloud client's `network_interface = "tailscale0"` makes the fingerprinted
  # `attr.unique.network.ip-address` (= the advertised endpoint below) its tailnet IP —
  # the one address every fleet member can dial.
  group "quod-cloud" {
    constraint {
      attribute = "${node.class}"
      value     = "cloud"
    }

    count = (var.bootstrap && var.genesis_hash == "") ? 0 : var.cloud_node_count

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
      port "explorer" { to = 14569 }
    }

    volume "quod-data" {
      type      = "host"
      source    = "quod-node-cloud"
      read_only = false
    }

    # Same start-gate as quod-node minus its exemptions: a satellite always has a fleet to
    # catch up from and is never the anchor, so it simply waits until any member is reachable.
    task "wait-for-peer" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
{{- range service "quod-metrics|any" }}
{{ .Address }}:{{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/peers"
        change_mode = "noop"
      }

      config {
        image   = "alpine:3.19"
        command = "sh"
        args = [
          "-c",
          "while :; do while IFS=: read -r H P; do if [ -n \"$H\" ] && [ -n \"$P\" ] && nc -z -w2 \"$H\" \"$P\" 2>/dev/null; then echo \"peer reachable at $H:$P\"; exit 0; fi; done < \"$NOMAD_TASK_DIR/peers\"; echo 'no peer reachable yet, sleeping 2s'; sleep 2; done"
        ]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }

    task "quod" {
      driver = "docker"

      config {
        image      = "${var.image_registry}/quod:${var.image_tag}"
        force_pull = true
        ports      = ["p2p", "metrics", "explorer"]
      }

      volume_mount {
        volume      = "quod-data"
        destination = "/quod/data"
        read_only   = false
      }

      template {
        data        = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
# Explorer stays tunnel-only: the published port lives on tailscale0 and the VM's public
# interface is firewalled, so 0.0.0.0 here never faces the internet.
explorer {
  enabled = true
  ip      = "0.0.0.0"
  port    = 14569
}
directory {
  # Satellites independently validate every directory record they receive.
  allowlist = [
    {
      namespace = "quod:root"
      node_keys = [
%{for node_key in var.directory_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
%{if var.cross_ontology_enabled~}
    {
      namespace = "${var.cross_ontology_source_namespace}"
      node_keys = [
%{for node_key in var.cross_ontology_source_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
    {
      namespace = "${var.cross_ontology_target_namespace}"
      node_keys = [
%{for node_key in var.cross_ontology_target_node_keys~}
        "${node_key}",
%{endfor~}
      ]
    },
%{endif~}
  ]
}
# `content` is a LIST — extra ontologies join here too (see the quod-node group's note).
content = [
  {
    namespace = "quod:root"
    data_dir  = "/quod/data/{{ env "NOMAD_ALLOC_INDEX" }}"
    max_proof_workers = ${var.max_proof_workers}
    max_ask_workers = ${var.max_ask_workers}
    proof_timeout_ms = ${var.proof_timeout_ms}
    transaction_ttl_ms = ${var.transaction_ttl_ms}
    batch_window_ms = ${var.batch_window_ms}
    ask_timeout_ms = ${var.ask_timeout_ms}
    ask_step_timeout_ms = ${var.ask_step_timeout_ms}
    detailed_consensus_metrics = ${var.detailed_consensus_metrics}
    mode         = join
    genesis_hash = "${var.genesis_hash}"
    seeds        = [
{{- range service "quod" }}
      "{{ .Address }}:{{ .Port }}",
{{- end }}
    ]
  }
]
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "noop"
      }

      template {
        data        = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
OTEL_SERVICE_NAME=quod
OTEL_RESOURCE_ATTRIBUTES=service.namespace=quod,deployment.environment=nomad,service.instance.id={{ env "NOMAD_ALLOC_ID" }}
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=${var.otel_exporter_otlp_endpoint}
OTEL_EXPORTER_OTLP_PROTOCOL=http_protobuf
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.05
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }

      service {
        name = "quod"
        port = "p2p"
        tags = ["quod", "content", "quic", "p2p", "cloud"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "cloud"]

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }

        check {
          name     = "consensus-ready"
          type     = "script"
          command  = "/bin/sh"
          args     = ["-ec", "curl -fsS --max-time 2 http://127.0.0.1:14568/metrics | awk '$1 ~ /^quod_consensus_syncing\\{/ { seen=1; if ($2 != 0) bad=1 } END { exit !(seen && !bad) }'"]
          interval = "5s"
          timeout  = "5s"
        }
      }

      service {
        name = "quod-explorer"
        port = "explorer"
        tags = ["quod", "explorer", "web", "cloud"]

        check {
          type     = "http"
          path     = "/health"
          interval = "15s"
          timeout  = "3s"
        }
      }

      kill_signal  = "SIGTERM"
      kill_timeout = "30s"
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }
  }

  update {
    max_parallel      = 1
    stagger           = "5s"
    health_check      = "checks"
    min_healthy_time  = "5s"
    healthy_deadline  = "15m"
    progress_deadline = "20m"
    auto_revert       = false
  }
}
