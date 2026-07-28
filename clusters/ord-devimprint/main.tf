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
resource "spot_spotnodepool" "workers" {
  cloudspace_name      = "ord-devimprint"
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}
