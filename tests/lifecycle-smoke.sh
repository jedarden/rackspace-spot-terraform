#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_bin="${TERRAFORM_BIN:-terraform}"
lifecycle_root="${LIFECYCLE_SMOKE_ROOT:-$repo_root}"
temp_dir="$(mktemp -d "$lifecycle_root/.l.XXXX")"
cleanup() {
  local exit_code=$?
  if (( exit_code == 0 )); then
    rm -rf "$temp_dir"
  else
    echo "Lifecycle smoke diagnostics retained at $temp_dir" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_absent() {
  [[ ! -e "$1" ]] || fail "expected temporary artifact to be removed: $1"
}

version_json="$("$terraform_bin" version -json)"
version_minor="$(jq -r '.terraform_version | split(".") | (.[0] | tonumber) * 100 + (.[1] | tonumber)' <<<"$version_json")"
(( version_minor >= 110 )) || fail "Terraform 1.10 or later is required; $terraform_bin is too old"

fixture="$temp_dir/module"
mkdir -p "$fixture" "$temp_dir/bin" "$temp_dir/tmp"

# The production root configures a remote S3 backend. Test a copy without that
# backend so the lifecycle test cannot read or write the real Terraform state.
for file in "$repo_root"/*.tf; do
  [[ "${file##*/}" == backend.tf ]] || cp "$file" "$fixture/"
done
cp "$repo_root/.terraform.lock.hcl" "$fixture/"
cp -a "$repo_root/scripts" "$repo_root/tests" "$fixture/"

cat >"$temp_dir/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${KUBECONFIG:-}" && -f "$KUBECONFIG" ]] || {
  echo 'KUBECONFIG is missing during bootstrap' >&2
  exit 1
}
printf 'kubectl|%s\n' "$*" >>"$COMMAND_LOG"
for arg in "$@"; do
  if [[ "$arg" == --from-env-file=* ]]; then
    oauth_env_file="${arg#--from-env-file=}"
    grep -Fxq 'client_id=test-tailscale-client' "$oauth_env_file"
    grep -Fxq 'client_secret=test-tailscale-secret' "$oauth_env_file"
  fi
done
case "$*" in
  'create namespace '*|'create secret generic '*) printf 'apiVersion: v1\nkind: ConfigMap\n' ;;
  'apply -f -') cat >/dev/null ;;
  'rollout restart deployment/operator '*) ;;
  'rollout status deployment/operator '*) ;;
  *) echo "unexpected kubectl command: $*" >&2; exit 1 ;;
esac
STUB

cat >"$temp_dir/bin/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm|%s\n' "$*" >>"$COMMAND_LOG"
if [[ "${1:-}" == version ]]; then
  echo 'v3.17.0+mock'
  exit 0
fi
if [[ "${1:-}" == repo ]]; then
  exit 0
fi
if [[ "${1:-}" == upgrade && "${2:-}" == --install && "${3:-}" == tailscale-operator && ! -e "$FAIL_MARKER" ]]; then
  touch "$FAIL_MARKER"
  echo 'simulated bootstrap failure' >&2
  exit 17
fi
STUB

cat >"$temp_dir/bin/liqoctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'liqoctl|%s\n' "$*" >>"$COMMAND_LOG"
echo 'liqoctl version mock'
STUB

chmod +x "$temp_dir/bin/kubectl" "$temp_dir/bin/helm" "$temp_dir/bin/liqoctl"
export PATH="$temp_dir/bin:$PATH"
export TMPDIR="${LIFECYCLE_SMOKE_TMPDIR:-$temp_dir}"
mkdir -p "$TMPDIR"
export COMMAND_LOG="$temp_dir/commands.log"
export FAIL_MARKER="$temp_dir/bootstrap-failed-once"
export TF_DATA_DIR="$temp_dir/tfdata"

"$terraform_bin" -chdir="$fixture" init -input=false -no-color

cloudspace_name="lifecycle-cleanup-$$"
kubeconfig="/tmp/${cloudspace_name}.kubeconfig"
assert_absent "$kubeconfig"

