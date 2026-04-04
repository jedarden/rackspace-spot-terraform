# Liqo peering with ardenone-hub.
#
# liqoctl peer requires both kubeconfigs (hub + spot).
# When the tf-operator runs on ardenone-hub, it has access to the hub's
# kubeconfig at /etc/rancher/k3s/k3s.yaml. The spot kubeconfig is written
# to a temp file from Terraform state.
#
# If liqoctl is not available in the tf-operator pod, complete peering
# manually from the hub:
#
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
#     --remote-kubeconfig /tmp/<cluster>.kubeconfig \
#     --server-service-type ClusterIP

resource "local_sensitive_file" "spot_kubeconfig" {
  content         = data.spot_kubeconfig.main.raw
  filename        = "/tmp/${local.cloudspace_name}.kubeconfig"
  file_permission = "0600"

  count = var.skip_bootstrap ? 0 : 1
  depends_on = [helm_release.liqo[0]]
}

resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      if ! command -v liqoctl &>/dev/null; then
        echo "==> liqoctl not found. Complete peering manually from ardenone-hub:"
        echo "    liqoctl peer --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig --server-service-type ClusterIP"
        exit 0
      fi

      # Use k3s kubeconfig on the host, or fall back to in-cluster config
      if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      echo "==> Peering ${local.cloudspace_name} with ardenone-hub"
      liqoctl peer \
        --remote-kubeconfig "${local_sensitive_file.spot_kubeconfig[0].filename}" \
        --server-service-type ClusterIP
    EOT
  }

  depends_on = [
    helm_release.liqo[0],
    local_sensitive_file.spot_kubeconfig[0],
  ]
}
