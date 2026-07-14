variable "image_tag" {
  type        = string
  default     = "0.6.39"
  description = "Quod image tag in the cluster registry. 0.6.39 unifies boot and runtime recovery: a node may vote only after quorum-correlated tip recovery, and committee catch-up replies are identity-bound. No ledger or wire-format change; use the serialized rolling update below."
}

variable "image_registry" {
  type        = string
  default     = "192.168.1.11:5000"
  description = "Registry hostname and port containing the quod image. Override this when deploying outside the home cluster."
}

variable "join_count" {
  type        = number
  default     = 0
  description = "Number of mode=join follower nodes, beyond the single founder. Default 0: bring up the founder FIRST, read its genesis anchor from the boot log, then deploy joiners with `-var join_count=N -var genesis_hash=<hex>`."
}

variable "genesis_hash" {
  type        = string
  default     = ""
  description = "The founder's genesis block hash (64-char hex), copied from the founder's boot log line `quod[..]: genesis anchor — pin as content.genesis_hash: <hex>`. REQUIRED when join_count>0 OR root_mode=join: it is a joiner's out-of-band trust anchor — a joiner verifies the whole downloaded history against this one pinned fingerprint, so a wrong/empty value makes it fail-fast (never a silent trust-on-first-use). Leave empty ONLY for the very first founder deploy (root_mode=create, join_count=0)."
}

variable "root_mode" {
  type        = string
  default     = "join"
  description = "content.mode for the quod-root group. The safe default is `join`: after bootstrap, every node resumes from durable state or trustlessly catches up against the pinned anchor. Pass `-var root_mode=create` ONLY for the FIRST deploy that founds genesis, then re-deploy with `-var root_mode=join -var genesis_hash=<hex>`. A `create` node whose CSI volume is wiped can silently re-found a divergent genesis. Requires genesis_hash when set to join."
}

