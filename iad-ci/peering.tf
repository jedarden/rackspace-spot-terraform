# Liqo peering with ardenone-hub.
#
# When the tf-operator runs on ardenone-hub, it has access to the hub's
# kubeconfig at /etc/rancher/k3s/k3s.yaml. The spot kubeconfig is written
# to a temp file from Terraform state.
#
# If liqoctl is not available in the tf-operator pod, complete peering
# manually from the hub:
#
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
#     --remote-kubeconfig /tmp/iad-ci.kubeconfig \
#     --server-service-type ClusterIP

resource "local_sensitive_file" "spot_kubeconfig" {
  content         = data.spot_kubeconfig.main.raw
  filename        = "/tmp/iad-ci.kubeconfig"
  file_permission = "0600"

  depends_on = [helm_release.liqo]
}

resource "null_resource" "liqo_peer" {
  triggers = {
    cloudspace = "iad-ci"
  }

  provisioner "local-exec" {
    command = <<-EOT
      if command -v liqoctl &>/dev/null && [ -f /etc/rancher/k3s/k3s.yaml ]; then
        echo "==> Peering iad-ci with ardenone-hub"
        KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \
          --remote-kubeconfig "${local_sensitive_file.spot_kubeconfig.filename}" \
          --server-service-type ClusterIP
      else
        echo "==> liqoctl or hub kubeconfig not available in this environment."
        echo "==> Complete peering manually from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/iad-ci.kubeconfig \\"
        echo "      --server-service-type ClusterIP"
      fi
    EOT
  }

  depends_on = [
    helm_release.liqo,
    local_sensitive_file.spot_kubeconfig,
  ]
}
