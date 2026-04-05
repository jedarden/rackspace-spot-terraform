# Bootstrap infrastructure onto a newly created spot cluster.
# Order: Tailscale (mesh) → Liqo (federation) → Traefik (ingress) → cert-manager (TLS)

# ---------- Tailscale Operator (mesh connectivity via OAuth) ----------

resource "kubernetes_namespace" "tailscale" {
  count = var.skip_bootstrap ? 0 : 1
  metadata {
    name = "tailscale"
  }
  depends_on = [spot_spotnodepool.workers]
}

resource "kubernetes_secret" "operator_oauth" {
  count = var.skip_bootstrap ? 0 : 1
  metadata {
    name      = "operator-oauth"
    namespace = kubernetes_namespace.tailscale[0].metadata[0].name
  }
  data = {
    client_id     = var.tailscale_oauth_client_id
    client_secret = var.tailscale_oauth_client_secret
  }
}

resource "helm_release" "tailscale" {
  count            = var.skip_bootstrap ? 0 : 1
  name             = "tailscale-operator"
  repository       = "https://pkgs.tailscale.com/helmcharts"
  chart            = "tailscale-operator"
  version          = var.tailscale_operator_version
  namespace        = "tailscale"
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    installCRDs = true
    oauth = {
      secretName = kubernetes_secret.operator_oauth[0].metadata[0].name
    }
    operatorConfig = {
      hostname = local.cloudspace_name
    }
    defaultTags = [
      "tag:k8s-operator",
      "tag:k8s",
      "tag:spot"
    ]
  })]

  depends_on = [
    kubernetes_namespace.tailscale[0],
    kubernetes_secret.operator_oauth[0],
  ]
}

# ---------- Liqo (provider mode — offers resources to hub) ----------

resource "helm_release" "liqo" {
  count            = var.skip_bootstrap ? 0 : 1
  name             = "liqo"
  repository       = "https://helm.liqo.io/"
  chart            = "liqo"
  version          = var.liqo_version
  namespace        = "liqo-system"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    ipam = {
      podCIDR     = "10.42.0.0/16"
      serviceCIDR = "10.43.0.0/16"
    }
    gateway = {
      config = {
        addressOverride = local.cloudspace_name
      }
      service = {
        type = "ClusterIP"
      }
    }
    networking = {
      enabled = true
    }
    authentication = {
      config = {
        allowAll = true
      }
    }
  })]

  depends_on = [helm_release.tailscale[0]]
}

# ---------- Traefik (ingress controller) ----------

resource "helm_release" "traefik" {
  count            = var.skip_bootstrap ? 0 : 1
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    ports = {
      websecure = {
        port     = 8443
        expose   = { default = true }
        protocol = "TCP"
      }
    }
    service = {
      type = "LoadBalancer"
    }
  })]

  depends_on = [spot_spotnodepool.workers]
}

# ---------- cert-manager (TLS certificates) ----------

resource "helm_release" "cert_manager" {
  count            = var.skip_bootstrap ? 0 : 1
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [spot_spotnodepool.workers]
}
