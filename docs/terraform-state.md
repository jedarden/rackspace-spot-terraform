# Remote Terraform state

This repository follows [ADR-001](plan/plan.md#adr-001-2026-07-20--remote-terraform-state-backend-with-locking).
Both configurations are prepared to use the same versioned S3-compatible
bucket, with an isolated state object for each Terraform root:

> Compatibility blocker: the live Garage endpoint currently runs Garage
> v2.2.0. Garage does not implement S3 bucket versioning or conditional
> `PutObject`, so it cannot currently provide both the rollback and native
> lock guarantees required by ADR-001. Do not run the migration commands below
> until the endpoint is upgraded to a compatible implementation and its
> versioning/conditional-write behavior is verified, or the ADR is revised to
> select a backend that supports those operations.

| Configuration | State object |
| --- | --- |
| Repository root (rs-manager) | `state/root/terraform.tfstate` |
| `clusters/ord-devimprint` | `state/ord-devimprint/terraform.tfstate` |

The backend also uses the sibling `<state object>.tflock` object for native
Terraform locking. The Garage endpoint is reached through the independent
cluster's Tailscale-only ingress, and path-style addressing is required by
Garage.

## Backend prerequisites

Before initializing either configuration, the platform operator must create
the `terraform-state` bucket on the independently-provisioned Garage cluster
(not `rs-manager`) with:

- bucket versioning enabled;
- a dedicated Garage key with `ListBucket`-equivalent access for the state
  prefixes, `GetObject`/`PutObject` for state objects, and
  `GetObject`/`PutObject`/`DeleteObject` for the matching `.tflock` objects;
- access to both `state/root/` and `state/ord-devimprint/`.

The bucket is intentionally not managed by these Terraform configurations: a
backend must already exist before Terraform can initialize and migrate state.
Once the compatibility blocker is resolved, manage the bucket and key through
the stable cluster's Garage operator/GitOps configuration. The current
operator schema cannot express the required versioning setting.

Terraform backend credentials are not stored in this repository. Load the
dedicated Garage key through the approved secret store into the conventional
AWS environment variables (or an AWS credentials profile) before `terraform
init`:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

Do not pass these values with `-backend-config` or put them in a committed
`.tfbackend` file; Terraform persists backend configuration locally under
`.terraform/`.

## One-time migration

Use Terraform 1.10 or newer. Keep an out-of-band copy of each existing local
`terraform.tfstate` and `terraform.tfstate.backup` before migration; state can
contain sensitive values.

From the repository root, after the bucket, compatible endpoint, and
credentials are ready:

```bash
terraform init -input=false -migrate-state
terraform plan -input=false -detailed-exitcode
```

The plan should return exit code `0` (no changes). Exit code `2` means the
configuration differs from the migrated state and must be investigated before
applying. Keep the out-of-band backup until a subsequent remote-backed plan
has also completed successfully.

Initialize the cluster configuration separately:

```bash
terraform -chdir=clusters/ord-devimprint init -input=false -migrate-state
terraform -chdir=clusters/ord-devimprint plan -input=false -detailed-exitcode
```

After initialization, use `-lock-timeout=5m` for normal plans and applies so a
briefly-held lock is retried rather than treated as an immediate failure. The
existing `scripts/tf-apply.sh` wrapper can continue to be used for root-module
operations once the backend has been initialized.
