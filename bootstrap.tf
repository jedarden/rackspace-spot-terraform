# Bootstrap infrastructure onto a newly created spot cluster.
# Order: Tailscale (mesh) → Liqo (federation) → Traefik (ingress) → cert-manager (TLS)

# ---------- Tailscale (mesh connectivity) ----------

resource "kubernetes_namespace" "tailscale" {
  metadata {
    name = "tailscale-system"
  }
  depends_on = [spot_spotnodepool.workers]
}

resource "kubernetes_secret" "tailscale_auth" {
  metadata {
    name      = "tailscale-auth"
    namespace = kubernetes_namespace.tailscale.metadata[0].name
  }
  data = {
    TS_AUTHKEY = var.tailscale_authkey
  }
}

# DaemonSet — every node joins the tailnet
resource "kubernetes_daemon_set_v1" "tailscale" {
  metadata {
    name      = "tailscale"
    namespace = kubernetes_namespace.tailscale.metadata[0].name
  }
  spec {
    selector {
      match_labels = { app = "tailscale" }
    }
    template {
      metadata {
        labels = { app = "tailscale" }
      }
      spec {
        host_network = true
        container {
          name  = "tailscale"
          image = "tailscale/tailscale:latest"
          security_context {
            privileged = true
          }
          env {
            name = "TS_AUTHKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tailscale_auth.metadata[0].name
                key  = "TS_AUTHKEY"
              }
            }
          }
          env {
            name = "TS_HOSTNAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name  = "TS_ACCEPT_DNS"
            value = "true"
          }
          env {
            name  = "TS_STATE_DIR"
            value = "/var/lib/tailscale"
          }
          volume_mount {
            name       = "dev-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "tailscale-state"
            mount_path = "/var/lib/tailscale"
          }
          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
        volume {
          name = "dev-tun"
          host_path {
            path = "/dev/net/tun"
          }
        }
        volume {
          name = "tailscale-state"
          host_path {
            path = "/var/lib/tailscale"
          }
        }
      }
    }
  }
}

# ---------- Liqo (provider mode — offers resources to hub) ----------

resource "helm_release" "liqo" {
  name             = "liqo"
  repository       = "https://helm.liqo.io/"
  chart            = "liqo"
  version          = var.liqo_version
  namespace        = "liqo-system"
  create_namespace = true
  wait             = true
  timeout          = 300

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

  depends_on = [kubernetes_daemon_set_v1.tailscale]
}

# ---------- Traefik (ingress controller) ----------

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true
  timeout          = 300

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
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }

  depends_on = [spot_spotnodepool.workers]
}
