# Liqo peering is initiated from ardenone-hub (the runner's hub kubeconfig)
# toward the Spot cluster, which acts as the provider and offers resources.
# See docs/liqo-tailscale-contract.md for context selection, permissions, and
# failure/recovery behavior.
resource "null_resource" "liqo_peer" {
  count = var.skip_bootstrap || var.skip_liqo ? 0 : 1
  triggers = {
    cloudspace = local.cloudspace_name
    version    = "22" # v22 uses the scripted, retryable peering contract
  }

  provisioner "local-exec" {
    environment = {
      CLOUDSPACE_NAME = local.cloudspace_name
      SPOT_KUBECONFIG = local_sensitive_file.spot_kubeconfig.filename
    }
    command = "bash \"${path.module}/scripts/liqo-peer.sh\" peer"
  }

  provisioner "local-exec" {
    when = destroy
    environment = {
      CLOUDSPACE_NAME = self.triggers.cloudspace
      SPOT_KUBECONFIG = "/tmp/${self.triggers.cloudspace}.kubeconfig"
    }
    command = "bash \"${path.module}/scripts/liqo-peer.sh\" unpeer"
  }

  depends_on = [null_resource.liqo]
}
