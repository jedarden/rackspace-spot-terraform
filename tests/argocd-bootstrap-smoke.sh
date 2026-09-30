#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$temp_dir/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1" expected="$2"
  [[ "$text" == *"$expected"* ]] || fail "expected output to contain '$expected'; got: $text"
}

cat >"$temp_dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_KUBECTL_FAIL:-0}" == 1 ]]; then
  echo 'applications.argoproj.io "applications-rs-manager" not found' >&2
  exit 1
fi
cat "$MOCK_APPLICATION_JSON"
STUB
chmod +x "$temp_dir/bin/kubectl"

cat >"$temp_dir/application.json" <<'JSON'
{
  "metadata": {"name": "applications-rs-manager", "namespace": "argocd"},
  "spec": {
    "project": "default",
    "source": {
      "repoURL": "https://github.com/jedarden/declarative-config",
      "targetRevision": "main",
      "path": "k8s/rs-manager",
      "directory": {"recurse": false, "include": "*-application.yml"}
    },
    "syncPolicy": {
      "automated": {"prune": true, "selfHeal": true},
      "syncOptions": ["CreateNamespace=true"]
    }
  },
  "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}
}
JSON

export PATH="$temp_dir/bin:$PATH"
export MOCK_APPLICATION_JSON="$temp_dir/application.json"
output="$(bash "$repo_root/scripts/check-argocd-bootstrap.sh")"
assert_contains "$output" 'PASS: ArgoCD Application'
assert_contains "$output" 'Synced and Healthy'

if MOCK_KUBECTL_FAIL=1 bash "$repo_root/scripts/check-argocd-bootstrap.sh" >"$temp_dir/missing.out" 2>&1; then
  fail 'a missing Application must fail the smoke check'
fi
assert_contains "$(cat "$temp_dir/missing.out")" 'Check the selected Kubernetes context and read access'

jq '.spec.source.repoURL = "https://wrong.example/declarative-config"' \
  "$temp_dir/application.json" >"$temp_dir/mismatch.json"
if MOCK_APPLICATION_JSON="$temp_dir/mismatch.json" \
  bash "$repo_root/scripts/check-argocd-bootstrap.sh" >"$temp_dir/mismatch.out" 2>&1; then
  fail 'a mismatched repository URL must fail the smoke check'
fi
assert_contains "$(cat "$temp_dir/mismatch.out")" 'Re-run Terraform bootstrap and inspect it with kubectl'

jq '.status.conditions = [{"type":"ComparisonError","message":"failed to load repository"}]' \
  "$temp_dir/application.json" >"$temp_dir/condition-error.json"
if MOCK_APPLICATION_JSON="$temp_dir/condition-error.json" \
  bash "$repo_root/scripts/check-argocd-bootstrap.sh" >"$temp_dir/condition-error.out" 2>&1; then
  fail 'an ArgoCD comparison error must fail the smoke check'
fi
assert_contains "$(cat "$temp_dir/condition-error.out")" 'Check repository credentials and path'

jq '.status.health.status = "Progressing"' \
  "$temp_dir/application.json" >"$temp_dir/unhealthy.json"
if MOCK_APPLICATION_JSON="$temp_dir/unhealthy.json" \
  bash "$repo_root/scripts/check-argocd-bootstrap.sh" >"$temp_dir/unhealthy.out" 2>&1; then
  fail 'an unhealthy Application must fail the smoke check'
fi
assert_contains "$(cat "$temp_dir/unhealthy.out")" 'status.health.status'

echo 'PASS: App-of-Apps smoke checker accepts a ready Application and reports actionable missing, mismatched, and unhealthy states'
