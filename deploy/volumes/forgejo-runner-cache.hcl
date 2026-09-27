## Ceph RBD CSI volume for the Forgejo runner, mounted at /cache by
## deploy/forgejo-runner.nomad: the runner-served actions cache that holds the
## gates workflow's rebar3 hex cache and dialyzer PLT between runs. Disposable:
## losing it only costs one cold run.
##
## Created once, from the repo root, with the Ceph key of client.nomad-csi
## substituted from outside the repository (see deploy/README.md):
##   perl -pe 's/__CEPH_CSI_USER_KEY__/$ENV{CEPH_CSI_USER_KEY}/' \
##     deploy/volumes/forgejo-runner-cache.hcl | nomad volume create -

id        = "forgejo-runner-cache"
name      = "forgejo-runner-cache"
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
