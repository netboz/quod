job "quod-old-cloud-ledger-cleanup-20261104" {
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
        args = ["-ec", "set -eu; cd /quod/data; test -d arch206; test ! -L arch206; test -d arch206/0; test ! -L arch206/0; test -d arch206/1; test ! -L arch206/1; set -- arch206/*; test \"$#\" -eq 2; test \"$1\" = arch206/0; test \"$2\" = arch206/1; rm -rf -- arch206/0 arch206/1; test ! -e arch206/0; test ! -e arch206/1; rmdir arch206; echo old-cloud-ledgers-removed"]
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
