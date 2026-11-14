## Dynamic host-volume template for one compute allocation.
## README.md creates quod-node-local[0..N-1] from this file before running the job.

namespace = "default"
name      = "quod-node-local[3]"
type      = "host"
plugin_id = "mkdir"
node_id   = "3e390ebd-5557-a67c-b64e-07b728144297"

constraint {
  attribute = "${node.class}"
  value     = "compute"
}

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
