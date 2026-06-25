variable "image_tag" {
  type        = string
  default     = "0.4.19"
  description = "quod image tag in the cluster registry"
}

variable "namespace" {
  type        = string
  default     = "ont:test"
  description = "Brahms/ontology namespace every node joins"
}

variable "client_count" {
  type        = number
  default     = 0
  description = "Dynamic-port nodes beyond the 3 static seeds (total = 3 + client_count). Default 0 so the seeds come up alone; scale up incrementally with `nomad job scale quod quod-client N` and watch the mesh grow."
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
      port "metrics" {
        static = 14568
      }
    }

    task "quod" {
      driver = "docker"

      config {
        image        = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull   = true
        network_mode = "host"
        ports        = ["p2p", "metrics"]
      }

      # node_id is this node's own dialable address. Seeds are discovered from
      # Consul (service `quod`) instead of hardcoded — a node picks up every
      # currently-registered peer and filters itself out. change_mode noop:
      # Brahms reads seeds once at join then gossips, so a Consul membership
      # change must NOT restart a running node.
      template {
        data = <<-EOT
QUOD_NODE_IP={{ env "attr.unique.network.ip-address" }}
QUOD_PORT=14567
QUOD_DIST_NAME=quod_14567@{{ env "attr.unique.network.ip-address" }}
QUOD_NAMESPACE=${var.namespace}
QUOD_SEEDS={{ range service "quod" }}{{ .Address }}:{{ .Port }} {{ end }}
EOT

        destination = "${NOMAD_TASK_DIR}/env"
        env         = true
        change_mode = "noop"
      }

      resources {
        cpu = 500
        # Pure-Erlang QUIC: a node sits around ~105 MB (the BEAM port table is
        # capped via `+Q` in vm.args, so Docker's huge default nofile no longer
        # preallocates ~1.5 GB). 256 reserve gives comfortable headroom.
        memory     = 256
        memory_max = 512
      }

      # QUIC p2p (UDP — no TCP check); liveness comes from the metrics endpoint.
      service {
        name = "quod"
        port = "p2p"
        tags = ["quod", "brahms", "quic", "p2p"]
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

    # Seeds roll ONE at a time: only 3 of them, and the clients gate on a healthy
    # seed, so the job-level max_parallel=5 (fine for the many clients) must not
    # apply here or all 3 seeds restart at once. Group-level update overrides it.
    update {
      max_parallel     = 1
      min_healthy_time = "15s"
      healthy_deadline = "3m"
      auto_revert      = true
    }
  }

  # ============================================================
  # Dynamic-port nodes — host network + dynamic ports (no `static`, no
  # `distinct_hosts`) so many co-locate per host. Mirrors bbsvx-client /
  # onia-join. node_id == {host_ip, dynamic p2p port}: QUIC binds AND advertises
  # that same host port, so there is no NAT (this is why host net, not bridge).
  # Both the seed list and the wait-for-seed gate come from Consul.
  # ============================================================
  group "quod-client" {
    count = var.client_count

    constraint {
      attribute = "${node.unique.name}"
      operator  = "regexp"
      value     = "^(caton|corin|conrad)$"
    }

    spread {
      attribute = "${node.unique.name}"
    }

    network {
      mode = "host"
      port "p2p" {}
      port "metrics" {}
    }

    # Gate boot until a healthy seed exists in Consul. QUIC is UDP, so we probe
    # the seed's TCP metrics port (service `quod-metrics`, which carries the
    # health check) — discovered via Consul, no hardcoded address.
    task "wait-for-seed" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      template {
        data = <<-EOT
{{ range $i, $s := service "quod-metrics" }}{{ if eq $i 0 }}SEED_HOST={{ .Address }}
SEED_PORT={{ .Port }}{{ end }}{{ end }}
EOT
        destination = "${NOMAD_TASK_DIR}/seed.env"
        env         = true
        change_mode = "noop"
      }

      config {
        image        = "alpine:3.19"
        network_mode = "host"
        command      = "sh"
        args = [
          "-c",
          "echo 'waiting for a quod seed (consul)...'; while [ -z \"$${SEED_HOST}\" ] || ! nc -z -w2 \"$${SEED_HOST}\" \"$${SEED_PORT}\" 2>/dev/null; do echo 'no healthy seed yet, sleeping 2s'; sleep 2; done; echo \"seed $${SEED_HOST}:$${SEED_PORT} up, proceeding\""
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
        image        = "192.168.1.11:5000/quod:${var.image_tag}"
        force_pull   = true
        network_mode = "host"
        ports        = ["p2p", "metrics"]
      }

      # Dynamic listener + dynamic metrics port (Nomad-assigned); seeds from
      # Consul. change_mode noop: see the seed group.
      template {
        data = <<-EOT
QUOD_NODE_IP={{ env "attr.unique.network.ip-address" }}
QUOD_PORT={{ env "NOMAD_PORT_p2p" }}
QUOD_METRICS_PORT={{ env "NOMAD_PORT_metrics" }}
QUOD_DIST_NAME=quod_{{ env "NOMAD_PORT_p2p" }}@{{ env "attr.unique.network.ip-address" }}
QUOD_NAMESPACE=${var.namespace}
QUOD_SEEDS={{ range service "quod" }}{{ .Address }}:{{ .Port }} {{ end }}
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
        tags = ["quod", "brahms", "quic", "p2p"]
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
    max_parallel     = 5
    min_healthy_time = "15s"
    healthy_deadline = "3m"
    auto_revert      = true
  }
}
