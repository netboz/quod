variable "image_tag" {
  type        = string
  default     = "0.1.0"
  description = "quod image tag in the cluster registry"
}

variable "namespace" {
  type        = string
  default     = "ont:test"
  description = "Brahms/ontology namespace every node joins"
}

# Static QUIC/UDP port. Static so node_id == {node_ip, port} is stable and the
# seed list below is predictable. quod is stateless -> no CSI volume.
job "quod" {
  datacenters = ["qengho"]
  type        = "service"

  group "quod" {
    count = 3

    # one instance per cluster server (caton/corin/conrad), never two on a host
    # (they'd collide on the static port).
    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }
    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    network {
      mode = "host"
      port "p2p" {
        static = 14567
      }
    }

    task "quod" {
      driver = "docker"

      config {
        image        = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull   = true
        network_mode = "host"
        ports        = ["p2p"]
      }

      # node_id is this node's own dialable address; seeds are all three nodes
      # (each filters itself out). Static seeds avoid a discovery bootstrap race.
      template {
        data = <<-EOT
QUOD_NODE_IP={{ env "attr.unique.network.ip-address" }}
QUOD_PORT=14567
QUOD_NAMESPACE=${var.namespace}
QUOD_SEEDS=192.168.1.10:14567 192.168.1.11:14567 192.168.1.12:14567
EOT

        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
      }

      resources {
        cpu = 500
        # NOTE: on the 16-core cluster nodes the quicer/msquic datapath
        # pre-allocates ~2.1 GB of UDP buffer pools at startup (fixed, not
        # core-scaled; ~75 MB on an 8-core dev box). Until that is tuned down in
        # quicer, the reserve must clear it or the node is OOM-killed on boot.
        memory     = 3072
        memory_max = 3072
      }

      # Informational Consul service (QUIC is UDP, so no TCP health check yet).
      service {
        name = "quod"
        port = "p2p"
        tags = ["quod", "brahms", "quic", "p2p"]
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
