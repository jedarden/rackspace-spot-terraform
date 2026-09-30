#!/usr/bin/env bash
# Initialize and operate one cluster Terraform root with its isolated state.
# Provider secrets are loaded by tf-apply.sh only after backend initialization.

set +x
set -euo pipefail

usage() {
  echo "Usage: $0 <cluster> <init|plan|apply> [terraform-options...]" >&2
  echo "Example: $0 ord-devimprint plan -var=node_count=8" >&2
}

if [[ $# -lt 2 ]]; then
  usage
  exit 2
fi

cluster_name="$1"
action="$2"
shift 2
terraform_args=("$@")

if [[ ! "$cluster_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Error: invalid cluster name: $cluster_name" >&2
  exit 2
fi

case "$action" in
  init|plan|apply) ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ "$action" == init && ${#terraform_args[@]} -gt 0 ]]; then
  echo "Error: init does not accept extra options; use the documented migration procedure when needed" >&2
  exit 2
fi

# Keep the safety-sensitive Terraform settings under wrapper control. In
# particular, applying a saved plan or using -auto-approve skips the normal
# review prompt, while -lock=false can allow concurrent state writes.
for ((index = 0; index < ${#terraform_args[@]}; index++)); do
  arg="${terraform_args[index]}"
  case "$arg" in
    -auto-approve|--auto-approve|-auto-approve=*|--auto-approve=*)
      echo "Error: automatic approval is disabled for cluster applies" >&2
      exit 2
      ;;
    -lock=false|--lock=false|-lock=false=*|--lock=false=*)
      echo "Error: Terraform state locking cannot be disabled" >&2
      exit 2
      ;;
    -lock-timeout|-lock-timeout=*|--lock-timeout|--lock-timeout=*)
      echo "Error: the cluster wrapper fixes the state lock timeout at 5m" >&2
      exit 2
      ;;
    -chdir|-chdir=*)
      echo "Error: the cluster working directory is selected by the wrapper" >&2
      exit 2
      ;;
    -state|-state=*|-state-out|-state-out=*|-backup|-backup=*)
      echo "Error: Terraform state paths are controlled by the configured remote backend" >&2
      exit 2
      ;;
    -var-file|-var-file=*)
      echo "Error: use TF_VAR_* environment variables instead of variable files with this wrapper" >&2
      exit 2
      ;;
    -input=true|--input=true)
      echo "Error: interactive variable input is disabled by the cluster wrapper" >&2
      exit 2
      ;;
    -out|-out=*|--out|--out=*|-json|--json)
      echo "Error: saved or JSON plans can expose sensitive values; use the redacted interactive plan output" >&2
      exit 2
      ;;
    -var|--var)
      if (( index + 1 >= ${#terraform_args[@]} )); then
        echo "Error: -var requires a value" >&2
        exit 2
      fi
      variable_name="${terraform_args[index + 1]%%=*}"
      case "$variable_name" in
        rackspace_spot_token|tailscale_oauth_client_id|tailscale_oauth_client_secret|github_token)
          echo "Error: pass credential variables through OpenBao, not Terraform arguments" >&2
          exit 2
          ;;
      esac
      index=$((index + 1))
      ;;
    -var=*|--var=*)
      variable_name="${arg#*=}"
      variable_name="${variable_name%%=*}"
      case "$variable_name" in
        rackspace_spot_token|tailscale_oauth_client_id|tailscale_oauth_client_secret|github_token)
          echo "Error: pass credential variables through OpenBao, not Terraform arguments" >&2
          exit 2
          ;;
      esac
      ;;
    -* ) ;;
    *)
      echo "Error: positional Terraform arguments are not accepted; review a plan before applying" >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cluster_dir="$repo_root/clusters/$cluster_name"
backend_file="$cluster_dir/backend.tf"
lock_file="$cluster_dir/.terraform.lock.hcl"
expected_state_key="state/$cluster_name/terraform.tfstate"
terraform_bin="${TERRAFORM_BIN:-terraform}"

if [[ ! -d "$cluster_dir" || ! -f "$backend_file" ]]; then
  echo "Error: cluster Terraform root not found: clusters/$cluster_name" >&2
  exit 2
fi
if [[ ! -f "$lock_file" ]]; then
  echo "Error: provider lock file not found: clusters/$cluster_name/.terraform.lock.hcl" >&2
  exit 1
fi

configured_state_key="$(awk -F '"' '
  /^[[:space:]]*key[[:space:]]*=/ {
    count++
    if (NF < 3) {
      exit 2
    }
    value = $2
  }
  END {
    if (count != 1) {
      exit 1
    }
    print value
  }
' "$backend_file")" || {
  echo "Error: expected exactly one literal backend key in clusters/$cluster_name/backend.tf" >&2
  exit 1
}

if [[ "$configured_state_key" != "$expected_state_key" ]]; then
  echo "Error: clusters/$cluster_name/backend.tf uses an unexpected state key" >&2
  echo "Expected: $expected_state_key" >&2
  exit 1
fi

if ! command -v "$terraform_bin" >/dev/null 2>&1; then
  echo "Error: Terraform executable not found: $terraform_bin" >&2
  exit 127
fi

echo "Initializing cluster $cluster_name with state key $expected_state_key"
# Backend authentication comes from the caller's AWS environment/profile. Do
# not expose OpenBao/provider credentials to Terraform init.
env \
  -u BAO_TOKEN \
  -u OPENBAO_ADDR \
  -u TF_SECRET_PATH \
  -u TF_VAR_rackspace_spot_token \
  -u TF_VAR_tailscale_oauth_client_id \
  -u TF_VAR_tailscale_oauth_client_secret \
  -u TF_VAR_github_token \
  -u TF_LOG \
  -u TF_LOG_PATH \
  -u TF_LOG_CORE \
  -u TF_LOG_PROVIDER \
  -u TF_DATA_DIR \
  -u TF_CLI_ARGS \
  -u TF_CLI_ARGS_init \
  -u TF_CLI_ARGS_plan \
  -u TF_CLI_ARGS_apply \
  TF_WORKSPACE=default \
  "$terraform_bin" -chdir="$cluster_dir" init -input=false -lockfile=readonly -no-color

if [[ "$action" == init ]]; then
  exit 0
fi

# Ignore ambient Terraform CLI overrides, debug logging, alternate data dirs,
# and workspaces so they cannot bypass the wrapper or select another state.
unset TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER TF_DATA_DIR
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply
export TF_WORKSPACE=default

cd "$cluster_dir"
exec "$repo_root/scripts/tf-apply.sh" \
  "$action" \
  -input=false \
  -lock-timeout=5m \
  -no-color \
  "${terraform_args[@]}"
