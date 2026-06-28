## CSI Ceph RBD volume for the quod content-root alloc (the founder).
##
## Direct port of onia-root.hcl / bbsvx-root.hcl — same Ceph cluster, same
## nomad-pool, same nomad-csi user. Holds the durable per-namespace LEDGER
## (CRC-framed block log under {content, data_dir} → /quod/data). The founder
## reads priv/ontologies/quod_root.pl once and commits the genesis into this
## ledger; it must survive node migration, so it's a network block device, not
## an ephemeral host path. 1-2 GiB is generous for the alpha (the ledger is just
## the ordered transaction log; no mnesia, no blobs).
##
## Create with:
##   NOMAD_ADDR=http://192.168.1.10:4646 \
##     nomad volume create deploy/volumes/quod-root.hcl

id        = "quod-root[0]"
name      = "quod-root"
type      = "csi"
plugin_id = "ceph-rbd"

capacity_min = "1G"
capacity_max = "2G"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

## Inline Ceph userKey — matches the homelab convention every other service
## volume HCL uses (onia-root, bbsvx-root, …). Single-operator private cluster;
## a cluster-wide migration to Nomad Variables/Vault is planned separately.
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
