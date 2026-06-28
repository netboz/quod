variable "image_tag" {
  type        = string
  default     = "latest"
  description = "quod image tag in the cluster registry. Build+push a NEW image from the content-layer branch (the old 0.4.19 is membership-only, pre-HOCON)."
}

# ============================================================================
# quod — content-layer first deploy: a SINGLE content-root.
#
# Content create is single-node until the join/sync path is built, so exactly
# one alloc founds and serves quod:root. It boots content.mode=create, reads
# priv/ontologies/quod_root.pl ONCE, and commits the genesis into the durable
# ledger on a Ceph RBD CSI volume mounted at /quod/data. The CSI volume makes
# "create once" hold across restarts/migration: on first boot /quod/data is
# empty ⇒ create; every later boot finds durable state ⇒ replay (join), never
# re-create. Expand to a mesh once join/sync lands.
#
# Config is the HOCON file rendered below + QUOD_CONF (the old QUOD_NODE_IP /
# QUOD_NAMESPACE / QUOD_SEEDS env vars are gone — config is a file now, env only
# overrides via QUOD_<PATH> keys). The image ships priv/ontologies/quod_root.pl.
#
# Volume pre-created with: nomad volume create deploy/volumes/quod-root.hcl
# ============================================================================
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  group "quod-root" {
    count = 1

    # compute-class, always-on node (caton/corin/conrad). Single-node-writer CSI
    # attaches to whichever it lands on; one alloc ⇒ no contention.
    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }

    # Static QUIC/UDP port so node_id == {node_ip, 14567} is stable across reschedules.
    network {
      mode = "host"
      port "p2p"     { static = 14567 }
      port "metrics" { static = 14568 }
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
        image        = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull   = true
        network_mode = "host"
        ports        = ["p2p", "metrics"]
      }

      volume_mount {
        volume      = "quod-data"
        destination = "/quod/data"
        read_only   = false
      }

      # The HOCON config file. content.mode=create founds quod:root on the empty
      # volume; data_dir=/quod/data is the CSI mount (the durable ledger). seeds
      # empty — a single content node has no peers to discover yet.
      template {
        data = <<-EOT
node {
  ip   = "{{ env "attr.unique.network.ip-address" }}"
  port = 14567
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

      # Point the node at the rendered config; per-host dist name (shared EPMD).
      template {
        data = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
QUOD_DIST_NAME=quod_14567@{{ env "attr.unique.network.ip-address" }}
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
    auto_revert      = true
  }
}
