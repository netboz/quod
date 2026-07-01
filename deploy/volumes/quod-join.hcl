## CSI Ceph RBD volume TEMPLATE for the quod-join group (the joiner voters).
##
## The quod-join group is count=var.voters with per_alloc=true, so it claims one volume
## per alloc: quod-join[0], quod-join[1], … quod-join[N-1]. This file declares index 0.
## BOTH the Nomad `id` AND the CSI `name` must be unique per index — the `name` is what the
## CSI plugin provisions the RBD image against, so a shared name dedups all indices onto ONE
## image. Create the rest by substituting the index (greenfield — wipe + recreate on a re-found):
##   for i in $(seq 0 5); do
##     sed "s/quod-join\[0\]/quod-join[$i]/; s/quod-join-0/quod-join-$i/" deploy/volumes/quod-join.hcl | \
##       NOMAD_ADDR=http://192.168.1.10:4646 nomad volume create -
##   done
##
## Same Ceph cluster / pool / user as quod-root.hcl — a per-node durable ledger. On first
## boot /quod/data is empty + content.mode=join ⇒ the node dials the committee (seeds), is
## admitted as a learner, syncs genesis + history, and is promoted to a voter. Every later
## boot finds durable state ⇒ replay + catch up the delta (never re-join from scratch).

id        = "quod-join[0]"
name      = "quod-join-0"
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
