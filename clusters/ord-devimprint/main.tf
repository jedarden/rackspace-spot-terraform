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

variable "postgres_server_class" {
  type        = string
  default     = "mh.vs1.large-ord"
  description = "Dedicated Postgres node server class. Default: mh.vs1.large-ord (4 CPU, 30GB, $0.006/hr at p50)."
}

variable "postgres_bid_price" {
  type        = number
  default     = 0.006
  description = "Bid price for dedicated Postgres node at p50 market price (per cg-1i8t)."
}

variable "postgres_node_count" {
  type        = number
  default     = 1
  description = "Dedicated Postgres node count (instances: 1 per cg-25cp decision)."
}

# Manage only the nodepool — the cloudspace already exists and cannot be
# modified post-creation via Terraform (admission webhook rejects all changes).
# The cloudspace_name is passed as a static string; no cloudspace resource needed.
#
# The ord-devimprint cloudspace (us-central-ord-1, Chicago) replaced the
# iad-devimprint cloudspace (us-east-iad-1) on 2026-04-22. This config
# manages its nodepool going forward.
resource "spot_spotnodepool" "workers" {
  cloudspace_name      = "ord-devimprint"
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}

# Dedicated Postgres nodepool for commitgraph v2 redesign (Phase 0).
# This is the sole write target for clone-worker rollup upserts.
# Per cg-1i8t: bid at p50 ($0.006/hr) to minimize preemption risk given
# the no-fallback constraint (old pipeline decommissioned 2026-08-05).
# Per cg-25cp: instances: 1 with synchronous replication for zero-data-loss.
# Per cg-2ypl: if mh.vs1.large-ord fails to fulfill after 15 minutes,
# fall back to ch.vs1.large-ord (same capacity, compute-optimized).
resource "spot_spotnodepool" "postgres" {
  cloudspace_name      = "ord-devimprint"
  server_class         = var.postgres_server_class
  bid_price            = var.postgres_bid_price
  desired_server_count = var.postgres_node_count
}
