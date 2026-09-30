# Terraform Scripts

This directory contains wrapper scripts for managing Terraform operations with OpenBao secret integration.

## Definition of done

Run `scripts/definition-of-done.sh` from the repository root, or pass `--fast`
explicitly. Both forms check Terraform formatting and validation, all plan-only
Terraform acceptance tests, the bootstrap, ArgoCD, and cluster-apply shell
smoke tests, and the failure/retry/destroy lifecycle test. The Terraform tests
run from a temporary copy without the S3 backend. The lifecycle test uses a
mocked Spot provider and stubbed Kubernetes tools; it does not create
Rackspace resources. Terraform
1.10 or later is required for native S3 state locking. If the default
`terraform` command is older or missing, the script downloads HashiCorp
Terraform 1.10.5 and verifies its SHA-256 checksum before using it. Set
`TERRAFORM_BIN` to use a specific executable; an unsupported explicit version
fails with an error.

## tf-apply.sh

Wrapper script for `terraform apply` that fetches sensitive variables from OpenBao instead of reading them from a local plaintext tfvars file.

### Prerequisites

- rs-manager OpenBao token with read access to `secret/rs-manager/rackspace-spot-terraform/*`
- `bao` CLI in PATH (available on ex44 and lab servers)

### Secret layout

The rs-manager OpenBao instance owns the `secret/rs-manager/*` prefix, so the
terraform credentials live under it like every other rs-manager-hosted secret:

| Path | Key | What |
|---|---|---|
| `secret/rs-manager/rackspace-spot-terraform/credentials` | `token` | Org-level Rackspace Spot refresh token — shared by every cloudspace this module manages (`rackspace_spot_token` is still read as a fallback) |
| | `token-name` | Console name of that token, for self-description; not read by the scripts |
| | `tailscale_oauth_client_id` / `tailscale_oauth_client_secret` | Tailscale operator OAuth client |
| | `github_token` | Read access for the ArgoCD bootstrap |

Set `TF_SECRET_PATH` to point both scripts at a different path (e.g. a
per-cloudspace credential set). Rotate a single key with `bao kv patch`, not
`put`, so the other keys survive:

```bash
# paste the new value on stdin, then Ctrl-D — never as an argument
bao kv patch secret/rs-manager/rackspace-spot-terraform/credentials token=-
```

Prior location (until 2026-08-29): `secret/rackspace-spot-terraform/rs-manager` —
no instance prefix, and the trailing `rs-manager` was the cloudspace name, which
read as if the secret were per-cluster. It is not; the Spot token is per org.

### Usage

```bash
# Read your OpenBao token without echoing it or putting it in command history.
read -r -s -p 'OpenBao token: ' BAO_TOKEN
printf '\n'
export BAO_TOKEN

# Run terraform apply (secrets are fetched automatically from OpenBao)
./scripts/tf-apply.sh apply

# Run terraform plan
./scripts/tf-apply.sh plan

# Pass additional terraform arguments
./scripts/tf-apply.sh apply -auto-approve
```

### How it works

1. Fetches secrets from OpenBao at `secret/rs-manager/rackspace-spot-terraform/credentials`
2. Exports them as `TF_VAR_*` environment variables:
   - `TF_VAR_rackspace_spot_token`
   - `TF_VAR_tailscale_oauth_client_id`
   - `TF_VAR_tailscale_oauth_client_secret`
   - `TF_VAR_github_token`
3. Invokes terraform with all passed arguments

### Error handling

The script will fail if:
- `BAO_TOKEN` is not set
- OpenBao is unreachable at `http://traefik-rs-manager:8200`
- Any required secret is missing from OpenBao

## tf-cluster.sh

Use this wrapper for independent Terraform roots under `clusters/`. It checks
that `clusters/<name>/backend.tf` selects `state/<name>/terraform.tfstate`,
runs backend initialization before loading provider credentials, and then
delegates plans and applies to `tf-apply.sh`.

```bash
# Backend credentials must be available as AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY, or through the configured AWS profile.

# Initialize only the backend; this does not fetch provider secrets.
./scripts/tf-cluster.sh ord-devimprint init

# Read the OpenBao token without echoing it or putting it in command history.
read -r -s -p 'OpenBao token: ' BAO_TOKEN
printf '\n'
export BAO_TOKEN

# Plan and apply with OpenBao credentials loaded automatically.
./scripts/tf-cluster.sh ord-devimprint plan
./scripts/tf-cluster.sh ord-devimprint apply

# Non-sensitive variable overrides may be provided with Terraform options.
./scripts/tf-cluster.sh ord-devimprint plan -var=node_count=8
```

Plan and apply always use `-input=false` and `-lock-timeout=5m`. Apply keeps
Terraform's interactive approval prompt. The wrapper rejects automatic
approval, disabled locking, custom lock timeouts, saved or JSON plan output,
saved-plan application, alternate local state paths, variable files, and
credential variables passed with `-var`. Set non-sensitive overrides through
`TF_VAR_*` or `-var`; credentials must come from OpenBao. The OpenBao token is
removed from the environment before
Terraform runs, and the wrapper does not print Terraform arguments. Terraform
state still contains sensitive values and must be protected like the source
credentials. The wrapper uses the root's `.terraform.lock.hcl` in read-only
mode, selects the default workspace, and ignores ambient Terraform CLI override
and debug-logging environment variables.

The wrapper never migrates local state. If a cluster has existing local state,
use the review and backup procedure in `docs/terraform-state.md`; do not accept
an unexpected backend migration prompt. That document's Garage compatibility
blocker applies to cluster operations too.

## seed-openbao.sh

One-time migration script to move secrets from `rs-manager.tfvars` (plaintext, gitignored) into OpenBao.

### Usage

```bash
# Read your OpenBao token without echoing it or putting it in command history.
read -r -s -p 'OpenBao token: ' BAO_TOKEN
printf '\n'
export BAO_TOKEN

# Run the seed script
./scripts/seed-openbao.sh
```

### What it does

1. Attempts to read existing values from `rs-manager.tfvars` (if present)
2. Prompts for any missing values interactively
3. Writes all secrets to OpenBao at `secret/rs-manager/rackspace-spot-terraform/credentials`
   via a mode-600 `@file` payload (values never appear in argv)
4. Verifies the write by metadata (version + timestamp) — it never prints the values back

### After seeding

1. Test the apply wrapper: `./scripts/tf-apply.sh plan`
2. Delete the local tfvars file: `rm rs-manager.tfvars`
3. Use `tf-apply.sh` for all future terraform operations

### Why use OpenBao?

**Before (single point of failure):**
- Secrets lived only in `rs-manager.tfvars` on one server
- No backup if that disk is lost
- Risk of accidental git commit (despite .gitignore)

**After (OpenBao):**
- Secrets stored centrally in OpenBao (already backed up)
- Same pattern used across all clusters in the fleet
- Access controlled via token-based authentication
- Version history (KV v2) for audit/rollback

See: docs/plan/plan.md (ADR-001 section, follow-up bead rackspac-a5e92e82)
