# --- Authentication ---

variable "rackspace_spot_token" {
  type        = string
  sensitive   = true
  description = "Rackspace Spot API refresh token"
}

variable "tailscale_authkey" {
  type        = string
  sensitive   = true
  description = "Tailscale auth key. Generate from https://login.tailscale.com/admin/settings/keys or via tailscale CLI."
}

# --- Cluster ---

variable "kubernetes_version" {
  type    = string
  default = "1.31.1"
}

# --- Liqo ---

variable "liqo_version" {
  type    = string
  default = "v1.1.2"
}

variable "liqo_hub_address" {
  type        = string
  description = "Tailscale IP of ardenone-hub's Liqo gateway."
}

# --- Component versions ---

variable "argo_workflows_version" {
  type    = string
  default = "0.45.14"
}
