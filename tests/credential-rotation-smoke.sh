#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$repo_root/docs/credential-rotation.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_documented() {
  local heading="$1"
  shift
  local section
  section="$(awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$doc")"
  [[ -n "$section" ]] || fail "missing section: $heading"
  for requirement in "$@"; do
    grep -Fq -- "$requirement" <<<"$section" || fail "$heading is missing: $requirement"
  done
}

[[ -f "$doc" ]] || fail 'credential rotation runbook is missing'
for requirement in \
  'secret/rs-manager/rackspace-spot-terraform/credentials' \
  'bao-as rs-manager-provision' \
  '-method=patch' \
  '-cas=' \
  'token=-' \
  'current_version' \
  'permanently purge' \
  'post-revocation'; do
  grep -Fq -- "$requirement" "$doc" || fail "runbook is missing: $requirement"
done

assert_documented '## Rackspace Spot token' \
  'organization-level' 'tf-apply.sh plan' 'tf-cluster.sh ord-devimprint plan' \
  'revoke the old token' 'run the root plan again'
assert_documented '## Tailscale OAuth client' \
  'tailscale_oauth_client_id' 'tailscale_oauth_client_secret' \
  'null_resource.tailscale' 'rollout' 'Then revoke the old'
assert_documented '## GitHub PAT for ArgoCD' \
  'github_token' 'null_resource.argocd' 'declarative-config-repo' \
  'repository connection status' 'Revoke the old PAT'
assert_documented '## Retirement, revocation, and recovery' \
  'immediately' 'permanently purge' 'metadata only' 'Terraform or the consumer fails'

echo 'PASS: rotation, post-revocation validation, and OpenBao retirement procedures are documented'
