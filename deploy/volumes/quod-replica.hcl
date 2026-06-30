## CSI Ceph RBD volume for the quod READ-REPLICA alloc (the read tier).
##
## Same Ceph cluster / pool / user as quod-root.hcl. Holds a permanent NON-voting full-copy
## replica of quod:root: the node joins via the join path (content.role=replica → {add_replica}),
## catches up the full durable ledger, and serves reads locally — reads never touch consensus.
## Per-node durable copy so it replays + catches up across restart/migration.
##
## Create with:
##   NOMAD_ADDR=http://192.168.1.10:4646 \
##     nomad volume create deploy/volumes/quod-replica.hcl

id        = "quod-replica[0]"
name      = "quod-replica"
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
