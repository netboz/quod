variable "image_tag" {
  type        = string
  default     = "0.6.11"
  description = "quod image tag in the cluster registry. 0.6.11 = onia-pattern deploy: one count=N joiner group + bridge/portmap dynamic host ports (node.bind_port decouples the fixed container listen port from the advertised host port), replacing the copy-pasted per-voter groups. Scaling is now `-var=voters=N`."
}

variable "voters" {
  type        = number
  default     = 6
  description = "Number of JOINER voters (besides the single founder). Committee size = 1 + voters. Default 6 ⇒ a 7-voter committee (quorum 4, tolerates 3 down). Scale with `-var=voters=N` once quod-join[0..N-1] volumes are pre-created."
}

# ============================================================================
# quod — quod:root committee + read tier, onia-pattern deploy (mirrors onia's
# nomad job + bbsvx's root/client shape).
#
#  - group "quod-root" (count 1, content.mode=create) founds quod:root + leads a
#    1-voter committee; joiners discover it via the Consul service `quod`.
#  - group "quod-join" (count = var.voters, content.mode=join) each joins as a VOTER
#    (learner→catch-up→promote). Founder + N joiners = an (N+1)-voter committee, grown
#    LIVE (bumping var.voters admits one more, no re-found). `spread` distributes the
#    joiners across the compute nodes.
#  - group "quod-replica" (count 1, content.role=replica) a permanent NON-voting
#    full-copy read replica. Reads never touch consensus.
#
# Networking — bridge + CNI portmap (NOT host mode). QUIC binds a FIXED in-container
# port (node.bind_port = 14567); Nomad maps a DYNAMIC host port to it and quod ADVERTISES
# that host port (node.port = ${NOMAD_HOST_PORT_p2p}, NOT ${NOMAD_PORT_p2p} which is the
# in-container port) as its endpoint — the node's identity is
# its Ed25519 pubkey, the address is only where it's dialed. So any number of nodes
# co-locate on one host with NO port collision, and scaling is one number (var.voters)
# instead of a hand-written static-port group per voter. QUOD_DIST_NAME is left at the
# image default (quod@127.0.0.1): bridge gives each container its own netns + EPMD, so a
# per-host-unique name is no longer needed.
#
# Volumes — per_alloc CSI ceph RBD; a count=N group claims source[0..N-1]. Pre-create
# before `nomad job run` (greenfield — wipe + recreate on a re-found, no backward compat):
#   nomad volume create deploy/volumes/quod-root.hcl
#   nomad volume create deploy/volumes/quod-replica.hcl
#   for i in $(seq 0 5); do
#     sed "s/quod-join\[0\]/quod-join[$i]/" deploy/volumes/quod-join.hcl | nomad volume create -
#   done
# ============================================================================
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  # Compute-class nodes (caton/corin/conrad); excludes the GPU node (prospero).
  constraint {
    attribute = "${node.class}"
    value     = "compute"
  }

  group "quod-root" {
    count = 1

    network {
      mode = "bridge"
      port "p2p"     { to = 14567 }
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
        data = <<-EOT
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
        data = <<-EOT
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

  group "quod-join" {
    count = var.voters

    spread {
      attribute = "${node.unique.name}"
    }

    network {
      mode = "bridge"
      port "p2p"     { to = 14567 }
      port "metrics" { to = 14568 }
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
        data = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
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

    network {
      mode = "bridge"
      port "p2p"     { to = 14567 }
      port "metrics" { to = 14568 }
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
        data = <<-EOT
node {
  ip        = "{{ env "attr.unique.network.ip-address" }}"
  port      = {{ env "NOMAD_HOST_PORT_p2p" }}
  bind_port = 14567
}
metrics { port = 14568 }
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
