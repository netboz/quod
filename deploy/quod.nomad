variable "image_tag" {
  type        = string
  default     = "0.7.11"
  description = "Quod image tag in the cluster registry. This clean-ledger release expects freshly provisioned quod-node CSI volumes."
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
#   1. Create quod-node[0..N-1] from deploy/volumes/quod-node.hcl.
#   2. nomad job run -var image_tag=TAG -var bootstrap=true deploy/quod.nomad
#      bootstrap=true forces count=1 and mode=create — one founder writes genesis.
#   3. Read the `genesis anchor` hash from that allocation's log.
#   4. nomad job run -var image_tag=TAG -var node_count=N \
#        -var genesis_hash=HEX deploy/quod.nomad
#      bootstrap defaults false ⇒ EVERY allocation runs in join mode: allocation
#      zero resumes its durable ledger (its volume is the anchor), and every new
#      allocation joins against the pinned history. All later deploys (image bumps,
#      scaling) are this same join-mode form.
#
# SAFETY: because founding is gated on `bootstrap` (a bool defaulting false), NOT on
# an empty genesis_hash, a routine `nomad job run` that forgets `-var genesis_hash`
# can never collapse the fleet to one node or re-found a divergent chain — it stays a
# non-destructive join-mode deploy (mode=join never writes genesis; existing volumes
# just resume). Set `bootstrap=true` ONLY against freshly provisioned volumes.
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
      port "transactions" { to = 14569 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-node"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      per_alloc       = true
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
        ports      = ["p2p", "metrics", "transactions"]
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
# The live transaction viewer is off by DEFAULT (unauthenticated debug surface); the fleet opts in
# explicitly and binds all interfaces so Nomad's quod-transactions /health check can reach it. This is a
# private cluster; do not copy `ip = "0.0.0.0"` to an internet-exposed deployment.
transactions {
  enabled = true
  ip      = "0.0.0.0"
  port    = 14569
}
# `content` is a LIST: further ontologies are added as extra entries, each with its own
# mode/anchor (founded once by a single create deploy, then joined fleet-wide with the
# logged anchor — same two-phase dance as quod:root; they share /quod/data, the ledger
# keeps one subdirectory per namespace).
content = [
  {
    namespace = "quod:root"
    data_dir  = "/quod/data"
    max_proof_workers = ${var.max_proof_workers}
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
]
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "noop"
      }

      template {
        data        = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
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
        name = "quod-transactions"
        port = "transactions"
        tags = ["quod", "transactions", "web"]

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
  #   - host volume instead of Ceph CSI (no RBD attach across the tunnel);
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
      port "transactions" { to = 14569 }
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
        ports      = ["p2p", "metrics", "transactions"]
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
# Viewer stays tunnel-only: the published port lives on tailscale0 and the VM's public
# interface is firewalled, so 0.0.0.0 here never faces the internet.
transactions {
  enabled = true
  ip      = "0.0.0.0"
  port    = 14569
}
# `content` is a LIST — extra ontologies join here too (see the quod-node group's note).
content = [
  {
    namespace = "quod:root"
    data_dir  = "/quod/data/{{ env "NOMAD_ALLOC_INDEX" }}"
    max_proof_workers = ${var.max_proof_workers}
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
EOT
        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
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
        name = "quod-transactions"
        port = "transactions"
        tags = ["quod", "transactions", "web", "cloud"]

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
    health_check      = "checks"
    min_healthy_time  = "15s"
    healthy_deadline  = "15m"
    progress_deadline = "20m"
    auto_revert       = false
  }
}
