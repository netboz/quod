job "quod-cloud-ledger-cleanup-20261114" {
  datacenters = ["qengho"]
  type = "batch"
  group "cleanup" {
    count = 1
    constraint {
      attribute = "${node.unique.id}"
      value = "e37f93bb-03a2-4384-e61a-b4648d5a24d2"
    }
    volume "cloud-data" {
      type = "host"
      source = "quod-node-cloud"
      read_only = false
    }
    task "remove-old-ledgers" {
      driver = "docker"
      config {
        image = "alpine:3.19"
        command = "/bin/sh"
        args = ["-ec", "set -eu; cd /quod/data; test -d 0; test ! -L 0; test -d 1; test ! -L 1; set -- *; test \"$#\" -eq 2; test \"$1\" = 0; test \"$2\" = 1; rm -rf -- 0 1; test ! -e 0; test ! -e 1; echo old-cloud-ledgers-removed"]
      }
      volume_mount {
        volume = "cloud-data"
        destination = "/quod/data"
        read_only = false
      }
      resources {
        cpu = 100
        memory = 64
      }
    }
  }
}
