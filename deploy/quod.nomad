variable "image_tag" {
  type        = string
  default     = "0.7.3"
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
# `max_parallel=1` covers the entire fleet because there is only one task group.
# No permanent allocation has a root/founder role after bootstrap.
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  constraint {
    attribute = "${node.class}"
    value     = "compute"
  }

  group "quod-node" {
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

    # Who may start WITHOUT first waiting for a live peer. This is a DIFFERENT question
    # from `bootstrap` (which decides create-vs-join): it asks "is there an anchored fleet
    # to catch up from, and am I not its resume-anchor?". Skip the wait when there is no
    # anchored fleet yet (genesis_hash empty — the founding deploy, or a forgot-the-var
    # deploy where existing volumes just resume) OR this is allocation zero (its own
    # durable volume is the anchor source). Every OTHER allocation of an anchored fleet
    # waits for a current member so it has someone to catch up from.
    task "wait-for-peer" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
{{- range service "quod-metrics" }}
QUOD_PEER_HOST={{ .Address }}
QUOD_PEER_METRICS_PORT={{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/peer.env"
        change_mode = "noop"
      }

      config {
        image   = "alpine:3.19"
        command = "sh"
        args = [
          "-c",
          "if [ -z '${var.genesis_hash}' ] || [ \"$NOMAD_ALLOC_INDEX\" = 0 ]; then echo 'bootstrap allocation, no peer required'; exit 0; fi; while :; do unset QUOD_PEER_HOST QUOD_PEER_METRICS_PORT; . \"$NOMAD_TASK_DIR/peer.env\" 2>/dev/null || true; if [ -n \"$QUOD_PEER_HOST\" ] && nc -z -w2 \"$QUOD_PEER_HOST\" \"$QUOD_PEER_METRICS_PORT\" 2>/dev/null; then echo \"peer up at $QUOD_PEER_HOST:$QUOD_PEER_METRICS_PORT\"; exit 0; fi; echo 'peer not ready, sleeping 2s'; sleep 2; done"
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
content {
  namespace = "quod:root"
  data_dir  = "/quod/data"
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

  update {
    max_parallel      = 1
    health_check      = "checks"
    min_healthy_time  = "15s"
    healthy_deadline  = "15m"
    progress_deadline = "20m"
    auto_revert       = false
  }
}
