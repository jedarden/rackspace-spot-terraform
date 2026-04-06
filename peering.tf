# Liqo peering with ardenone-hub.
#
# liqoctl peer requires both kubeconfigs (hub + spot).
# The tf-operator runs on ardenone-hub and has in-cluster access to the
# hub API. The spot kubeconfig is written by bootstrap.tf.
#
# --gw-server-service-location Consumer pins the WireGuard gateway to the
# hub (ardenone-hub) side. The hub is a single-node VPS with a stable
# Tailscale IP (100.100.51.40), so the gateway is always reachable from
# the spot cluster. Without this flag the gateway lands on the spot side
# where the addressOverride hostname may not resolve to the node actually
# running the gateway pod.
#
# If peering fails (e.g. insufficient RBAC on the hub side), complete
# it manually from ardenone-hub:
#
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
#     --remote-kubeconfig /tmp/<cluster>.kubeconfig \
#     --namespace liqo-system \
#     --remote-namespace liqo-system \
#     --gw-server-service-type NodePort \
#     --gw-server-service-location Consumer \
#     --gw-client-address 100.100.51.40 \
#     --skip-confirm \
#     --timeout 15m

resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
    version    = "9"  # bump to force re-peering
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
          echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
          echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
          echo "      --namespace liqo-system \\"
          echo "      --remote-namespace liqo-system \\"
          echo "      --gw-server-service-type NodePort \\"
          echo "      --gw-server-service-location Consumer \\"
          echo "      --skip-confirm \\"
          echo "      --timeout 15m"
          exit 0
        fi
        sleep 10
      done

      # Switch to hub (in-cluster config)
      SPOT_KUBECONFIG="${local_sensitive_file.spot_kubeconfig.filename}"
      unset KUBECONFIG
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      # Clean up stale peering state from prior runs.
      # liqoctl unpeer handles most cleanup but does not delete liqo-tenant-*
      # namespaces; we delete them explicitly so liqotech can create them fresh.
      echo "==> Cleaning up stale peering state (if any)..."
      liqoctl unpeer \
        --remote-kubeconfig "$SPOT_KUBECONFIG" \
        --namespace liqo-system \
        --remote-namespace liqo-system \
        --skip-confirm \
        2>&1 || true

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

      echo "==> Peering ${local.cloudspace_name} with ardenone-hub"
      liqoctl peer \
        --remote-kubeconfig "${local_sensitive_file.spot_kubeconfig.filename}" \
        --namespace liqo-system \
        --remote-namespace liqo-system \
        --gw-server-service-type NodePort \
        --gw-server-service-location Consumer \
        --gw-client-address 100.100.51.40 \
        --skip-confirm \
        --timeout 15m \
      || {
        echo ""
        echo "==> Peering failed (likely RBAC). Complete manually from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
        echo "      --namespace liqo-system \\"
        echo "      --remote-namespace liqo-system \\"
        echo "      --gw-server-service-type NodePort \\"
        echo "      --gw-server-service-location Consumer \\"
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
