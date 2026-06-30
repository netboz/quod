variable "image_tag" {
  type        = string
  default     = "0.6.8"
  description = "quod image tag in the cluster registry. 0.6.8 = identity A.3 KEYSTONE: node_id = pubkey (address demoted to a resolvable hint; resolver cache + peercert bind; Brahms stays address-based)."
}

# ============================================================================
# quod — quod:root committee + read tier (founder + joiner + read-replica).
#
# group "quod-root" (FOUNDER) — content.mode=create: founds quod:root on an empty
#   volume (genesis incl. can_join), leads a 1-voter committee.
# group "quod-join" (JOINER) — content.mode=join: joins as a VOTER (learner→promote)
#   → a 2-voter committee.
# group "quod-replica" (READ TIER) — content.role=replica: joins as a permanent
#   NON-voting full-copy replica ({add_replica}, never promoted), serves reads
#   locally. Reads never touch consensus.
#
# Each group binds a DISTINCT static p2p/metrics port (root 14567/8, join 14569/70,
# replica 14571/2) so MULTIPLE quod nodes can share a host — the node's identity is
# its Ed25519 pubkey (not its address), so the port is just where it listens. No
# distinct_hosts pinning: Nomad may bin-pack several nodes onto one host. Seeds come
# from Nomad service discovery (`service "quod"` → each node's actual ip:port).
#
# Volumes pre-created (wipe + recreate on a clean re-found — greenfield, no
# backward compat):
#   nomad volume create deploy/volumes/quod-root.hcl
#   nomad volume create deploy/volumes/quod-join.hcl
#   nomad volume create deploy/volumes/quod-replica.hcl
# ============================================================================
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  group "quod-root" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }

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

      template {
        data = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
QUOD_DIST_NAME=quod_14567_0@{{ env "attr.unique.network.ip-address" }}
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

  group "quod-join" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }

    network {
      mode = "host"
      port "p2p"     { static = 14569 }
      port "metrics" { static = 14570 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-join"
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

      template {
        data = <<-EOT
node {
  ip   = "{{ env "attr.unique.network.ip-address" }}"
  port = 14569
}
metrics { port = 14570 }
content {
  namespace = "quod:root"
  mode      = join
  data_dir  = "/quod/data"
  seeds     = [{{ range $i, $s := service "quod" }}{{ if $i }}, {{ end }}"{{ .Address }}:{{ .Port }}"{{ end }}]
}
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "restart"
      }

      template {
        data = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
QUOD_DIST_NAME=quod_14569_1@{{ env "attr.unique.network.ip-address" }}
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
        tags = ["quod", "content", "quic", "p2p", "joiner"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "joiner"]

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

  group "quod-replica" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }

    network {
      mode = "host"
      port "p2p"     { static = 14571 }
      port "metrics" { static = 14572 }
    }

    volume "quod-data" {
      type            = "csi"
      source          = "quod-replica"
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

      template {
        data = <<-EOT
node {
  ip   = "{{ env "attr.unique.network.ip-address" }}"
  port = 14571
}
metrics { port = 14572 }
content {
  namespace = "quod:root"
  mode      = join
  role      = replica
  data_dir  = "/quod/data"
  seeds     = [{{ range $i, $s := service "quod" }}{{ if $i }}, {{ end }}"{{ .Address }}:{{ .Port }}"{{ end }}]
}
EOT
        destination = "${NOMAD_TASK_DIR}/quod.conf"
        change_mode = "restart"
      }

      template {
        data = <<-EOT
QUOD_CONF={{ env "NOMAD_TASK_DIR" }}/quod.conf
QUOD_DIST_NAME=quod_14571_2@{{ env "attr.unique.network.ip-address" }}
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
        tags = ["quod", "content", "quic", "p2p", "replica"]
      }

      service {
        name = "quod-metrics"
        port = "metrics"
        tags = ["quod", "metrics", "prometheus", "replica"]

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
