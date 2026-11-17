job "quod-hostvol-check-20261104" {
  datacenters = ["qengho"]
  type = "sysbatch"
  constraint {
    attribute = "${node.class}"
    value = "compute"
  }
  group "check" {
    task "list" {
      driver = "docker"
      config {
        image = "alpine:3.19"
        command = "/bin/sh"
        args = ["-c", "echo host=$(cat /etc/hostname); ls -1 /hv"]
        volumes = ["/var/lib/nomad/host_volumes:/hv:ro"]
      }
      resources {
        cpu = 50
        memory = 32
      }
    }
  }
}
