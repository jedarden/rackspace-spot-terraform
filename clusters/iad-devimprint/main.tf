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

# Import the existing iad-devimprint cloudspace rather than recreating it.
import {
  to = spot_cloudspace.main
  id = "iad-devimprint"
}

resource "spot_cloudspace" "main" {
  cloudspace_name    = "iad-devimprint"
  region             = "us-east-iad-1"
  hacontrol_plane    = false
  wait_until_ready   = false
  kubernetes_version = "1.31.1"
  cni                = "calico"
}

# Import the existing nodepool (UUID from node label nodepool.ngpc.rxt.io/name).
import {
  to = spot_spotnodepool.workers
  id = "633096cd-fcaf-45b6-8c1b-2e62461b8652"
}

resource "spot_spotnodepool" "workers" {
  cloudspace_name      = spot_cloudspace.main.cloudspace_name
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}
