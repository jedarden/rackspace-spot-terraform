# Bootstrap infrastructure onto a newly created spot cluster.
# Uses local-exec with KUBECONFIG to avoid the Terraform provider
# chicken-and-egg problem (helm/kubernetes providers can't be configured
# with values that aren't known until apply time).
#
# Order: tools -> Tailscale (mesh) -> Liqo (federation) -> Traefik (ingress) -> cert-manager (TLS)

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

      helm repo add liqo https://helm.liqo.io/
      helm upgrade --install liqo liqo/liqo \
        --namespace liqo-system --create-namespace \
        --version "${var.liqo_version}" \
        --timeout 15m \
        --set ipam.podCIDR=10.42.0.0/16 \
        --set ipam.serviceCIDR=10.43.0.0/16 \
        --set gateway.config.addressOverride=${local.cloudspace_name} \
        --set gateway.service.type=ClusterIP \
        --set networking.enabled=true \
        --set authentication.config.allowAll=true
    EOT
  }

  depends_on = [null_resource.tailscale]
}

# ---------- Traefik (ingress controller) ----------

resource "null_resource" "traefik" {
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

      helm repo add traefik https://traefik.github.io/charts
      helm upgrade --install traefik traefik/traefik \
        --namespace traefik --create-namespace \
        --version "${var.traefik_version}" \
        --timeout 15m \
        --set ports.websecure.port=8443 \
        --set ports.websecure.expose.default=true \
        --set ports.websecure.protocol=TCP \
        --set service.type=LoadBalancer
    EOT
  }

  depends_on = [null_resource.install_tools]
}

# ---------- cert-manager (TLS certificates) ----------

resource "null_resource" "cert_manager" {
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
