#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--fast" ) ]]; then
  echo "Usage: $0 [--fast]" >&2
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

terraform_version_json="$("$terraform_bin" version -json 2>/dev/null || true)"
terraform_version="$(jq -r '.terraform_version // empty' <<<"$terraform_version_json" 2>/dev/null || true)"
terraform_supported=0
if [[ "$terraform_version" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
  terraform_major="${BASH_REMATCH[1]}"
  terraform_minor="${BASH_REMATCH[2]}"
  if (( terraform_major > 1 || (terraform_major == 1 && terraform_minor >= 10) )); then
    terraform_supported=1
  fi
fi

if (( ! terraform_supported )); then
  if [[ -n "${TERRAFORM_BIN:-}" ]]; then
    echo "Terraform 1.10 or later is required; TERRAFORM_BIN='$terraform_bin' is missing or too old" >&2
    exit 1
  fi

  terraform_version='1.10.5'
  terraform_sha256='0566a24f5332098b15716ebc394be503f4094acba5ba529bf5eb0698ed5e2a90'
  terraform_archive="$temp_dir/terraform_${terraform_version}_linux_amd64.zip"
  terraform_dir="$temp_dir/terraform-bin"
  mkdir -p "$terraform_dir"
  curl --fail --location --silent --show-error --retry 3 \
    "https://releases.hashicorp.com/terraform/${terraform_version}/terraform_${terraform_version}_linux_amd64.zip" \
    --output "$terraform_archive"
  printf '%s  %s\n' "$terraform_sha256" "$terraform_archive" | sha256sum --check --status || {
    echo 'Terraform download checksum verification failed' >&2
    exit 1
  }
  python3 - "$terraform_archive" "$terraform_dir" <<'PY'
import shutil
import sys
import zipfile
from pathlib import Path

archive_path = Path(sys.argv[1])
target_path = Path(sys.argv[2]) / "terraform"
with zipfile.ZipFile(archive_path) as archive:
    with archive.open("terraform") as source, target_path.open("wb") as target:
        shutil.copyfileobj(source, target)
target_path.chmod(0o755)
PY
  terraform_bin="$terraform_dir/terraform"
  echo "Using Terraform $terraform_version from the verified HashiCorp release archive" >&2
fi

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
