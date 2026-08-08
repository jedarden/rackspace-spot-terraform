terraform {
  required_version = ">= 1.5"

  required_providers {
    spot = {
      source  = "rackerlabs/spot"
      version = ">= 0.1.0"
    }
  }
}

provider "spot" {
  token = var.rackspace_spot_token
}

variable "rackspace_spot_token" {
  type      = string
  sensitive = true
}

variable "server_class" {
  type        = string
  default     = "ch.vs1.medium-ord"
  description = "Node server class. Default: ch.vs1.medium-ord (2 CPU, 3.75GB, $0.001/hr)."
}

variable "node_count" {
  type        = number
  default     = 6
  description = "Desired spot node count."
}

variable "bid_price" {
  type    = number
  default = 0.001
}

# Manage only the nodepool — the cloudspace already exists and cannot be
# modified post-creation via Terraform (admission webhook rejects all changes).
# The cloudspace_name is passed as a static string; no cloudspace resource needed.
#
# The ord-devimprint cloudspace (us-central-ord-1, Chicago) replaced the
# iad-devimprint cloudspace (us-east-iad-1) on 2026-04-22. This config
# manages its nodepool going forward.

# General worker nodepool for mixed workloads
resource "spot_spotnodepool" "workers" {
  cloudspace_name      = "ord-devimprint"
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}

# Postgres-dedicated nodepool (mh.vs1.large-ord: 4 CPU, 30GB)
# See plan.md "Postgres provisioning" section for rationale and decisions.
# Fallback class: ch.vs1.large-ord with 15-minute trigger (cg-2ypl, resolved 2026-08-06)
# Bid price: $0.005/hr (market price for mh.vs1.large-ord; cg-1i8t, resolved 2026-08-06)
resource "spot_spotnodepool" "postgres" {
  cloudspace_name      = "ord-devimprint"
  server_class         = "mh.vs1.large-ord"
  bid_price            = 0.02
  desired_server_count = 1
}
