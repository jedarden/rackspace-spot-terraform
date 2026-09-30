variable "rackspace_spot_token" {
  type        = string
  sensitive   = true
  description = "Rackspace Spot API refresh token"

  validation {
    condition     = trimspace(var.rackspace_spot_token) != ""
    error_message = "rackspace_spot_token must not be empty."
  }
}

# --- Naming ---

variable "cloudspace_name" {
  type        = string
  default     = ""
  description = "Explicit cloudspace name. If empty, generates iad-<random-word>."

  validation {
    condition = (
      var.cloudspace_name == "" ||
      (length(var.cloudspace_name) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cloudspace_name)))
    )
    error_message = "cloudspace_name must be empty for a generated name or a DNS label of at most 63 lowercase letters, digits, and hyphens, starting and ending with a letter or digit."
  }
}

# --- Cluster ---

variable "region" {
  type    = string
  default = "us-east-iad-1"

  validation {
    condition     = can(regex("^us-[a-z]+-[a-z]{3}-[0-9]+$", var.region))
    error_message = "region must use the Rackspace Spot format us-<area>-<location>-<number>, such as us-east-iad-1."
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.31.1"

  validation {
    condition     = can(regex("^[1-9][0-9]*\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", var.kubernetes_version))
    error_message = "kubernetes_version must be a stable numeric major.minor.patch version, such as 1.31.1."
  }
}

# --- Node Pool ---

variable "server_class" {
  type        = string
  default     = "gp.vs1.medium-iad"
  description = "Rackspace Spot server class. Use spotctl serverclasses list to see options. Default: gp.vs1.medium-iad (2 CPU, 3.75GB, $0.001/hr)."

  validation {
    condition = (
      can(regex("^[a-z]{2}\\.[a-z0-9]+\\.[a-z0-9]+-[a-z]{3}$", var.server_class)) &&
      try(regex("^[a-z]{2}\\.[a-z0-9]+\\.[a-z0-9]+-([a-z]{3})$", var.server_class)[0], "") ==
      try(regex("^us-[a-z]+-([a-z]{3})-[0-9]+$", var.region)[0], "")
    )
    error_message = "server_class must use the Rackspace Spot class format and its location suffix must match region."
  }
}

variable "node_count" {
  type        = number
  default     = 3
  description = "Desired number of spot worker nodes."

  validation {
    condition     = var.node_count >= 1 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a positive whole number."
  }
}

variable "bid_price" {
  type        = number
  default     = 0.001
  description = "Bid price per hour. Minimum varies by server class (check spotctl). Default suits mh.vs1.large-iad."

  validation {
    condition     = var.bid_price > 0
    error_message = "bid_price must be greater than zero; the minimum depends on the selected server class."
  }
}

# --- Tailscale (mesh connectivity via OAuth) ---

variable "tailscale_oauth_client_id" {
  type        = string
  sensitive   = true
  description = "Tailscale OAuth client ID. Create at https://login.tailscale.com/admin/settings/oauth"

  validation {
    condition     = trimspace(var.tailscale_oauth_client_id) != ""
    error_message = "tailscale_oauth_client_id must not be empty."
  }
}

variable "tailscale_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "Tailscale OAuth client secret."

  validation {
    condition     = trimspace(var.tailscale_oauth_client_secret) != ""
    error_message = "tailscale_oauth_client_secret must not be empty."
  }
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
  description = "Skip Liqo installation and peering. Use for management or standalone clusters; removing an existing peering runs liqoctl unpeer but leaves the Helm release installed."
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

# --- ArgoCD bootstrap ---

variable "skip_argocd" {
  type        = bool
  default     = false
  description = "Skip ArgoCD installation and App-of-Apps bootstrap."
}

variable "argocd_chart_version" {
  type        = string
  default     = "7.8.23"
  description = "ArgoCD Helm chart version (argo/argo-cd)."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub PAT for ArgoCD to read jedarden/declarative-config."

  validation {
    condition     = trimspace(var.github_token) != ""
    error_message = "github_token must not be empty."
  }
}

variable "declarative_config_path" {
  type        = string
  default     = "rs-manager"
  description = "Subdirectory under k8s/ in declarative-config for the App-of-Apps path."
}
