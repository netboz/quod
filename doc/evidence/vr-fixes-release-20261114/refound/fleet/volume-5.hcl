## Dynamic host-volume template for one compute allocation.
## README.md creates quod-node-local[0..N-1] from this file before running the job.

namespace = "default"
name      = "quod-node-local[5]"
type      = "host"
plugin_id = "mkdir"
node_id   = "c8f9edef-853b-fc43-e3fb-d884418f7061"

constraint {
  attribute = "${node.class}"
  value     = "compute"
}

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
