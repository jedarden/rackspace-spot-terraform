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
#     --server-service-type ClusterIP

resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export PATH="/tmp:$PATH"

      # Use k3s kubeconfig on the host, or fall back to in-cluster config
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      echo "==> Peering ${local.cloudspace_name} with ardenone-hub"
      liqoctl peer \
        --remote-kubeconfig "${local_sensitive_file.spot_kubeconfig.filename}" \
        --server-service-type ClusterIP \
      || {
        echo ""
        echo "==> Peering failed (likely RBAC). Complete manually from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
        echo "      --server-service-type ClusterIP"
        echo ""
        echo "Kubeconfig has been written to: /tmp/${local.cloudspace_name}.kubeconfig"
        exit 0
      }
    EOT
  }

  depends_on = [null_resource.liqo]
}
