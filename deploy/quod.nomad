variable "image_tag" {
  type        = string
  default     = "0.6.15"
  description = "quod image tag in the cluster registry. 0.6.15 = block + transaction timestamps (leader-set commit time on #block/#entry, client submit time on #transaction, monotonic + future-bounded validation) on top of 0.6.14's de-Raft cleanup + dissemination feed (quod_feed) + shared transport send verb (quod_quic:send/3) + mode=join HOCON plumbing. NOTE: the new block fields change the genesis hash — re-found (wipe the quod-root/quod-join volumes) to deploy."
}

variable "join_count" {
  type        = number
  default     = 0
  description = "Number of mode=join follower nodes, beyond the single founder. Default 0: bring up the founder FIRST, read its genesis anchor from the boot log, then deploy joiners with `-var join_count=N -var genesis_hash=<hex>`."
}

variable "genesis_hash" {
  type        = string
  default     = ""
  description = "The founder's genesis block hash (64-char hex), copied from the founder's boot log line `quod[..]: genesis anchor — pin as content.genesis_hash: <hex>`. REQUIRED when join_count>0: it is the joiner's out-of-band trust anchor — a joiner verifies the whole downloaded history against this one pinned fingerprint, so a wrong/empty value makes it fail-fast (never a silent trust-on-first-use). Leave empty when join_count=0."
}

# ============================================================================
# quod — quod:root DispersedSimplex deploy: one founder + optional joiners.
#
#  - group "quod-root" (count 1, content.mode=create) founds quod:root as a
#    self-only 1-validator committee, applies its genesis, serves prove, and
#    LOGS its genesis anchor for joiners to pin.
#  - group "quod-join" (count var.join_count, content.mode=join) catches up the
#    founder's committed log TRUSTLESSLY (verifying every block's quorum cert
#    against the genesis anchor it was handed), then FOLLOWS live commits over
#    the dissemination feed (quod_feed) as a read-only observer. Discovers the
#    founder via the `quod` Consul service (p2p seed) and `quod-metrics` (a
#    `wait-for-root` prestart blocks until the founder's TCP metrics port is up).
#
# TWO-PHASE bring-up (the joiner's trust anchor is only known after the founder
# founds genesis, and must be pinned out-of-band — that is the whole point):
#   1. nomad job run deploy/quod.nomad                 # founder only (join_count=0)
#   2. nomad alloc logs <quod-root-alloc> | grep 'genesis anchor'   # copy the hex
#   3. nomad job run -var join_count=1 -var genesis_hash=<hex> deploy/quod.nomad
# A post-join write on the founder (e.g. a prove that asserts a fact) then
# demonstrates the live feed: the joiner picks the new block up over gossip.
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
  # Founder — mode=create. Founds quod:root, logs the genesis anchor.
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
        image      = "192.168.1.11:5000/quod:${var.image_tag}"
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
  mode         = create
  genesis_file = "ontologies/quod_root.pl"
  data_dir     = "/quod/data"
  seeds        = []
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

    # Block startup until the founder is up. We probe its TCP METRICS port (via the
    # `quod-metrics` Consul service), NOT the p2p port: p2p is QUIC-over-UDP and a TCP
    # scan (`nc -z`) can never connect to it — the founder's own QUIC dial + retry is
    # what validates p2p reachability. A live metrics port means the BEAM booted and the
    # namespace is up, which is exactly the "founder ready" signal we want to gate on.
    task "wait-for-root" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data        = <<-EOT
{{- range service "quod-metrics" }}
QUOD_ROOT_HOST={{ .Address }}
QUOD_ROOT_METRICS_PORT={{ .Port }}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/root.env"
        env         = true
        change_mode = "noop"
      }

      config {
        image   = "alpine:3.19"
        command = "sh"
        args = [
          "-c",
          "echo \"waiting for quod founder metrics at $${QUOD_ROOT_HOST}:$${QUOD_ROOT_METRICS_PORT}...\"; while [ -z \"$${QUOD_ROOT_HOST}\" ] || ! nc -z -w2 \"$${QUOD_ROOT_HOST}\" \"$${QUOD_ROOT_METRICS_PORT}\" 2>/dev/null; do echo 'founder not ready, sleeping 2s'; sleep 2; done; echo \"founder up, proceeding\""
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
        image      = "192.168.1.11:5000/quod:${var.image_tag}"
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
{{- range service "quod" }}
  seeds        = ["{{ .Address }}:{{ .Port }}"]
{{- end }}
  genesis_hash = "${var.genesis_hash}"
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
    max_parallel     = 1
    min_healthy_time = "15s"
    healthy_deadline = "3m"
    auto_revert      = false
  }
}
