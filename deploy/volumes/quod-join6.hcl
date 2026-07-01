## CSI Ceph RBD volume for the quod SECOND JOINER alloc (the third committee member).
##
## Same Ceph cluster / pool / user as quod-root.hcl — a per-node durable ledger for the
## third voter. On first boot /quod/data is empty + content.mode=join ⇒ the node dials the
## committee (seeds), is admitted as a learner, syncs the genesis + history, and is promoted
## to a voter — taking the committee to THREE voters (quorum 2, tolerates one node down).
## Every later boot finds durable state ⇒ replay + catch up the delta (never re-join from
## scratch). Separate volume from the other members' so each keeps its own ledger copy.
##
## Create with:
##   NOMAD_ADDR=http://192.168.1.10:4646 \
##     nomad volume create deploy/volumes/quod-join6.hcl

id        = "quod-join6[0]"
name      = "quod-join6"
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