# The first apply leaves Spot resources and a kubeconfig behind until the
# Terraform test runner performs its partial-state cleanup. The one-shot Helm
# error proves that cleanup is exercised after a bootstrap provisioner fails.
if "$terraform_bin" -chdir="$fixture" test \
  -filter=tests/lifecycle_cleanup.tftest.hcl \
  -no-color \
  -var="cloudspace_name=$cloudspace_name" >"$temp_dir/failure.log" 2>&1; then
  fail 'the injected first bootstrap failure unexpectedly passed'
fi
grep -Fq 'simulated bootstrap failure' "$temp_dir/failure.log" || {
  cat "$temp_dir/failure.log" >&2
  fail 'the first apply did not reach the injected bootstrap failure'
}
grep -Fq 'tests/lifecycle_cleanup.tftest.hcl... tearing down' "$temp_dir/failure.log" || {
  cat "$temp_dir/failure.log" >&2
  fail 'Terraform did not attempt teardown after the partial apply'
}
[[ -e "$FAIL_MARKER" ]] || fail 'the bootstrap failure stub did not run'
assert_absent "$kubeconfig"
if compgen -G "$temp_dir/tmp/tailscale-operator-oauth.*" >/dev/null; then
  fail 'the OAuth environment file was left behind after failed bootstrap'
fi
if grep -Eiq 'failed to destroy|could not destroy|cleanup failed|encountered an error destroying|left the following resources in state' "$temp_dir/failure.log"; then
  cat "$temp_dir/failure.log" >&2
  fail 'Terraform reported that partial Spot resources could not be cleaned up'
fi

# Reapply with the same cluster name after the transient bootstrap error. The
# test starts with fresh in-memory state, so success also proves the failed
# attempt did not strand the kubeconfig or prevent recreation and teardown.
: >"$COMMAND_LOG"
"$terraform_bin" -chdir="$fixture" test \
  -filter=tests/lifecycle_cleanup.tftest.hcl \
  -no-color \
  -var="cloudspace_name=$cloudspace_name" >"$temp_dir/retry.log" 2>&1 || {
    cat "$temp_dir/retry.log" >&2
    fail 'the retry apply or its teardown failed'
  }
grep -Fq 'tests/lifecycle_cleanup.tftest.hcl... tearing down' "$temp_dir/retry.log" || {
  cat "$temp_dir/retry.log" >&2
  fail 'Terraform did not tear down the successful retry'
}
grep -Fq 'tests/lifecycle_cleanup.tftest.hcl... pass' "$temp_dir/retry.log" || {
  cat "$temp_dir/retry.log" >&2
  fail 'Terraform did not complete teardown after the successful retry'
}
if grep -Fq 'left the following resources in state' "$temp_dir/retry.log"; then
  cat "$temp_dir/retry.log" >&2
  fail 'Terraform left Spot resources in state after the successful retry'
fi
grep -Fq 'upgrade --install tailscale-operator tailscale/tailscale-operator' "$COMMAND_LOG" ||
  fail 'the retry did not complete the Tailscale bootstrap command'
restart_line="$(grep -n -F 'kubectl|rollout restart deployment/operator --namespace tailscale' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
status_line="$(grep -n -F 'kubectl|rollout status deployment/operator --namespace tailscale --timeout=5m' "$COMMAND_LOG" | head -1 | cut -d: -f1)"
[[ -n "$restart_line" && -n "$status_line" ]] || fail 'the retry did not restart and wait for the Tailscale operator'
(( restart_line < status_line )) || fail 'the Tailscale operator rollout was checked before it was restarted'
assert_absent "$kubeconfig"
if compgen -G "$temp_dir/tmp/tailscale-operator-oauth.*" >/dev/null; then
  fail 'the OAuth environment file was left behind after retry and destroy'
fi

echo 'PASS: failed bootstrap cleanup, retry, Spot resource teardown, kubeconfig removal, and OAuth file removal'
