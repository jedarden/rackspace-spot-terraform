#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d "$repo_root/.cluster-apply.XXXX")"
cleanup() {
  local exit_code=$?
  if (( exit_code == 0 )); then
    rm -rf "$temp_dir"
  else
    echo "Cluster apply smoke diagnostics retained at $temp_dir" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local content="$1"
  local expected="$2"
  [[ "$content" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_secret_absent() {
  local content="$1"
  local secret="$2"
  [[ "$content" != *"$secret"* ]] || fail 'a credential value appeared in wrapper output'
}

fixture="$temp_dir/repo"
mkdir -p "$fixture/scripts" "$fixture/clusters/ord-devimprint" "$temp_dir/bin"
cp "$repo_root/scripts/tf-cluster.sh" "$repo_root/scripts/tf-apply.sh" "$fixture/scripts/"
cat >"$fixture/clusters/ord-devimprint/backend.tf" <<'HCL'
terraform {
  backend "s3" {
    key = "state/ord-devimprint/terraform.tfstate"
  }
}
HCL
touch "$fixture/clusters/ord-devimprint/.terraform.lock.hcl"

cat >"$temp_dir/bin/bao" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${BAO_TOKEN:-}" == "$EXPECTED_BAO_TOKEN" ]] || {
  echo 'mock OpenBao did not receive its token through the environment' >&2
  exit 1
}
[[ "${OPENBAO_ADDR:-}" == 'http://openbao-test.invalid:8200' ]] || {
  echo 'mock OpenBao did not receive its endpoint through the environment' >&2
  exit 1
}
[[ "$*" == 'kv get -format=json secret/rs-manager/rackspace-spot-terraform/credentials' ]] || {
  echo 'unexpected OpenBao arguments' >&2
  exit 1
}
printf 'bao|%s\n' "$*" >>"$CALL_LOG"
cat <<'JSON'
{"data":{"data":{"token":"spot-secret-sentinel","tailscale_oauth_client_id":"ts-client-sentinel","tailscale_oauth_client_secret":"ts-secret-sentinel","github_token":"github-secret-sentinel"}}}
JSON
STUB

cat >"$temp_dir/bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == -chdir=* && "${2:-}" == init ]]; then
  [[ -z "${BAO_TOKEN:-}" ]] || {
    echo 'OpenBao token leaked into terraform init' >&2
    exit 1
  }
  [[ -z "${OPENBAO_ADDR:-}" && -z "${TF_SECRET_PATH:-}" ]] || {
    echo 'OpenBao configuration leaked into terraform init' >&2
    exit 1
  }
  [[ -z "${TF_VAR_rackspace_spot_token:-}" ]] || {
    echo 'provider secret leaked into terraform init' >&2
    exit 1
  }
  [[ "${TF_WORKSPACE:-}" == default && -z "${TF_DATA_DIR:-}" ]] || {
    echo 'terraform init did not use the isolated default workspace/data directory' >&2
    exit 1
  }
  [[ -z "${TF_CLI_ARGS:-}${TF_CLI_ARGS_init:-}${TF_CLI_ARGS_plan:-}${TF_CLI_ARGS_apply:-}" ]] || {
    echo 'ambient Terraform CLI arguments reached init' >&2
    exit 1
  }
  printf 'terraform-init|%s\n' "$*" >>"$CALL_LOG"
  exit 0
fi

[[ -z "${BAO_TOKEN:-}" ]] || {
  echo 'OpenBao token leaked into Terraform' >&2
  exit 1
}
[[ -z "${OPENBAO_ADDR:-}" && -z "${TF_SECRET_PATH:-}" ]] || {
  echo 'OpenBao configuration leaked into Terraform' >&2
  exit 1
}
[[ "${TF_WORKSPACE:-}" == default && -z "${TF_DATA_DIR:-}" ]] || {
  echo 'cluster operation did not use the default workspace and local data directory' >&2
  exit 1
}
[[ -z "${TF_CLI_ARGS:-}${TF_CLI_ARGS_init:-}${TF_CLI_ARGS_plan:-}${TF_CLI_ARGS_apply:-}" ]] || {
  echo 'ambient Terraform CLI arguments reached a cluster operation' >&2
  exit 1
}
[[ "${TF_VAR_rackspace_spot_token:-}" == 'spot-secret-sentinel' ]] || exit 1
[[ "${TF_VAR_tailscale_oauth_client_id:-}" == 'ts-client-sentinel' ]] || exit 1
[[ "${TF_VAR_tailscale_oauth_client_secret:-}" == 'ts-secret-sentinel' ]] || exit 1
[[ "${TF_VAR_github_token:-}" == 'github-secret-sentinel' ]] || exit 1
case "$*" in
  *spot-secret-sentinel*|*ts-client-sentinel*|*ts-secret-sentinel*|*github-secret-sentinel*)
    echo 'provider secret leaked into Terraform arguments' >&2
    exit 1
    ;;
esac
printf 'terraform-run|%s\n' "$*" >>"$CALL_LOG"
STUB

chmod +x "$temp_dir/bin/bao" "$temp_dir/bin/terraform"
export PATH="$temp_dir/bin:$PATH"
export TERRAFORM_BIN="$temp_dir/bin/terraform"
export CALL_LOG="$temp_dir/calls.log"
export EXPECTED_BAO_TOKEN='openbao-token-sentinel'
export BAO_TOKEN="$EXPECTED_BAO_TOKEN"
export OPENBAO_ADDR='http://openbao-test.invalid:8200'
export TF_CLI_ARGS='-auto-approve'
export TF_CLI_ARGS_init='-lock=false'
export TF_CLI_ARGS_plan='-lock=false'
export TF_CLI_ARGS_apply='-auto-approve -lock=false'
export TF_LOG=TRACE
export TF_DATA_DIR="$temp_dir/externally-selected-tfdata"
export TF_WORKSPACE=unexpected-workspace

# Explicit init is backend-only and does not require OpenBao credentials.
init_output="$("$fixture/scripts/tf-cluster.sh" ord-devimprint init 2>&1)" || {
  echo "$init_output" >&2
  fail 'backend-only initialization failed'
}
assert_contains "$init_output" 'state/ord-devimprint/terraform.tfstate'
assert_contains "$(cat "$CALL_LOG")" "$fixture/clusters/ord-devimprint"
assert_contains "$(cat "$CALL_LOG")" '-lockfile=readonly'
if grep -Fq 'bao|' "$CALL_LOG"; then
  fail 'init fetched provider credentials from OpenBao'
fi

# Plan initializes first, then fetches OpenBao secrets, then invokes Terraform
# with the fixed lock timeout. No credential value may appear in output or argv.
: >"$CALL_LOG"
plan_output="$("$fixture/scripts/tf-cluster.sh" ord-devimprint plan -var=node_count=8 2>&1)" || {
  echo "$plan_output" >&2
  fail 'cluster plan failed'
}
for secret in "$EXPECTED_BAO_TOKEN" spot-secret-sentinel ts-client-sentinel ts-secret-sentinel github-secret-sentinel; do
  assert_secret_absent "$plan_output" "$secret"
done
calls="$(cat "$CALL_LOG")"
init_line="$(grep -n '^terraform-init|' <<<"$calls" | cut -d: -f1)"
bao_line="$(grep -n '^bao|' <<<"$calls" | cut -d: -f1)"
plan_line="$(grep -n '^terraform-run|plan ' <<<"$calls" | cut -d: -f1)"
[[ -n "$init_line" && -n "$bao_line" && -n "$plan_line" ]] || fail 'plan did not initialize, fetch secrets, and run in order'
(( init_line < bao_line && bao_line < plan_line )) || fail 'backend init, OpenBao lookup, and plan ran out of order'
assert_contains "$calls" '-lock-timeout=5m'
assert_contains "$calls" '-input=false'
assert_contains "$calls" '-var=node_count=8'
for secret in "$EXPECTED_BAO_TOKEN" spot-secret-sentinel ts-client-sentinel ts-secret-sentinel github-secret-sentinel; do
  assert_secret_absent "$calls" "$secret"
done

# Apply also loads secrets only after init and leaves Terraform's approval
# prompt enabled; unsafe command-line bypasses and saved-plan application fail
# before either Terraform or OpenBao is invoked.
: >"$CALL_LOG"
apply_output="$("$fixture/scripts/tf-cluster.sh" ord-devimprint apply 2>&1)" || {
  echo "$apply_output" >&2
  fail 'cluster apply failed'
}
calls="$(cat "$CALL_LOG")"
assert_contains "$calls" 'terraform-run|apply -input=false -lock-timeout=5m -no-color'
for secret in "$EXPECTED_BAO_TOKEN" spot-secret-sentinel ts-client-sentinel ts-secret-sentinel github-secret-sentinel; do
  assert_secret_absent "$apply_output" "$secret"
  assert_secret_absent "$calls" "$secret"
done

expect_rejected() {
  local description="$1"
  shift
  : >"$CALL_LOG"
  if output="$("$fixture/scripts/tf-cluster.sh" "$@" 2>&1)"; then
    fail "$description was unexpectedly accepted"
  fi
  [[ ! -s "$CALL_LOG" ]] || fail "$description reached Terraform or OpenBao"
}

expect_rejected 'auto-approved apply' ord-devimprint apply -auto-approve
expect_rejected 'disabled state locking' ord-devimprint plan -lock=false
expect_rejected 'overridden lock timeout' ord-devimprint plan -lock-timeout=0s
expect_rejected 'saved plan positional argument' ord-devimprint apply reviewed.tfplan
expect_rejected 'saved plan output' ord-devimprint plan -out=reviewed.tfplan
expect_rejected 'JSON plan output' ord-devimprint plan -json
expect_rejected 'alternate local state path' ord-devimprint apply -state=other.tfstate
expect_rejected 'credential variable in argv' ord-devimprint plan -var=rackspace_spot_token=spot-secret-sentinel
expect_rejected 'credential variable in separate argv' ord-devimprint plan -var rackspace_spot_token=spot-secret-sentinel
expect_rejected 'variable file' ord-devimprint plan -var-file=private.tfvars
expect_rejected 'cluster path traversal' ../ord-devimprint plan

# A mismatched key fails before initialization, avoiding accidental use of the
# root module's state object.
: >"$CALL_LOG"
sed -i 's#state/ord-devimprint/terraform.tfstate#state/root/terraform.tfstate#' \
  "$fixture/clusters/ord-devimprint/backend.tf"
if output="$("$fixture/scripts/tf-cluster.sh" ord-devimprint plan 2>&1)"; then
  fail 'a cluster root with the root state key was unexpectedly accepted'
fi
assert_contains "$output" 'unexpected state key'
[[ ! -s "$CALL_LOG" ]] || fail 'state key mismatch reached Terraform or OpenBao'

echo 'PASS: cluster backend selection, init order, lock timeout, secret redaction, and interactive apply safeguards'
