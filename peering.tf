# Liqo peering with ardenone-hub.
#
# Architecture: Provider (spot) → Tailscale operator ingress → Consumer (hub)
#
# The spot cluster installs liqo with:
#   gateway.config.addressOverride = <cloudspace>-liqo
#   gateway.service.type           = LoadBalancer
#   gateway.service.annotations    = {tailscale.com/expose: "true",
#                                     tailscale.com/hostname: <cloudspace>-liqo}
#
# This causes the Tailscale operator to create a device named <cloudspace>-liqo
# on the tailnet, exposing the liqo WireGuard gateway. The hub's gateway client
# connects to <cloudspace>-liqo via Tailscale MagicDNS.
#
# Flow:
#   1. Spot joins tailnet (Tailscale operator bootstrap)
#   2. liqoctl peer creates GatewayServer on spot; liqo controller creates
#      LoadBalancer service; Tailscale operator exposes it as <cloudspace>-liqo
#   3. Hub's GatewayClient reads endpoint from GatewayServer status
#      (addressOverride = <cloudspace>-liqo) and connects via Tailscale
#   4. WireGuard tunnel established through the tailnet
#
# Manual recovery from ardenone-hub:
#
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
#     --remote-kubeconfig /tmp/<cluster>.kubeconfig \
#     --namespace liqo-system \
#     --remote-namespace liqo-system \
#     --skip-confirm \
#     --timeout 15m

resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
    version    = "12"  # bump to force re-peering
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"
      export KUBECONFIG="${local_sensitive_file.spot_kubeconfig.filename}"

      # Wait for liqo controller-manager to be ready on the spot cluster
      echo "==> Waiting for liqo-controller-manager on ${local.cloudspace_name}..."
      for i in $(seq 1 60); do
        if kubectl -n liqo-system get deploy liqo-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
          echo "==> Liqo controller-manager ready"
          break
        fi
        if [ "$i" -eq 60 ]; then
          echo "==> Liqo controller-manager not ready after 10m. Peering must be done manually."
          exit 0
        fi
        sleep 10
      done

      # Wait for liqo-fabric DaemonSet to be fully ready.
      # liqo-fabric sets up service-CIDR routing on the spot node via the WireGuard tunnel.
      # Without it, the spot's liqo-controller-manager cannot reach the hub's liqo-proxy
      # to complete the auth exchange. The initial liqo install uses --no-wait, so fabric
      # may still be starting when the controller-manager is first Ready.
      echo "==> Waiting for liqo-fabric DaemonSet on ${local.cloudspace_name}..."
      for i in $(seq 1 120); do
        DESIRED=$(kubectl -n liqo-system get ds liqo-fabric \
          -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
        READY=$(kubectl -n liqo-system get ds liqo-fabric \
          -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        if [ -n "$DESIRED" ] && [ "$DESIRED" != "0" ] && [ "$DESIRED" = "$READY" ]; then
          echo "==> liqo-fabric ready ($READY/$DESIRED)"
          break
        fi
        if [ "$i" -eq 120 ]; then
          echo "==> liqo-fabric not ready after 20m. Peering must be done manually."
          exit 0
        fi
        sleep 10
      done

      # Upgrade liqo on spot to expose the gateway via the Tailscale operator.
      # The gateway service needs tailscale.com/expose so the operator creates a
      # Tailscale device for it, making it reachable from the hub via MagicDNS.
      # addressOverride sets the endpoint hostname liqo advertises to the hub.
      echo "==> Upgrading liqo gateway to use Tailscale operator ingress..."
      helm repo add liqo https://helm.liqo.io/ 2>/dev/null || true
      helm upgrade liqo liqo/liqo \
        --namespace liqo-system \
        --version "${var.liqo_version}" \
        --reuse-values \
        --set gateway.config.addressOverride="${local.cloudspace_name}-liqo" \
        --set gateway.service.type=LoadBalancer \
        --set-json "gateway.service.annotations={\"tailscale.com/expose\":\"true\",\"tailscale.com/hostname\":\"${local.cloudspace_name}-liqo\"}" \
        --timeout 5m

      # Switch to hub (in-cluster config)
      SPOT_KUBECONFIG="${local_sensitive_file.spot_kubeconfig.filename}"
      unset KUBECONFIG
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      # Clean up stale peering state from prior runs.
      echo "==> Cleaning up stale peering state (if any)..."
      liqotech_unpeer() {
        liqoctl unpeer \
          --remote-kubeconfig "$SPOT_KUBECONFIG" \
          --namespace liqo-system \
          --remote-namespace liqo-system \
          --skip-confirm \
          2>&1 || true
      }
      liqotech_unpeer

      # Explicitly remove stale liqo-tenant namespaces so liqotech can recreate them.
      HUB_CLUSTER_ID=$(kubectl get configmap liqo-clusterid-configmap \
        -n liqo-system -o jsonpath='{.data.CLUSTER_ID}' 2>/dev/null || echo "")
      SPOT_CLUSTER_ID=$(kubectl --kubeconfig "$SPOT_KUBECONFIG" \
        get configmap liqo-clusterid-configmap \
        -n liqo-system -o jsonpath='{.data.CLUSTER_ID}' 2>/dev/null || echo "")

      if [ -n "$HUB_CLUSTER_ID" ]; then
        echo "==> Deleting liqo-tenant-$HUB_CLUSTER_ID from spot cluster (if exists)..."
        kubectl --kubeconfig "$SPOT_KUBECONFIG" delete namespace \
          "liqo-tenant-$HUB_CLUSTER_ID" --ignore-not-found=true 2>/dev/null || true
      fi
      if [ -n "$SPOT_CLUSTER_ID" ]; then
        echo "==> Deleting liqo-tenant-$SPOT_CLUSTER_ID from hub (if exists)..."
        kubectl delete namespace \
          "liqo-tenant-$SPOT_CLUSTER_ID" --ignore-not-found=true 2>/dev/null || true
      fi

      # Wait for Tailscale operator to create the device for the liqo gateway.
      # The device is created when liqoctl peer triggers the GatewayServer
      # controller to create the LoadBalancer service. We allow up to 3 min.
      echo "==> Peering ${local.cloudspace_name} with ardenone-hub (Provider via Tailscale)..."
      liqoctl peer \
        --remote-kubeconfig "$SPOT_KUBECONFIG" \
        --namespace liqo-system \
        --remote-namespace liqo-system \
        --skip-confirm \
        --timeout 30m \
      || {
        echo ""
        echo "==> Peering failed. Check if ${local.cloudspace_name}-liqo is in the tailnet."
        echo "    Complete manually from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
        echo "      --namespace liqo-system \\"
        echo "      --remote-namespace liqo-system \\"
        echo "      --skip-confirm \\"
        echo "      --timeout 15m"
        echo ""
        echo "Kubeconfig has been written to: /tmp/${local.cloudspace_name}.kubeconfig"
        exit 0
      }
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      # Use k3s kubeconfig on the host for the hub side (same as peer)
      unset KUBECONFIG
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      # Construct kubeconfig path from trigger (cannot reference other resources in destroy)
      SPOT_KUBECONFIG="/tmp/${self.triggers.cloudspace}.kubeconfig"

      echo "==> Unpeering ${self.triggers.cloudspace} from ardenone-hub"
      liqoctl unpeer \
        --remote-kubeconfig "$SPOT_KUBECONFIG" \
        --namespace liqo-system \
        --remote-namespace liqo-system \
        --skip-confirm \
      || true
    EOT
  }

  depends_on = [null_resource.liqo]
}
