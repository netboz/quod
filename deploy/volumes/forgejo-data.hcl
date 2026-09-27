## Ceph RBD CSI volume for Forgejo, mounted at /data by deploy/forgejo.nomad:
## SQLite database, repositories, LFS, packages, sessions, indexers, custom dir.
## Thin-provisioned on the NAS pool; resize later with `nomad volume create` on
## the same id and a larger capacity_max (ceph-csi supports online expansion).
##
## Created once, from the repo root, with the Ceph key of client.nomad-csi
## substituted from outside the repository (see deploy/README.md):
##   perl -pe 's/__CEPH_CSI_USER_KEY__/$ENV{CEPH_CSI_USER_KEY}/' \
##     deploy/volumes/forgejo-data.hcl | nomad volume create -

id        = "forgejo-data"
name      = "forgejo-data"
type      = "csi"
plugin_id = "ceph-rbd"

capacity_min = "20G"
capacity_max = "20G"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

secrets {
  userID  = "nomad-csi"
  userKey = "__CEPH_CSI_USER_KEY__"
}

parameters {
  clusterID     = "bcb4ff5c-9ece-11f0-8588-a4badb3f905a"
  pool          = "nomad-pool"
  imageFeatures = "layering"
  mkfsOptions   = "-t ext4"
}
