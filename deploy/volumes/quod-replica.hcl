## CSI Ceph RBD volume reserved for a future quod read-observer alloc.
##
## Same Ceph cluster / pool / user as quod-root.hcl. There is no content.role=replica
## configuration now: all non-members use content.mode=join, recover the durable ledger,
## and remain read-only until a committed admission makes them voting validators.
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
