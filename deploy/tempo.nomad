# Grafana Tempo — trace backend for quod's OpenTelemetry spans.
#
# quod nodes export OTLP/HTTP to `tempo-otlp.service.consul:4318` (see deploy/quod.nomad).
# Consul A-records carry no port, so the OTLP receiver MUST bind host port 4318 exactly;
# the query API (used by the Grafana datasource) is on 3200. Single-binary, local storage,
# short retention — this is a load-test/measurement backend, not long-term trace storage.
#
# Deploy:  NOMAD_ADDR=http://192.168.1.10:4646 nomad job run deploy/tempo.nomad
# Remove:  nomad job stop -purge tempo

job "tempo" {
  datacenters = ["qengho"]
  type        = "service"

  group "tempo" {
    count = 1

    network {
      mode = "bridge"
      port "http" {
        static = 3200
        to     = 3200
      }
      port "otlp_http" {
        static = 4318
        to     = 4318
      }
      port "otlp_grpc" {
        static = 4317
        to     = 4317
      }
    }

    # Query API — the Grafana Tempo datasource points here (tempo.service.consul:3200).
    service {
      name = "tempo"
      port = "http"
      tags = ["traces", "grafana-datasource"]
      check {
        type     = "http"
        path     = "/ready"
        interval = "15s"
        timeout  = "3s"
      }
    }

    # OTLP/HTTP ingest — quod nodes export here (tempo-otlp.service.consul:4318).
    service {
      name = "tempo-otlp"
      port = "otlp_http"
      tags = ["otlp", "ingest"]
    }

    ephemeral_disk {
      size = 2000
    }

    task "tempo" {
      driver = "docker"

      config {
        image   = "grafana/tempo:2.6.1"
        ports   = ["http", "otlp_http", "otlp_grpc"]
        args    = ["-config.file=/local/tempo.yaml"]
      }

      template {
        destination = "local/tempo.yaml"
        data        = <<-EOT
        server:
          http_listen_port: 3200

        distributor:
          receivers:
            otlp:
              protocols:
                http:
                  endpoint: 0.0.0.0:4318
                grpc:
                  endpoint: 0.0.0.0:4317

        ingester:
          max_block_duration: 2m

        compactor:
          compaction:
            block_retention: 2h

        storage:
          trace:
            backend: local
            local:
              path: /alloc/data/tempo/blocks
            wal:
              path: /alloc/data/tempo/wal

        usage_report:
          reporting_enabled: false
        EOT
      }

      resources {
        cpu    = 500
        memory = 768
      }
    }
  }
}
