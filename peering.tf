# Liqo peering with ardenone-hub.
#
# Architecture: Spot cluster hosts GatewayServer (Provider) → Hub's GatewayClient connects
#
# The spot cluster runs liqo with:
#   gateway.service.type = NodePort  (no cloud LB — uses the node's public IP)
#
# liqotech peer uses --gw-server-service-type NodePort.
# Liqo reads the node's ExternalIP/InternalIP and the auto-assigned nodePort.
# The hub's GatewayClient is set to <node-ip>:<nodePort> and connects via WireGuard UDP.
#
# Flow:
#   1. Spot joins tailnet (Tailscale operator bootstrap)
#   2. liqoctl peer creates GatewayServer on SPOT (Provider, NodePort type)
#   3. Liqo reads node IP + nodePort → sets GatewayServer status endpoint
#   4. liqoctl reads the endpoint and creates hub's GatewayClient pointing to it
#   5. WireGuard tunnel established: hub → spot via node public IP + nodePort
#
# Root cause of prior failures (v17/v18 "Namespace not found"):
#
#   Hub's liqo-crd-replicator caches the UID of spot's liqo-tenant-<hub-id>
#   namespace when it first replicates the ResourceSlice. If that namespace is
#   deleted and recreated (by cleanup/unpeer), it gets a new UID. The replicator
#   still uses the old cached UID in ownerReferences. Spot's resourceslice_remote
#   controller validates the ownerRef UID and fails with "Namespace <old-uid>
#   not found". Fix: restart liqo-crd-replicator after cleanup so it reads the
#   current namespace UID fresh from the API.
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
    version    = "21"  # bump to force re-peering; 21=NodePort gateway
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

      # DIAGNOSTIC: capture spot cluster state before peering attempt.
      echo "==> DIAGNOSTIC: Spot liqo pods"
      kubectl get pods -n liqo-system -o wide 2>&1 || true
      echo "==> DIAGNOSTIC: Spot cluster ID"
      kubectl get configmap liqo-clusterid-configmap -n liqo-system \
        -o jsonpath='{.data.CLUSTER_ID}' 2>&1 || true
      echo ""
      echo "==> DIAGNOSTIC: Spot ForeignClusters"
      kubectl get foreignclusters -A 2>&1 || true
      echo "==> END DIAGNOSTIC"

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

      # Delete ALL stale liqo-tenant namespaces from prior hub cluster ID incarnations.
      echo "==> Deleting all liqo-tenant-* namespaces from spot cluster..."
      kubectl --kubeconfig "$SPOT_KUBECONFIG" get namespace \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep "^liqo-tenant-" \
        | xargs -r kubectl --kubeconfig "$SPOT_KUBECONFIG" delete namespace \
          --ignore-not-found=true 2>/dev/null || true

      if [ -n "$SPOT_CLUSTER_ID" ]; then
        echo "==> Deleting liqo-tenant-$SPOT_CLUSTER_ID from hub (if exists)..."
        kubectl delete namespace \
          "liqo-tenant-$SPOT_CLUSTER_ID" --ignore-not-found=true 2>/dev/null || true
      fi

      # Restart hub's liqo-controller-manager AND liqo-crd-replicator to clear stale namespace UID caches.
      #
      # Root cause of v17/v18/v19 "Namespace <old-uid> not found":
      #
      # Hub's localresourceslice_controller (inside liqo-controller-manager) creates
      # the ResourceSlice in liqo-tenant-<spot-id> with ownerRef.uid set to that
      # namespace's UID at creation time. If the namespace is deleted+recreated
      # (by unpeer/cleanup), it gets a new UID. The controller's runtime cache still
      # has the old UID, so it creates the ResourceSlice with a stale ownerRef.
      # The CRD replicator faithfully copies this stale ownerRef to spot.
      # Spot's resourceslice_remote controller validates the ownerRef UID against
      # liqo-tenant-<hub-id> and fails: "Namespace <stale-uid> not found".
      #
      # Fix: restart BOTH controllers after cleanup so they read current namespace
      # UIDs fresh from the Kubernetes API before the next peering attempt.
      echo "==> Restarting hub liqo-controller-manager to clear stale namespace UID cache..."
      kubectl rollout restart deployment/liqo-controller-manager -n liqo-system
      kubectl rollout status deployment/liqo-controller-manager -n liqo-system --timeout=3m
      echo "==> liqo-controller-manager restarted and ready"

      echo "==> Restarting hub liqo-crd-replicator to clear stale namespace UID cache..."
      kubectl rollout restart deployment/liqo-crd-replicator -n liqo-system
      kubectl rollout status deployment/liqo-crd-replicator -n liqo-system --timeout=3m
      echo "==> liqo-crd-replicator restarted and ready"

      # Peer hub (consumer) with spot (provider).
      # The spot cluster's GatewayServer uses NodePort — Liqo reads the node's public
      # IP and nodePort and the hub's GatewayClient connects directly over UDP.
      echo "==> Peering hub with ${local.cloudspace_name} (25m timeout)..."
      liqoctl peer \
        --remote-kubeconfig "$SPOT_KUBECONFIG" \
        --namespace liqo-system \
        --remote-namespace liqo-system \
        --skip-confirm \
        --timeout 25m \
        --gw-server-service-type NodePort \
      || {
        echo "==> DIAGNOSTIC (post-failure): Spot controller-manager logs (last 150 lines)"
        kubectl --kubeconfig "$SPOT_KUBECONFIG" logs -n liqo-system \
          deploy/liqo-controller-manager --tail=150 2>&1 || true
        echo "==> DIAGNOSTIC: Hub controller-manager logs (last 50 lines)"
        kubectl logs -n liqo-system deploy/liqo-controller-manager --tail=50 2>&1 || true
        echo "==> DIAGNOSTIC: Hub crd-replicator logs (last 50 lines)"
        kubectl logs -n liqo-system deploy/liqo-crd-replicator --tail=50 2>&1 || true
        echo ""
        echo "==> Peering failed. Manual recovery from ardenone-hub:"
        echo "    KUBECONFIG=/etc/rancher/k3s/k3s.yaml liqoctl peer \\"
        echo "      --remote-kubeconfig /tmp/${local.cloudspace_name}.kubeconfig \\"
        echo "      --namespace liqo-system \\"
        echo "      --remote-namespace liqo-system \\"
        echo "      --skip-confirm \\"
        echo "      --timeout 15m \\"
        echo "      --gw-server-service-type NodePort"
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
