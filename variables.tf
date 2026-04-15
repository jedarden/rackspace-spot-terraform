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
  default     = 0.015
  description = "Bid price per hour. Minimum varies by server class (check spotctl). Default suits mh.vs1.large-iad."
}

# --- Tailscale (mesh connectivity via OAuth) ---

variable "tailscale_oauth_client_id" {
  type        = string
  sensitive   = true
  description = "Tailscale OAuth client ID. Create at https://login.tailscale.com/admin/settings/oauth"
}

variable "tailscale_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Tailscale OAuth client secret."
}

variable "tailscale_operator_version" {
  type    = string
  default = "1.94.2"
}

# --- Liqo (cluster federation) ---

variable "liqo_version" {
  type        = string
  default     = "v1.1.2"
  description = "Liqo Helm chart version. Must match ardenone-hub."
}

variable "skip_liqo" {
  type        = bool
  default     = false
  description = "Skip Liqo installation and peering. Use for standalone clusters that don't federate resources with ardenone-hub."
}

variable "skip_traefik" {
  type        = bool
  default     = false
  description = "Skip Traefik ingress controller installation. Use for clusters with no user-facing HTTP services."
}

variable "skip_cert_manager" {
  type        = bool
  default     = false
  description = "Skip cert-manager installation. Typically set together with skip_traefik."
}

variable "skip_bootstrap" {
  type        = bool
  default     = false
  description = "Skip bootstrap resources (Tailscale, Liqo, Traefik, cert-manager). Use when cluster is already bootstrapped or RBAC is restricted."
}

# --- Bootstrap tools and charts ---

variable "helm_version" {
  type        = string
  default     = "3.17.0"
  description = "Helm version to download at runtime for bootstrap."
}

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
