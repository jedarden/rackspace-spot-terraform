#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [cloudspace-name] [declarative-config-path]" >&2
  echo "Checks the App-of-Apps Application created by the Terraform bootstrap." >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ "$#" -gt 2 ]]; then
  usage
  exit 2
fi

cloudspace_name="${1:-rs-manager}"
declarative_config_path="${2:-rs-manager}"
app_name="applications-${cloudspace_name}"
app_namespace="argocd"
repo_url="https://github.com/jedarden/declarative-config"
revision="main"
source_path="k8s/${declarative_config_path}"
include_glob="*-application.yml"

if [[ ! "$cloudspace_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  fail "Invalid cloudspace name '$cloudspace_name'; use a lowercase Kubernetes DNS label."
fi
if [[ "$declarative_config_path" == /* || "$declarative_config_path" == *..* ]]; then
  fail "Invalid declarative-config path '$declarative_config_path'; provide a relative path under k8s/."
fi
command -v kubectl >/dev/null || fail "kubectl is required; install it and configure KUBECONFIG for the target cloudspace."
command -v jq >/dev/null || fail "jq is required to inspect the ArgoCD Application JSON."

if ! application_json="$(kubectl -n "$app_namespace" get applications.argoproj.io "$app_name" -o json 2>&1)"; then
  fail "Could not read Application '$app_name' in namespace '$app_namespace': $application_json. Check the selected Kubernetes context and read access, then inspect the bootstrap apply."
fi

check_field() {
  local selector="$1" expected="$2" label="$3" actual
  actual="$(jq -r "$selector | if . == null then \"<missing>\" else tostring end" <<<"$application_json")" \
    || fail "Application '$app_name' returned invalid JSON; inspect it with kubectl -n $app_namespace get application $app_name -o yaml."
  if [[ "$actual" != "$expected" ]]; then
    fail "Application '$app_name' has $label '$actual'; expected '$expected'. Re-run Terraform bootstrap and inspect it with kubectl -n $app_namespace describe application $app_name."
  fi
}

check_field '.metadata.name' "$app_name" 'metadata.name'
check_field '.metadata.namespace' "$app_namespace" 'metadata.namespace'
check_field '.spec.project' 'default' 'spec.project'
check_field '.spec.source.repoURL' "$repo_url" 'spec.source.repoURL'
check_field '.spec.source.targetRevision' "$revision" 'spec.source.targetRevision'
check_field '.spec.source.path' "$source_path" 'spec.source.path'
check_field '.spec.source.directory.recurse' 'false' 'spec.source.directory.recurse'
check_field '.spec.source.directory.include' "$include_glob" 'spec.source.directory.include'
check_field '.spec.syncPolicy.automated.prune' 'true' 'spec.syncPolicy.automated.prune'
check_field '.spec.syncPolicy.automated.selfHeal' 'true' 'spec.syncPolicy.automated.selfHeal'

if ! jq -e 'any(.spec.syncPolicy.syncOptions[]?; . == "CreateNamespace=true")' \
  <<<"$application_json" >/dev/null; then
  fail "Application '$app_name' is missing sync option CreateNamespace=true; re-run Terraform bootstrap and inspect it with kubectl -n $app_namespace describe application $app_name."
fi

conditions="$(jq -c '[.status.conditions[]? | select(.type == "ComparisonError" or .type == "SyncError" or .type == "InvalidSpecError" or .type == "UnknownError") | {type, message}]' <<<"$application_json")"
if [[ "$conditions" != '[]' ]]; then
  fail "ArgoCD reports Application errors: $conditions. Check repository credentials and path, then inspect with kubectl -n $app_namespace describe application $app_name."
fi

check_field '.status.sync.status' 'Synced' 'status.sync.status'
check_field '.status.health.status' 'Healthy' 'status.health.status'

echo "PASS: ArgoCD Application '$app_name' matches $repo_url@$revision:$source_path and is Synced and Healthy."
