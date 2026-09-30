#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d "$repo_root/.integration-smoke.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"
export SMOKE_LOG="$temp_dir/commands.log"
export FAIL_MARKER="$temp_dir/peer-failed-once"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

cat >"$temp_dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl|%s|%s\n' "${KUBECONFIG:-<unset>}" "$*" >>"$SMOKE_LOG"
for arg in "$@"; do
  if [[ "$arg" == --from-env-file=* ]]; then
    oauth_env_file="${arg#--from-env-file=}"
    grep -Fxq "client_id=${TAILSCALE_OAUTH_CLIENT_ID}" "$oauth_env_file"
    grep -Fxq "client_secret=${TAILSCALE_OAUTH_CLIENT_SECRET}" "$oauth_env_file"
  fi
done
case "$*" in
  *"get deploy liqo-controller-manager"*) printf '1' ;;
  *"get ds liqo-fabric"*desiredNumberScheduled*) printf '1' ;;
  *"get ds liqo-fabric"*numberReady*) printf '1' ;;
  *"get configmap liqo-clusterid-configmap"*) printf 'spot-cluster-id' ;;
  *"get namespace"*) printf 'liqo-tenant-stale-spot\n' ;;
esac
STUB

cat >"$temp_dir/bin/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm|%s\n' "$*" >>"$SMOKE_LOG"
STUB

cat >"$temp_dir/bin/liqoctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'liqoctl|%s|%s\n' "${KUBECONFIG:-<unset>}" "$*" >>"$SMOKE_LOG"
if [[ "${1:-}" == peer && ! -e "$FAIL_MARKER" ]]; then
  touch "$FAIL_MARKER"
  echo 'simulated peering failure' >&2
  exit 1
fi
if [[ "${1:-}" == unpeer && "${FAIL_UNPEER:-0}" == 1 ]]; then
  echo 'simulated already-unpeered state' >&2
  exit 1
fi
STUB

chmod +x "$temp_dir/bin/kubectl" "$temp_dir/bin/helm" "$temp_dir/bin/liqoctl"
export PATH="$temp_dir/bin:$PATH"

# Exercise the exact installer called by Terraform with fake cluster/API tools.
: >"$SMOKE_LOG"
KUBECONFIG="$temp_dir/spot.kubeconfig" \
TMPDIR="$temp_dir" \
TAILSCALE_OAUTH_CLIENT_ID=test-client-id \
TAILSCALE_OAUTH_CLIENT_SECRET=test-client-secret \
TAILSCALE_OPERATOR_VERSION=1.94.2 \
CLOUDSPACE_NAME=smoke-compute \
  bash "$repo_root/scripts/install-tailscale-operator.sh"
assert_contains "$SMOKE_LOG" "kubectl|$temp_dir/spot.kubeconfig|create namespace tailscale"
assert_contains "$SMOKE_LOG" 'create namespace tailscale'
assert_contains "$SMOKE_LOG" "create secret generic operator-oauth --namespace tailscale --from-env-file=$temp_dir/tailscale-operator-oauth."
if grep -Fq 'test-client-secret' "$SMOKE_LOG"; then
  fail 'the OAuth secret must not appear in the kubectl command log'
fi
if compgen -G "$temp_dir/tailscale-operator-oauth.*" >/dev/null; then
  fail 'the temporary OAuth env file must be removed after registration bootstrap'
fi
assert_contains "$SMOKE_LOG" 'helm|upgrade --install tailscale-operator tailscale/tailscale-operator'
assert_contains "$SMOKE_LOG" '--set operatorConfig.hostname=smoke-compute'
assert_contains "$SMOKE_LOG" '--set-json operatorConfig.defaultTags=["tag:k8s-operator"]'
assert_contains "$SMOKE_LOG" '--set-json proxyConfig.defaultTags=["tag:k8s","tag:spot"]'
assert_contains "$SMOKE_LOG" 'rollout status deployment/operator --namespace tailscale --timeout=5m'

# Fail the first Liqo peer attempt, then retry. The second invocation must run
# the cleanup/restart recovery sequence and succeed with the same inputs.
: >"$SMOKE_LOG"
export HUB_KUBECONFIG=hub-smoke.kubeconfig
export SPOT_KUBECONFIG=spot-smoke.kubeconfig
export CLOUDSPACE_NAME=smoke-compute
export LIQO_CONTROLLER_ATTEMPTS=1
export LIQO_FABRIC_ATTEMPTS=1
export LIQO_POLL_INTERVAL=0
if bash "$repo_root/scripts/liqo-peer.sh" peer >"$temp_dir/peer-failure.log" 2>&1; then
  fail "a failed Liqo peer attempt must return nonzero"
fi
assert_contains "$temp_dir/peer-failure.log" 'Peering failed.'
assert_contains "$SMOKE_LOG" 'liqoctl|hub-smoke.kubeconfig|peer '
assert_contains "$SMOKE_LOG" '--remote-kubeconfig spot-smoke.kubeconfig'
assert_contains "$SMOKE_LOG" '--gw-server-service-type NodePort'
assert_contains "$SMOKE_LOG" 'kubectl|hub-smoke.kubeconfig|rollout restart deployment/liqo-controller-manager'
assert_contains "$SMOKE_LOG" 'kubectl|hub-smoke.kubeconfig|rollout restart deployment/liqo-crd-replicator'

bash "$repo_root/scripts/liqo-peer.sh" peer
peer_count="$(grep -c '^liqoctl|.*|peer ' "$SMOKE_LOG")"
[[ "$peer_count" == 2 ]] || fail "expected two peer attempts, found $peer_count"
assert_contains "$SMOKE_LOG" 'kubectl|hub-smoke.kubeconfig|delete namespace liqo-tenant-spot-cluster-id'
assert_contains "$SMOKE_LOG" 'kubectl|hub-smoke.kubeconfig|--kubeconfig spot-smoke.kubeconfig delete namespace --ignore-not-found=true liqo-tenant-stale-spot'

# Terraform's destroy provisioner calls this path. Unpeer errors are tolerated
# so teardown remains idempotent when Liqo has already removed the relationship.
FAIL_UNPEER=1 bash "$repo_root/scripts/liqo-peer.sh" unpeer
assert_contains "$SMOKE_LOG" 'liqoctl|hub-smoke.kubeconfig|unpeer --remote-kubeconfig spot-smoke.kubeconfig'

echo 'PASS: Tailscale registration configuration, Liqo failure/recovery, and teardown smoke checks'
