# Bootstrap infrastructure onto a newly created spot cluster.
# Uses local-exec with KUBECONFIG to avoid the Terraform provider
# chicken-and-egg problem (helm/kubernetes providers can't be configured
# with values that aren't known until apply time).
#
# Order: tools -> Tailscale (mesh) -> Liqo (federation) -> Traefik (ingress) -> cert-manager (TLS) -> ArgoCD -> App-of-Apps

# Write spot kubeconfig to file for bootstrap and peering.
resource "local_sensitive_file" "spot_kubeconfig" {
  content         = data.spot_kubeconfig.main.raw
  filename        = "/tmp/${local.cloudspace_name}.kubeconfig"
  file_permission = "0600"
  depends_on      = [spot_spotnodepool.workers]
}

# Download helm and liqoctl to /tmp so local-exec scripts can use them.
# Runs once per cloudspace; subsequent null_resources share /tmp in the same pod.
resource "null_resource" "install_tools" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    # Always re-run: tools are in /tmp which doesn't persist across pods
    always = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      # helm
      if ! command -v helm &>/dev/null && [ ! -x /tmp/helm ]; then
        echo "==> Installing helm"
        wget -q "https://get.helm.sh/helm-v${var.helm_version}-linux-amd64.tar.gz" -O /tmp/helm.tar.gz
        tar xzf /tmp/helm.tar.gz -C /tmp/
        mv /tmp/linux-amd64/helm /tmp/helm
        chmod +x /tmp/helm
        rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
      fi

      # liqoctl
      if ! command -v liqoctl &>/dev/null && [ ! -x /tmp/liqoctl ]; then
        echo "==> Installing liqoctl"
        wget -q "https://github.com/liqotech/liqo/releases/download/${var.liqo_version}/liqoctl-linux-amd64.tar.gz" -O /tmp/liqoctl.tar.gz
        tar xzf /tmp/liqoctl.tar.gz -C /tmp/
        chmod +x /tmp/liqoctl
        rm -f /tmp/liqoctl.tar.gz
      fi

      export PATH="/tmp:$PATH"
      helm version --short
      liqoctl version --client 2>&1 | head -1
      echo "==> Tools ready"
    EOT
  }

  depends_on = [local_sensitive_file.spot_kubeconfig]
}

# ---------- Tailscale Operator (mesh connectivity via OAuth) ----------

resource "null_resource" "tailscale" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

      kubectl create secret generic operator-oauth \
        --namespace tailscale \
        --from-literal=client_id="${var.tailscale_oauth_client_id}" \
        --from-literal=client_secret="${var.tailscale_oauth_client_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

      helm repo add tailscale https://pkgs.tailscale.com/helmcharts
      helm upgrade --install tailscale-operator tailscale/tailscale-operator \
        --namespace tailscale \
        --version "${var.tailscale_operator_version}" \
        --timeout 15m \
        --set installCRDs=true \
        --set oauth.secretName=operator-oauth \
        --set "operatorConfig.hostname=${local.cloudspace_name}" \
        --set-json 'defaultTags=["tag:k8s-operator","tag:k8s","tag:spot"]'
    EOT
  }

  depends_on = [null_resource.install_tools]
}

# ---------- Liqo (provider mode -- offers resources to hub) ----------

resource "null_resource" "liqo" {
  count = var.skip_bootstrap || var.skip_liqo ? 0 : 1
  triggers = {
    cloudspace  = local.cloudspace_name
    api_address = "2"  # bump to force re-run with apiServer.address fix
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      helm repo add liqo https://helm.liqo.io/
      helm upgrade --install liqo liqo/liqo \
        --namespace liqo-system --create-namespace \
        --version "${var.liqo_version}" \
        --timeout 15m \
        --set ipam.podCIDR=10.42.0.0/16 \
        --set ipam.serviceCIDR=10.43.0.0/16 \
        --set gateway.service.type=NodePort \
        --set-json "gateway.service.annotations={\"tailscale.com/expose\":\"true\",\"tailscale.com/hostname\":\"${local.cloudspace_name}-liqo\"}" \
        --set networking.enabled=true \
        --set authentication.config.allowAll=true \
        --set "apiServer.address=${data.spot_kubeconfig.main.kubeconfigs[0].host}"
    EOT
  }

  depends_on = [null_resource.tailscale]
}

# ---------- Traefik (ingress controller) ----------

resource "null_resource" "traefik" {
  count = var.skip_bootstrap || var.skip_traefik ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      helm repo add traefik https://traefik.github.io/charts
      helm upgrade --install traefik traefik/traefik \
        --namespace traefik --create-namespace \
        --version "${var.traefik_version}" \
        --timeout 15m \
        --set ports.websecure.port=8443 \
        --set ports.websecure.expose.default=true \
        --set ports.websecure.protocol=TCP \
        --set service.type=ClusterIP
    EOT
  }

  depends_on = [null_resource.install_tools]
}

# ---------- cert-manager (TLS certificates) ----------

resource "null_resource" "cert_manager" {
  count = var.skip_bootstrap || var.skip_cert_manager ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      helm repo add jetstack https://charts.jetstack.io
      helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "${var.cert_manager_version}" \
        --timeout 15m \
        --set crds.enabled=true \
        --set startupapicheck.enabled=false
    EOT
  }

  depends_on = [null_resource.install_tools]
}

# ---------- ArgoCD (GitOps controller) ----------

resource "null_resource" "argocd" {
  count = var.skip_bootstrap || var.skip_argocd ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      echo "==> Installing ArgoCD ${var.argocd_chart_version}"
      helm repo add argo https://argoproj.github.io/argo-helm
      helm repo update argo

      helm upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace \
        --version "${var.argocd_chart_version}" \
        --timeout 15m \
        --wait \
        --set configs.params."server\.insecure"=true

      echo "==> Creating declarative-config repo secret"
      kubectl create secret generic declarative-config-repo \
        --namespace argocd \
        --from-literal=type=git \
        --from-literal=url=https://github.com/jedarden/declarative-config \
        --from-literal=username=jedarden \
        --from-literal=password="${var.github_token}" \
        --dry-run=client -o yaml | kubectl apply -f -

      kubectl label secret declarative-config-repo \
        --namespace argocd \
        --overwrite \
        argocd.argoproj.io/secret-type=repository

      echo "==> ArgoCD ready"
    EOT
  }

  depends_on = [null_resource.cert_manager, null_resource.traefik]
}

# ---------- App-of-Apps (hands off to declarative-config) ----------

resource "null_resource" "app_of_apps" {
  count = var.skip_bootstrap || var.skip_argocd ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
    path       = var.declarative_config_path
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = <<-EOT
      set -euo pipefail

      echo "==> Applying App-of-Apps for k8s/${var.declarative_config_path}"
      kubectl apply -f - <<MANIFEST
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: applications-${local.cloudspace_name}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jedarden/declarative-config
    targetRevision: HEAD
    path: k8s/${var.declarative_config_path}
    directory:
      recurse: false
      include: '*-application.yml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
MANIFEST
      echo "==> App-of-Apps applied — ArgoCD will sync from declarative-config"
    EOT
  }

  depends_on = [null_resource.argocd]
}
