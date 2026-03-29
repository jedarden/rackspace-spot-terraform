variable "rackspace_spot_token" {
  type        = string
  sensitive   = true
  description = "Rackspace Spot API refresh token"
}

variable "cloudspace_name" {
  type    = string
  default = "apexalgo-spot"
}

variable "region" {
  type    = string
  default = "us-east-iad-1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31.1"
}

variable "server_class" {
  type        = string
  default     = "mh.vs1.large-iad"
  description = "Rackspace Spot server class for worker nodes. Use spotctl serverclasses list to see options."
}

variable "node_count" {
  type        = number
  default     = 3
  description = "Desired number of spot worker nodes."
}

variable "bid_price" {
  type        = number
  default     = 0.001
  description = "Bid price per hour. Floor is 0.001. Set to p95 market price for stable instances."
}
