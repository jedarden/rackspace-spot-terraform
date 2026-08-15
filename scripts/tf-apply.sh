#!/usr/bin/env bash
# Terraform apply wrapper for rackspace-spot-terraform
# Fetches sensitive variables from OpenBao and exports them as TF_VAR_* before calling terraform
#
# Usage: ./scripts/tf-apply.sh [terraform-args...]
#
# Requires:
#   - BAO_TOKEN environment variable (OpenBao token with read access to secret/rackspace-spot-terraform/*)
#   - bao CLI in PATH (installed on ex44 and lab servers)

set -euo pipefail

# OpenBao configuration
OPENBAO_ADDR="${OPENBAO_ADDR:-http://traefik-rs-manager:8200}"
export OPENBAO_ADDR

# Check for BAO_TOKEN
if [[ -z "${BAO_TOKEN:-}" ]]; then
  echo "Error: BAO_TOKEN environment variable not set" >&2
  echo "Please set it with: export BAO_TOKEN=hvs.your-token-here" >&2
  exit 1
fi

# Path in OpenBao where secrets are stored
SECRET_PATH="secret/rackspace-spot-terraform/rs-manager"

echo "Fetching secrets from OpenBao: ${SECRET_PATH}"

# Fetch secrets from OpenBao (KV v2)
SECRETS_JSON=$(bao kv get -format=json "${SECRET_PATH}" 2>/dev/null || {
  echo "Error: Failed to fetch secrets from OpenBao" >&2
  echo "Ensure:" >&2
  echo "  1. OpenBao is reachable at ${OPENBAO_ADDR}" >&2
  echo "  2. BAO_TOKEN is valid and has read access to ${SECRET_PATH}" >&2
  echo "  3. Secrets have been seeded to OpenBao" >&2
  exit 1
})

# Extract individual secrets and export as TF_VAR_*
export TF_VAR_rackspace_spot_token=$(echo "${SECRETS_JSON}" | jq -r '.data.data.rackspace_spot_token // empty')
export TF_VAR_tailscale_oauth_client_id=$(echo "${SECRETS_JSON}" | jq -r '.data.data.tailscale_oauth_client_id // empty')
export TF_VAR_tailscale_oauth_client_secret=$(echo "${SECRETS_JSON}" | jq -r '.data.data.tailscale_oauth_client_secret // empty')
export TF_VAR_github_token=$(echo "${SECRETS_JSON}" | jq -r '.data.data.github_token // empty')

# Verify all required secrets are present
REQUIRED_SECRETS=(
  "rackspace_spot_token"
  "tailscale_oauth_client_id"
  "tailscale_oauth_client_secret"
  "github_token"
)

MISSING_SECRETS=()
for secret in "${REQUIRED_SECRETS[@]}"; do
  var_name="TF_VAR_${secret}"
  if [[ -z "${!var_name:-}" ]]; then
    MISSING_SECRETS+=("${secret}")
  fi
done

if [[ ${#MISSING_SECRETS[@]} -gt 0 ]]; then
  echo "Error: Missing required secrets from OpenBao: ${MISSING_SECRETS[*]}" >&2
  echo "Ensure these values are set at ${SECRET_PATH} in OpenBao" >&2
  exit 1
fi

echo "✓ All secrets fetched successfully"

# Run terraform with any passed arguments
echo "Running: terraform $*"
exec terraform "$@"
