# Bootstrap: Tailscale (mesh) -> Liqo (federation) -> Argo Workflows (CI)
# All other services (Traefik, cloudflared, cert-manager, ESO, OpenBao)
# are provided by ardenone-hub via Liqo.

# ---------- Tailscale (mesh connectivity) ----------

resource "kubernetes_namespace" "tailscale" {
  metadata { name = "tailscale-system" }
  depends_on = [spot_spotnodepool.control]
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
            name  = "TS_HOSTNAME"
            value = "iad-ci"
          }
          env {
            name  = "TS_USERSPACE"
            value = "false"
          }
          env {
            name  = "TS_ACCEPT_DNS"
            value = "true"
          }
          volume_mount {
            name       = "dev-tun"
            mount_path = "/dev/net/tun"
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
    gateway = {
      config = {
        addressOverride = "iad-ci"
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

# ---------- Argo Workflows ----------

resource "helm_release" "argo_workflows" {
  name             = "argo-workflows"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-workflows"
  version          = var.argo_workflows_version
  namespace        = "argo"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "64Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }
      workflowDefaults = {
        spec = {
          podGC = {
            strategy = "OnPodCompletion"
          }
          activeDeadlineSeconds = 1800
        }
      }
    }
    server = {
      resources = {
        requests = { cpu = "100m", memory = "64Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }
      extraArgs = [
        "--auth-mode=server",
      ]
    }
    useStaticCredentials = true
  })]

  depends_on = [spot_spotnodepool.control]
}
