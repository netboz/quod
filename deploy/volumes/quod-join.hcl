## CSI Ceph RBD volume for the quod JOINER alloc (the second committee member).
##
## Same Ceph cluster / pool / user as quod-root.hcl — a per-node durable ledger for
## the joining node. On first boot /quod/data is empty + content.mode=join ⇒ the node
## dials the founder (seeds), is admitted as a learner, syncs the genesis + history,
## and is promoted to a voter. Every later boot finds durable state ⇒ replay + catch
## up the delta (never re-join from scratch). Separate volume from the founder's so
## each member keeps its own copy of the replicated ledger.
##
## Create with:
##   NOMAD_ADDR=http://192.168.1.10:4646 \
##     nomad volume create deploy/volumes/quod-join.hcl

id        = "quod-join[0]"
name      = "quod-join"
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
