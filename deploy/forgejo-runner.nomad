# Forgejo Runner: executes .forgejo/workflows/* for the `quod` organisation on
# http://forgejo.service.consul (deploy/forgejo.nomad).
#
# Placement: corin only. Job containers are started through the host's Docker socket,
# so they live OUTSIDE Nomad's resource accounting; the runner config below caps each
# job container (container.options) and corin is the one compute node with the headroom.
#
# Registration: the runner regenerates its identity from a shared secret at every start
# (`forgejo-runner create-runner-file`), so no registration state persists. The secret was
# created and registered server-side with
#   forgejo forgejo-cli actions generate-secret
#   forgejo forgejo-cli actions register --secret <secret> --name corin --scope quod --labels docker
# and lives with the cache secret in Nomad variable nomad/jobs/forgejo-runner.
#
# Cache: the runner's built-in actions cache server keeps its data on the Ceph RBD volume
# `forgejo-runner-cache` and serves actions/cache to job containers over HTTP, so the
# rebar3 hex cache and the dialyzer PLT survive between runs without any host path.
#
# SECURITY: the Docker socket is root on corin. Any workflow job that mounts it (the
# master release-image job does) can control every container on corin, including the
# Forgejo and quod allocations. Only trusted branches run here; see deploy/README.md.
#
# Deploy, from the repo root:
#   NOMAD_ADDR=http://192.168.1.10:4646 nomad job run deploy/forgejo-runner.nomad

variable "runner_version" {
  type        = string
  default     = "9.1.1"
  description = "Runner image tag on code.forgejo.org/forgejo/runner. Track the latest release."
}

variable "ci_image" {
  type        = string
  default     = "192.168.1.11:5000/quod-ci:28"
  description = "Image behind the `docker` label: every job runs in it unless the workflow says otherwise. Built from deploy/ci/Dockerfile."
}

variable "runner_log_level" {
  type        = string
  default     = "info"
  description = "Daemon and job log level; pass -var runner_log_level=debug to get act's per-step diagnostics in the allocation log and in the job logs."
}

variable "forgejo_url" {
  type    = string
  default = "http://forgejo.service.consul"
}

job "forgejo-runner" {
  datacenters = ["qengho"]
  type        = "service"
  priority    = 50

  group "runner" {
    count = 1

    constraint {
      attribute = "${node.unique.name}"
      value     = "corin"
    }

    update {
      max_parallel     = 1
      min_healthy_time = "30s"
      healthy_deadline = "5m"
      auto_revert      = true
    }

    # Host networking: job containers (on Docker's own bridge) reach the cache proxy at the
    # node's LAN address, and the runner resolves *.service.consul through the host.
    network {
      mode = "host"
      port "cache" {
        static = 8090
      }
      port "cache_proxy" {
        static = 8091
      }
    }

    volume "cache" {
      type            = "csi"
      source          = "forgejo-runner-cache"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

    service {
      name = "forgejo-runner"
      port = "cache"
      tags = ["forge", "ci", "actions-cache"]
      check {
        type     = "tcp"
        interval = "30s"
        timeout  = "5s"
      }
    }

    task "runner" {
      driver = "docker"

      # The socket on corin is root-owned; the runner image's own user (1000) cannot open it.
      user = "root"

      config {
        image        = "code.forgejo.org/forgejo/runner:${var.runner_version}"
        network_mode = "host"
        volumes      = ["/var/run/docker.sock:/var/run/docker.sock"]
        entrypoint   = ["/bin/sh", "-c"]
        args = [
          "set -e; cd /data && forgejo-runner create-runner-file --instance '${var.forgejo_url}' --secret \"$REGISTRATION_SECRET\" --name corin --connect && exec forgejo-runner daemon --config /local/config.yml"
        ]
      }

      volume_mount {
        volume      = "cache"
        destination = "/cache"
      }

      template {
        destination = "secrets/env"
        env         = true
        change_mode = "restart"
        data        = <<-EOT
        REGISTRATION_SECRET={{ with nomadVar "nomad/jobs/forgejo-runner" }}{{ .registration_secret }}{{ end }}
        EOT
      }

      template {
        destination = "local/config.yml"
        change_mode = "restart"
        data        = <<-EOT
        log:
          level: ${var.runner_log_level}
          job_level: ${var.runner_log_level}

        runner:
          file: .runner
          capacity: 1
          timeout: 90m
          fetch_timeout: 5s
          fetch_interval: 2s
          labels:
            - "docker:docker://${var.ci_image}"

        cache:
          enabled: true
          dir: /cache/actcache
          # Fixed so cache entries stay valid across runner restarts.
          secret: "{{ with nomadVar "nomad/jobs/forgejo-runner" }}{{ .cache_secret }}{{ end }}"
          host: "{{ env "attr.unique.network.ip-address" }}"
          port: {{ env "NOMAD_PORT_cache" }}
          proxy_port: {{ env "NOMAD_PORT_cache_proxy" }}

        container:
          network: ""
          privileged: false
          # Every job container is bounded here because Nomad does not see them.
          # - Memory: 6 GiB hard, no swap. eunit peaks near 2.6 GiB.
          # - CPU: a low weight, not a quota. A hard --cpus quota throttles the Erlang VM in
          #   bursts and the timing-sensitive tests fail; a weight lets CI use idle cores and
          #   yield to the quod and Forgejo tasks (Nomad weights them by their cpu MHz) when
          #   corin is busy.
          # - Open files: corin's Docker hands containers a limit of 1073741816, and the Erlang
          #   VM sizes its fd tables by it, about 2 GiB per VM (the eunit VM plus each peer VM a
          #   test starts). 65536 brings a VM back to about 40 MiB.
          options: "--memory=6g --memory-swap=6g --cpu-shares=256 --ulimit nofile=65536:65536"
          workdir_parent: ""
          # The only host path a workflow may mount: the release-image job needs the daemon.
          valid_volumes:
            - /var/run/docker.sock
          docker_host: "-"
          # Pull the job image every time so a rebuilt quod-ci:28 is picked up (LAN registry).
          force_pull: true

        host:
          workdir_parent: ""
        EOT
      }

      # The runner process and its cache proxy only; job containers are capped separately above.
      # Measured 2026-09-27: 14 MiB idle and while a job runs, but a 430 MiB spike while it
      # clones the checkout/cache action repositories in-process at job start; a 512 MiB cap
      # OOM-killed it once. 2 GiB leaves that spike room without reserving it permanently.
      resources {
        cpu        = 200
        memory     = 512
        memory_max = 2048
      }
    }
  }
}
