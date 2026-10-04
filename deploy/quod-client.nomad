# Stable browser origin; backend TLS, identity and application state stay in Quod.
variable "job_name" {
  type = string
}

variable "datacenter" {
  type = string
}

variable "node_id" {
  type        = string
  description = "Nomad node that owns the browser origin's fixed IP address."
}

variable "listen_ip" {
  type = string
}

variable "https_port" {
  type = number
}

variable "backend_service" {
  type = string
}

variable "backend_tag" {
  type        = string
  description = "Selects one durable Quod gateway identity, including group/index."
}

variable "traefik_image" {
  type = string
  validation {
    condition     = var.traefik_image != "" && regex_replace(var.traefik_image, "^.+@sha256:[a-f0-9]{64}$", "") == ""
    error_message = "Pin Traefik to the verified immutable image digest."
  }
}

job "quod-client" {
  id          = var.job_name
  name        = var.job_name
  namespace   = "default"
  datacenters = [var.datacenter]
  type        = "service"

  group "ingress" {
    count = 1

    constraint {
      attribute = "${node.unique.id}"
      value     = var.node_id
    }

    network {
      mode = "host"
      port "client" {
        static = var.https_port
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = var.traefik_image
        network_mode = "host"
        ports        = ["client"]
        # Mount the directory: template updates replace the file atomically.
        volumes = ["local/dynamic:/etc/traefik/dynamic:ro"]
        args = [
          "--entrypoints.client.address=${var.listen_ip}:${var.https_port}",
          "--providers.file.directory=/etc/traefik/dynamic",
          "--providers.file.watch=true",
          "--log.level=INFO",
          "--global.sendanonymoususage=false",
          "--global.checknewversion=false",
        ]
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = var.job_name
        provider = "consul"
        port     = "client"
        tags     = ["quod", "ingress"]

        # The listener can be ready while maintenance deliberately has no backend.
        check {
          name     = "reserved listener"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }

      template {
        destination = "local/dynamic/client.yml"
        change_mode = "noop"
        perms       = "0644"
        # Never distribute one browser session across independent gateway owners.
        # Missing or ambiguous ownership removes the route instead of picking one.
        data = <<-EOT
{{- $backends := service "${var.backend_tag}.${var.backend_service}" -}}
{{- if eq (len $backends) 1 }}
tcp:
  routers:
    client:
      entryPoints: [client]
      rule: "HostSNI(`*`)"
      service: client
      tls:
        passthrough: true
  services:
    client:
      loadBalancer:
        servers:
{{- range $backends }}
          - address: "{{ .Address }}:{{ .Port }}"
{{- end }}
{{- else }}
tcp: {}
{{- end }}
EOT
      }
    }
  }
}
