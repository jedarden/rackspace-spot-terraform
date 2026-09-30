#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "--fast" || $# -ne 1 ]]; then
  echo "Usage: $0 --fast" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_bin="${TERRAFORM_BIN:-terraform}"
temp_dir="$(mktemp -d "$repo_root/.definition-of-done.XXXXXX")"
cleanup() {
  local exit_code=$?
  if (( exit_code == 0 )); then
    rm -rf "$temp_dir"
  else
    echo "Definition-of-done diagnostics retained at $temp_dir" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT

fixture="$temp_dir/module"
mkdir -p "$fixture"
for file in "$repo_root"/*.tf; do
  [[ "${file##*/}" == backend.tf ]] || cp "$file" "$fixture/"
done
cp "$repo_root/.terraform.lock.hcl" "$fixture/"
cp -a "$repo_root/scripts" "$repo_root/tests" "$fixture/"

export TF_DATA_DIR="$temp_dir/tfdata"

"$terraform_bin" fmt -check -recursive "$fixture"
"$terraform_bin" -chdir="$fixture" init -input=false -no-color
"$terraform_bin" -chdir="$fixture" validate -no-color
"$terraform_bin" -chdir="$fixture" test \
  -filter=tests/acceptance.tftest.hcl \
  -filter=tests/output_contract.tftest.hcl \
  -filter=tests/platform_contract.tftest.hcl \
  -filter=tests/skip_components.tftest.hcl \
  -no-color

bash "$repo_root/tests/integration-smoke.sh"
bash "$repo_root/tests/argocd-bootstrap-smoke.sh"
TERRAFORM_BIN="$terraform_bin" bash "$repo_root/tests/lifecycle-smoke.sh"

echo 'PASS: Terraform formatting, validation, plan acceptance, script smoke, and lifecycle cleanup checks'
