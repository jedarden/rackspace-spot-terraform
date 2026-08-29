# Terraform Scripts

This directory contains wrapper scripts for managing Terraform operations with OpenBao secret integration.

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
| `secret/rs-manager/rackspace-spot-terraform/credentials` | `rackspace_spot_token` | Org-level Rackspace Spot refresh token — shared by every cloudspace this module manages |
| | `tailscale_oauth_client_id` / `tailscale_oauth_client_secret` | Tailscale operator OAuth client |
| | `github_token` | Read access for the ArgoCD bootstrap |

Set `TF_SECRET_PATH` to point both scripts at a different path (e.g. a
per-cloudspace credential set). Rotate a single key with `bao kv patch`, not
`put`, so the other keys survive:

```bash
# paste the new value on stdin, then Ctrl-D — never as an argument
bao kv patch secret/rs-manager/rackspace-spot-terraform/credentials rackspace_spot_token=-
```

Prior location (until 2026-08-29): `secret/rackspace-spot-terraform/rs-manager` —
no instance prefix, and the trailing `rs-manager` was the cloudspace name, which
read as if the secret were per-cluster. It is not; the Spot token is per org.

### Usage

```bash
# Set your OpenBao token
export BAO_TOKEN=hvs.your-token-here

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

## seed-openbao.sh

One-time migration script to move secrets from `rs-manager.tfvars` (plaintext, gitignored) into OpenBao.

### Usage

```bash
# Set your OpenBao token
export BAO_TOKEN=hvs.your-token-here

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
