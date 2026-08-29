#!/usr/bin/env bash
# Seed rackspace-spot-terraform secrets into OpenBao
# Run this once to migrate secrets from rs-manager.tfvars to OpenBao
#
# Usage: ./scripts/seed-openbao.sh
#
# This script:
#   1. Reads existing secrets from rs-manager.tfvars (if present)
#   2. Prompts for any missing secrets
#   3. Writes them to OpenBao at secret/rs-manager/rackspace-spot-terraform/credentials
#      (override with TF_SECRET_PATH). Values travel to bao via a mode-600 @file,
#      never as command-line arguments, and are never echoed back.
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

SECRET_PATH="${TF_SECRET_PATH:-secret/rs-manager/rackspace-spot-terraform/credentials}"
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

# Write to OpenBao using bao CLI.
# The values go through a mode-600 temp file passed as @file so they never appear
# in argv (ps, shell history, transcripts). jq reads them from the environment.
echo ""
echo "Writing secrets to OpenBao at ${SECRET_PATH}..."

umask 077
PAYLOAD="$(mktemp -t seed-openbao.XXXXXX.json)"
trap 'rm -f "${PAYLOAD}"' EXIT
export RACKSPACE_SPOT_TOKEN TAILSCALE_CLIENT_ID TAILSCALE_CLIENT_SECRET GITHUB_TOKEN
jq -n '{
  rackspace_spot_token:          $ENV.RACKSPACE_SPOT_TOKEN,
  tailscale_oauth_client_id:     $ENV.TAILSCALE_CLIENT_ID,
  tailscale_oauth_client_secret: $ENV.TAILSCALE_CLIENT_SECRET,
  github_token:                  $ENV.GITHUB_TOKEN
}' > "${PAYLOAD}"

bao kv put "${SECRET_PATH}" @"${PAYLOAD}" > /dev/null || {
  echo "Error: Failed to write secrets to OpenBao" >&2
  exit 1
}
rm -f "${PAYLOAD}"

echo "✓ Secrets successfully written to OpenBao"

# Verify by property (version/timestamp), never by printing the values back
echo ""
echo "Verifying write (metadata only)..."
bao kv metadata get -format=json "${SECRET_PATH}" \
  | jq -r '"  version \(.data.current_version) written \(.data.updated_time)"' || {
  echo "Warning: Could not read metadata (check manually with: bao kv metadata get ${SECRET_PATH})" >&2
}

echo ""
echo "=== Next steps ==="
echo "1. Verify secrets in OpenBao (metadata only — never kv get, it prints the values):"
echo "   bao kv metadata get ${SECRET_PATH}"
echo ""
echo "2. Test the terraform apply wrapper:"
echo "   ./scripts/tf-apply.sh plan"
echo ""
echo "3. If everything works, delete the local tfvars file:"
echo "   rm ${TFVARS_FILE}"
echo ""
echo "4. All future applies should use:"
echo "   ./scripts/tf-apply.sh [terraform-args...]"
