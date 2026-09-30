#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?KUBECONFIG must name the Spot cluster credentials}"
: "${TAILSCALE_OAUTH_CLIENT_ID:?TAILSCALE_OAUTH_CLIENT_ID is required}"
: "${TAILSCALE_OAUTH_CLIENT_SECRET:?TAILSCALE_OAUTH_CLIENT_SECRET is required}"
: "${TAILSCALE_OPERATOR_VERSION:?TAILSCALE_OPERATOR_VERSION is required}"
: "${CLOUDSPACE_NAME:?CLOUDSPACE_NAME is required}"

export PATH="/tmp:$PATH"
umask 077
oauth_env_file="$(mktemp "${TMPDIR:-/tmp}/tailscale-operator-oauth.XXXXXX")"
trap 'rm -f "$oauth_env_file"' EXIT
printf 'client_id=%s\nclient_secret=%s\n' \
  "$TAILSCALE_OAUTH_CLIENT_ID" "$TAILSCALE_OAUTH_CLIENT_SECRET" >"$oauth_env_file"

kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic operator-oauth \
  --namespace tailscale \
  --from-env-file="$oauth_env_file" \
  --dry-run=client -o yaml | kubectl apply -f -

helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --version "${TAILSCALE_OPERATOR_VERSION}" \
  --timeout 15m \
  --set installCRDs=true \
  --set oauth.secretName=operator-oauth \
  --set "operatorConfig.hostname=${CLOUDSPACE_NAME}" \
  --set-json 'operatorConfig.defaultTags=["tag:k8s-operator"]' \
  --set-json 'proxyConfig.defaultTags=["tag:k8s","tag:spot"]'

# The chart may not roll pods when an existing Secret changes. Restart the
# operator after updating operator-oauth so it loads the new credentials.
kubectl rollout restart deployment/operator --namespace tailscale
kubectl rollout status deployment/operator --namespace tailscale --timeout=5m
