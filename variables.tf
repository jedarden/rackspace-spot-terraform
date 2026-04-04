variable "rackspace_spot_token" {
  type        = string
  sensitive   = true
  description = "Rackspace Spot API refresh token"
}

# --- Naming ---

variable "cloudspace_name" {
  type        = string
  default     = ""
  description = "Explicit cloudspace name. If empty, generates iad-<random-word>."
}

# --- Cluster ---

variable "region" {
  type    = string
  default = "us-east-iad-1"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31.1"
}

# --- Node Pool ---

variable "server_class" {
  type        = string
  default     = "mh.vs1.large-iad"
  description = "Rackspace Spot server class. Use spotctl serverclasses list to see options."
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

# --- Tailscale (mesh connectivity) ---

variable "tailscale_authkey" {
  type        = string
  sensitive   = true
  description = "Tailscale auth key. Generate from https://login.tailscale.com/admin/settings/keys or via `tailscale` CLI."
}

# --- Liqo (cluster federation) ---

variable "liqo_version" {
  type        = string
  default     = "v1.1.2"
  description = "Liqo Helm chart version. Must match ardenone-hub."
}

variable "liqo_hub_address" {
  type        = string
  description = "Tailscale IP of ardenone-hub's Liqo gateway."
}

# --- Bootstrap CRDs ---

variable "traefik_version" {
  type        = string
  default     = "34.3.0"
  description = "Traefik Helm chart version."
}

variable "cert_manager_version" {
  type        = string
  default     = "v1.17.1"
  description = "cert-manager Helm chart version."
}
