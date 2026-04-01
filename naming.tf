# BIP39-style random name for disposable clusters.
# Uses random_pet (single word) prefixed with "iad-".
# Override with var.cloudspace_name for explicit naming.

resource "random_pet" "cluster" {
  length    = 1
  separator = "-"
}

locals {
  cloudspace_name = var.cloudspace_name != "" ? var.cloudspace_name : "iad-${random_pet.cluster.id}"
}