# ============================================================================
# quod — quod:root DispersedSimplex deploy: one founder + optional joiners.
#
#  - group "quod-root" (count 1) is the ROOT node. mode=${var.root_mode}:
#    `create` (first deploy only) founds quod:root as a self-only 1-validator
#    committee, applies its genesis, and LOGS its genesis anchor to pin. AFTER
#    genesis exists, and ESPECIALLY after the committee has grown past N=1, this
#    group MUST be re-deployed as mode=join (`-var root_mode=join`): a `create`
#    node whose CSI volume is ever wiped would silently RE-FOUND a DIVERGENT
#    genesis (a catastrophic fork). mode=join resumes from the volume if present,
#    else catches up trustlessly against the pinned anchor — same as any member.
#  - group "quod-join" (count var.join_count, mode=join) catches up the committed
#    log TRUSTLESSLY (verifying every block's quorum cert against the genesis
#    anchor), then FOLLOWS live commits over the feed. Once ADMITTED to the
#    committee (an existing member proves `admit`, gated by the peer_ready
#    readiness rule) a joiner self-PROMOTES to a voting validator.
#  Both groups seed from BOTH the `quod` and `quod-join` Consul services, so any
#  member can reach any other member — the homogeneous end-state is EVERY node
#  mode=join, no permanent `create` node.
#
# BOOTSTRAP (the trust anchor is only known after the founder founds genesis, and
# is pinned out-of-band — that is the whole point):
#   1. nomad job run -var root_mode=create deploy/quod.nomad  # founder only
#   2. nomad alloc logs <quod-root-alloc> | grep 'genesis anchor'   # copy the hex
#   3. nomad job run -var root_mode=join -var join_count=N -var genesis_hash=<hex> deploy/quod.nomad
# GROW the committee live (supervised): on the founder, upgrade the can_join rule
# to peer_ready (one atomic tx), then `admit` caught-up joiners one at a time;
# each self-promotes to a voter (watch quod_consensus_is_validator / committee_size).
# POST-GROWTH REDEPLOY — flip the bootstrap node to a plain member so a volume
# wipe can never re-found:
#   nomad job run -var root_mode=join -var genesis_hash=<hex> -var join_count=N deploy/quod.nomad
#
# Networking — bridge + CNI portmap (NOT host mode). QUIC binds a FIXED
# in-container port (node.bind_port = 14567); Nomad maps a DYNAMIC host port and
# quod ADVERTISES that host port (node.port = ${NOMAD_HOST_PORT_p2p}) as its
# endpoint — identity is the Ed25519 pubkey, the address is only where it's dialed.
#
# Volumes — per_alloc CSI ceph RBD (`quod-root`, `quod-join`). The on-disk block
# log format changed with the de-Raft cleanup (#entry dropped its Raft term/kind
# fields), so any volume written by an older image (≤ 0.6.13) MUST be wiped:
#   nomad job stop -purge quod
#   nomad volume delete quod-root[0]        # and quod-join[0] if it exists
#   nomad volume create deploy/volumes/quod-root.hcl
#   nomad volume create deploy/volumes/quod-join.hcl
# ============================================================================
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  # Compute-class nodes (caton/corin/conrad); excludes the GPU node (prospero).
  constraint {
    attribute = "${node.class}"
    value     = "compute"
  }

  # ==========================================================================
  # Root — mode=${var.root_mode}. Bootstrap with create, then keep it as a joiner.
  # ==========================================================================
  group "quod-root" {
    count = 1

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-root"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      per_alloc       = true
    }

    task "quod" {
      driver = "docker"

      config {
        image      = "${var.image_registry}/quod:${var.image_tag}"
        force_pull = true
        ports      = ["p2p", "metrics"]
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
content {
  namespace    = "quod:root"
  mode         = ${var.root_mode}
  data_dir     = "/quod/data"
%{if var.root_mode == "create"}
  genesis_file = "ontologies/quod_root.pl"
  seeds        = []
%{else}
  genesis_hash = "${var.genesis_hash}"
  seeds        = [
{{- range service "quod" }}
    "{{ .Address }}:{{ .Port }}",
{{- end }}
{{- range service "quod-join" }}
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
        tags = ["quod", "content", "quic", "p2p", "founder"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "founder"]

        check {
          type     = "http"
          path     = "/metrics"
          interval = "15s"
          timeout  = "3s"
        }

        # A responsive metrics endpoint is not sufficient during a rolling update:
        # a recovering validator is deliberately unable to vote. Keep max_parallel=1
        # from advancing until recovery has corroborated the local ledger tip.
        check {
          name     = "consensus-ready"
          type     = "script"
          command  = "/bin/sh"
          args     = ["-ec", "curl -fsS --max-time 2 http://127.0.0.1:14568/metrics | awk '$1 ~ /^quod_consensus_syncing\\{/ { seen=1; if ($2 != 0) bad=1 } END { exit !(seen && !bad) }'"]
          interval = "5s"
          timeout  = "5s"
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

  # ==========================================================================
  # Joiners — mode=join. Trustless catch-up + live feed-follow (read-only).
  # Deployed only when join_count>0 AND genesis_hash is set (see the header).
  # ==========================================================================
  group "quod-join" {
    count = var.join_count

    spread {
      attribute = "${node.unique.name}"
    }

    network {
      mode = "bridge"
      port "p2p" { to = 14567 }
      port "metrics" { to = 14568 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-join"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      per_alloc       = true
    }

    # Block startup until a current member is up. We probe its TCP METRICS port (via the
    # `quod-metrics` Consul service), NOT the p2p port: p2p is QUIC-over-UDP and a TCP
    # scan (`nc -z`) can never connect to it. A live metrics port means the BEAM booted
    # and the namespace is up, which is exactly the startup signal we need here.
    task "wait-for-root" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      # This file stays live as Consul changes. The task rereads it on each retry;
      # using `env = true` would freeze an empty first render for the task lifetime.
      template {
        data        = <<-EOT
{{- range service "quod-metrics" }}
QUOD_ROOT_HOST={{ .Address }}
QUOD_ROOT_METRICS_PORT={{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/root.env"
        change_mode = "noop"
      }

      config {
        image   = "alpine:3.19"
        command = "sh"
        args = [
          "-c",
          "while :; do unset QUOD_ROOT_HOST QUOD_ROOT_METRICS_PORT; . \"$${NOMAD_TASK_DIR}/root.env\" 2>/dev/null || true; if [ -n \"$${QUOD_ROOT_HOST}\" ] && nc -z -w2 \"$${QUOD_ROOT_HOST}\" \"$${QUOD_ROOT_METRICS_PORT}\" 2>/dev/null; then echo \"founder up at $${QUOD_ROOT_HOST}:$${QUOD_ROOT_METRICS_PORT}, proceeding\"; exit 0; fi; echo 'founder not ready, sleeping 2s'; sleep 2; done"
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
        ports      = ["p2p", "metrics"]
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
content {
  namespace    = "quod:root"
  mode         = join
  data_dir     = "/quod/data"
  genesis_hash = "${var.genesis_hash}"
  seeds        = [
{{- range service "quod" }}
    "{{ .Address }}:{{ .Port }}",
{{- end }}
{{- range service "quod-join" }}
    "{{ .Address }}:{{ .Port }}",
{{- end }}
  ]
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
        name = "quod-join"
        port = "p2p"
        tags = ["quod", "content", "quic", "p2p", "join"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "join"]

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
