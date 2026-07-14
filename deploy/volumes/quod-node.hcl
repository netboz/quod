## CSI Ceph RBD volume template for the homogeneous quod-node group.
##
## The Nomad group uses `source = "quod-node"` with `per_alloc = true`, so
## allocation index i claims volume `quod-node[i]`. Both `id` and `name` must be
## unique because the CSI plugin provisions the Ceph RBD image by name.
##
## Create a fresh eight-node volume set with:
##   NODE_COUNT=8
##   for i in $(seq 0 $((NODE_COUNT - 1))); do
##     sed "s/quod-node\[0\]/quod-node[$i]/; s/quod-node-0/quod-node-$i/" \
##       deploy/volumes/quod-node.hcl | \
##       NOMAD_ADDR=http://192.168.1.10:4646 nomad volume create -
##   done

id        = "quod-node[0]"
name      = "quod-node-0"
type      = "csi"
plugin_id = "ceph-rbd"

capacity_min = "1G"
capacity_max = "2G"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

secrets {
  userID  = "nomad-csi"
  userKey = "AQDctJhpNaNNMBAAvHEwc8gfWQxTU06YgnLtNg=="
}

parameters {
  clusterID     = "bcb4ff5c-9ece-11f0-8588-a4badb3f905a"
  pool          = "nomad-pool"
  imageFeatures = "layering"
  mkfsOptions   = "-t ext4"
}
