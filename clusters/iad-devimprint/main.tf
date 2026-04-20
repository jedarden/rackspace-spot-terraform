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
  default     = "gp.vs1.large-iad"
  description = "Node server class. Default: gp.vs1.large-iad (4 CPU, 15GB, $0.001/hr) — sized for devimprint pipeline."
}

variable "node_count" {
  type        = number
  default     = 1
  description = "Desired spot node count."
}

variable "bid_price" {
  type    = number
  default = 0.001
}

# Manage only the nodepool — the cloudspace already exists and cannot be
# modified post-creation via Terraform (admission webhook rejects all changes).
# The cloudspace_name is passed as a static string; no cloudspace resource needed.
resource "spot_spotnodepool" "workers" {
  cloudspace_name      = "iad-devimprint"
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}
