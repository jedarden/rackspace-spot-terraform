# Liqo peering with ardenone-hub.
#
# liqoctl peer requires both kubeconfigs (hub + spot).
# The tf-operator runs on ardenone-hub and has in-cluster access to the
# hub API. The spot kubeconfig is written by bootstrap.tf.
#
# If peering fails (e.g. insufficient RBAC on the hub side), complete
# it manually from ardenone-hub:
#
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
#     --remote-kubeconfig /tmp/<cluster>.kubeconfig \
#     --gw-server-service-type ClusterIP

resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
    version    = "2"  # bump to force re-peering
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
          echo "      --gw-server-service-type ClusterIP"
          exit 0
        fi
        sleep 10
      done

      # Use k3s kubeconfig on the host for the hub side
      unset KUBECONFIG
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      echo "==> Peering ${local.cloudspace_name} with ardenone-hub"
      liqoctl peer \
        --remote-kubeconfig "${local_sensitive_file.spot_kubeconfig.filename}" \
        --gw-server-service-type ClusterIP \
      || {
        echo ""
        echo "==> Peering failed (likely RBAC). Complete manually from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
        echo "      --gw-server-service-type ClusterIP"
        echo ""
        echo "Kubeconfig has been written to: /tmp/${local.cloudspace_name}.kubeconfig"
        exit 0
      }
    EOT
  }

  depends_on = [null_resource.liqo]
}
