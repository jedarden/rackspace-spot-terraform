#!/usr/bin/env bash
# Seed rackspace-spot-terraform secrets into OpenBao
# Run this once to migrate secrets from rs-manager.tfvars to OpenBao
#
# Usage: ./scripts/seed-openbao.sh
#
# This script:
#   1. Reads existing secrets from rs-manager.tfvars (if present)
#   2. Prompts for any missing secrets
#   3. Writes them to OpenBao at secret/rackspace-spot-terraform/rs-manager
#
# After seeding:
#   - Delete rs-manager.tfvars (gitignored, single-point-of-failure)
#   - Use scripts/tf-apply.sh for all terraform applies

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

SECRET_PATH="secret/rackspace-spot-terraform/rs-manager"
TFVARS_FILE="rs-manager.tfvars"

echo "=== Seeding Rackspace Spot Terraform secrets to OpenBao ==="
echo "OpenBao endpoint: ${OPENBAO_ADDR}"
echo "Secret path: ${SECRET_PATH}"
echo ""

# Function to extract value from tfvars file
extract_from_tfvars() {
  local key="$1"
  local file="$2"
  if [[ -f "${file}" ]]; then
    grep -E "^${key}\\s*=\\s*" "${file}" | sed -E 's/.*=\s*["'"'"']?([^'"'"'""]*)["'"'"']?.*/\1/' | tr -d ' '
  fi
}

# Try to read existing values from tfvars file
echo "Checking for existing values in ${TFVARS_FILE}..."
RACKSPACE_SPOT_TOKEN=$(extract_from_tfvars "rackspace_spot_token" "${TFVARS_FILE}")
TAILSCALE_CLIENT_ID=$(extract_from_tfvars "tailscale_oauth_client_id" "${TFVARS_FILE}")
TAILSCALE_CLIENT_SECRET=$(extract_from_tfvars "tailscale_oauth_client_secret" "${TFVARS_FILE}")
GITHUB_TOKEN=$(extract_from_tfvars "github_token" "${TFVARS_FILE}")

# Prompt for any missing values
if [[ -z "${RACKSPACE_SPOT_TOKEN}" ]]; then
  echo -n "Enter Rackspace Spot API token: "
  read -rs RACKSPACE_SPOT_TOKEN
  echo ""
else
  echo "✓ Found rackspace_spot_token in ${TFVARS_FILE}"
fi

if [[ -z "${TAILSCALE_CLIENT_ID}" ]]; then
  echo -n "Enter Tailscale OAuth client ID: "
  read -rs TAILSCALE_CLIENT_ID
  echo ""
else
  echo "✓ Found tailscale_oauth_client_id in ${TFVARS_FILE}"
fi

if [[ -z "${TAILSCALE_CLIENT_SECRET}" ]]; then
  echo -n "Enter Tailscale OAuth client secret: "
  read -rs TAILSCALE_CLIENT_SECRET
  echo ""
else
  echo "✓ Found tailscale_oauth_client_secret in ${TFVARS_FILE}"
fi

if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo -n "Enter GitHub token: "
  read -rs GITHUB_TOKEN
  echo ""
else
  echo "✓ Found github_token in ${TFVARS_FILE}"
fi

# Validate all values are present
if [[ -z "${RACKSPACE_SPOT_TOKEN}" ]] || [[ -z "${TAILSCALE_CLIENT_ID}" ]] || \
   [[ -z "${TAILSCALE_CLIENT_SECRET}" ]] || [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "Error: All secrets are required. Aborting." >&2
  exit 1
fi

# Write to OpenBao using bao CLI
echo ""
echo "Writing secrets to OpenBao at ${SECRET_PATH}..."

bao kv put "${SECRET_PATH}" \
  rackspace_spot_token="${RACKSPACE_SPOT_TOKEN}" \
  tailscale_oauth_client_id="${TAILSCALE_CLIENT_ID}" \
  tailscale_oauth_client_secret="${TAILSCALE_CLIENT_SECRET}" \
  github_token="${GITHUB_TOKEN}" || {
  echo "Error: Failed to write secrets to OpenBao" >&2
  exit 1
}

echo "✓ Secrets successfully written to OpenBao"

# Verify by reading back
echo ""
echo "Verifying secrets were written correctly..."
bao kv get "${SECRET_PATH}" || {
  echo "Warning: Could not verify secrets (check manually with: bao kv get ${SECRET_PATH})" >&2
}

echo ""
echo "=== Next steps ==="
echo "1. Verify secrets in OpenBao:"
echo "   bao kv get ${SECRET_PATH}"
echo ""
echo "2. Test the terraform apply wrapper:"
echo "   ./scripts/tf-apply.sh plan"
echo ""
echo "3. If everything works, delete the local tfvars file:"
echo "   rm ${TFVARS_FILE}"
echo ""
echo "4. All future applies should use:"
echo "   ./scripts/tf-apply.sh [terraform-args...]"
