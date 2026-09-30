#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-peer}"
: "${CLOUDSPACE_NAME:?CLOUDSPACE_NAME is required}"
: "${SPOT_KUBECONFIG:?SPOT_KUBECONFIG must name the Spot cluster credentials}"
export PATH="/tmp:$PATH"

use_hub_context() {
  # HUB_KUBECONFIG is an optional runner override. The k3s host config is the
  # default on the hub runner; otherwise kubectl/liqotech use their normal
  # ~/.kube/config context.
  if [[ -n "${HUB_KUBECONFIG:-}" ]]; then
    export KUBECONFIG="$HUB_KUBECONFIG"
  elif [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  else
    unset KUBECONFIG
  fi
}

unpeer() {
  use_hub_context
  echo "==> Unpeering ${CLOUDSPACE_NAME} from ardenone-hub"
  liqoctl unpeer \
    --remote-kubeconfig "$SPOT_KUBECONFIG" \
    --namespace liqo-system \
    --remote-namespace liqo-system \
    --skip-confirm \
    || true
}

wait_for_spot() {
  export KUBECONFIG="$SPOT_KUBECONFIG"
  local i desired ready

  echo "==> Waiting for liqo-controller-manager on ${CLOUDSPACE_NAME}..."
  for ((i = 1; i <= ${LIQO_CONTROLLER_ATTEMPTS:-60}; i++)); do
    if kubectl -n liqo-system get deploy liqo-controller-manager \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
      echo "==> Liqo controller-manager ready"
      break
    fi
    if ((i == ${LIQO_CONTROLLER_ATTEMPTS:-60})); then
      echo "==> Liqo controller-manager not ready. Peering must be retried after recovery."
      return 1
    fi
    sleep "${LIQO_POLL_INTERVAL:-10}"
  done

  echo "==> Waiting for liqo-fabric DaemonSet on ${CLOUDSPACE_NAME}..."
  for ((i = 1; i <= ${LIQO_FABRIC_ATTEMPTS:-120}; i++)); do
    desired="$(kubectl -n liqo-system get ds liqo-fabric \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")"
    ready="$(kubectl -n liqo-system get ds liqo-fabric \
      -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")"
    if [[ -n "$desired" && "$desired" != "0" && "$desired" == "$ready" ]]; then
      echo "==> liqo-fabric ready ($ready/$desired)"
      break
    fi
    if ((i == ${LIQO_FABRIC_ATTEMPTS:-120})); then
      echo "==> liqo-fabric not ready. Peering must be retried after recovery."
      return 1
    fi
    sleep "${LIQO_POLL_INTERVAL:-10}"
  done
}

peer() {
  wait_for_spot

  echo "==> DIAGNOSTIC: Spot liqo pods"
  kubectl get pods -n liqo-system -o wide 2>&1 || true
  echo "==> DIAGNOSTIC: Spot cluster ID"
  kubectl get configmap liqo-clusterid-configmap -n liqo-system \
    -o jsonpath='{.data.CLUSTER_ID}' 2>&1 || true
  echo ""
  echo "==> DIAGNOSTIC: Spot ForeignClusters"
  kubectl get foreignclusters -A 2>&1 || true
  echo "==> END DIAGNOSTIC"

  # Switch from the remote Spot context to ardenone-hub for Liqo operations.
  use_hub_context

  # Clean stale state on every attempt. This makes re-running apply the
  # recovery path after a previous peer command failed.
  echo "==> Cleaning up stale peering state (if any)..."
  liqoctl unpeer \
    --remote-kubeconfig "$SPOT_KUBECONFIG" \
    --namespace liqo-system \
    --remote-namespace liqo-system \
    --skip-confirm \
    2>&1 || true

  SPOT_CLUSTER_ID="$(kubectl --kubeconfig "$SPOT_KUBECONFIG" \
    get configmap liqo-clusterid-configmap \
    -n liqo-system -o jsonpath='{.data.CLUSTER_ID}' 2>/dev/null || echo "")"

  echo "==> Deleting all liqo-tenant-* namespaces from Spot cluster..."
  kubectl --kubeconfig "$SPOT_KUBECONFIG" get namespace \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep "^liqo-tenant-" \
    | xargs -r kubectl --kubeconfig "$SPOT_KUBECONFIG" delete namespace \
      --ignore-not-found=true 2>/dev/null || true

  if [[ -n "$SPOT_CLUSTER_ID" ]]; then
    echo "==> Deleting liqo-tenant-$SPOT_CLUSTER_ID from hub (if exists)..."
    kubectl delete namespace "liqo-tenant-$SPOT_CLUSTER_ID" \
      --ignore-not-found=true 2>/dev/null || true
  fi

  echo "==> Restarting hub liqo-controller-manager to clear stale namespace UID cache..."
  kubectl rollout restart deployment/liqo-controller-manager -n liqo-system
  kubectl rollout status deployment/liqo-controller-manager -n liqo-system \
    --timeout=3m
  echo "==> liqo-controller-manager restarted and ready"

  echo "==> Restarting hub liqo-crd-replicator to clear stale namespace UID cache..."
  kubectl rollout restart deployment/liqo-crd-replicator -n liqo-system
  kubectl rollout status deployment/liqo-crd-replicator -n liqo-system \
    --timeout=3m
  echo "==> liqo-crd-replicator restarted and ready"

  echo "==> Peering hub with ${CLOUDSPACE_NAME} (25m timeout)..."
  if liqoctl peer \
    --remote-kubeconfig "$SPOT_KUBECONFIG" \
    --namespace liqo-system \
    --remote-namespace liqo-system \
    --skip-confirm \
    --timeout 25m \
    --gw-server-service-type NodePort; then
    return 0
  fi

  echo "==> DIAGNOSTIC (post-failure): Spot controller-manager logs (last 150 lines)"
  kubectl --kubeconfig "$SPOT_KUBECONFIG" logs -n liqo-system \
    deploy/liqo-controller-manager --tail=150 2>&1 || true
  echo "==> DIAGNOSTIC: Hub controller-manager logs (last 50 lines)"
  kubectl logs -n liqo-system deploy/liqo-controller-manager --tail=50 2>&1 || true
  echo "==> DIAGNOSTIC: Hub crd-replicator logs (last 50 lines)"
  kubectl logs -n liqo-system deploy/liqo-crd-replicator --tail=50 2>&1 || true
  echo "==> Peering failed. Correct the reported issue and rerun Terraform apply; the next attempt repeats stale-state cleanup before peering."
  return 1
}

case "$MODE" in
  peer) peer ;;
  unpeer) unpeer ;;
  *) echo "Usage: $0 {peer|unpeer}" >&2; exit 2 ;;
esac
