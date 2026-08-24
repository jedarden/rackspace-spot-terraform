# Terraform State Migration Status

## ADR-001: Remote State Backend Migration

**Status**: Partially Complete - Backend Configured, Migration Blocked

### Completed Work

- ✅ **Backend configuration added** (commit 6350388, 2026-08-21)
  - `backend.tf` created with S3 backend pointing to Garage
  - `clusters/ord-devimprint/backend.tf` configured for cluster-specific state
  - Both use `use_lockfile = true` for native Terraform locking (requires 1.10+)

- ✅ **Endpoint corrected** (commit 2e537d2, 2026-08-21)
  - Fixed from HTTPS VIP to direct Tailscale HTTP endpoint
  - Endpoint: `http://garage-ardenone-cluster.tail1b1987.ts.net:3900`
  - Uses path-style addressing required by Garage

- ✅ **Documentation added** (commit 6350388)
  - `docs/terraform-state.md` with migration commands
  - ADR-001 documented in `docs/plan/plan.md`

- ✅ **Style cleanup** (commit 6b8489e, 2026-08-24)
  - Normalized comment spacing in bootstrap and peering modules

### Remaining Prerequisites

The migration cannot proceed until these are resolved:

#### 1. Terraform Version Upgrade
- **Current**: v1.9.8 (installed on system)
- **Required**: ≥ 1.10 for `use_lockfile = true` support
- **Action**: Upgrade Terraform to 1.10+ (latest: 1.15.9)
- **Impact**: Native state locking will not work without this

#### 2. Garage Bucket Creation
- **Required**: `terraform-state` bucket on Garage cluster
- **Settings**: Versioning enabled
- **Permissions**: Dedicated Garage key with:
  - `ListBucket`-equivalent for state prefixes
  - `GetObject`/`PutObject` for state objects
  - `GetObject`/`PutObject`/`DeleteObject` for `.tflock` objects
- **Scope**: Both `state/root/` and `state/ord-devimprint/`

#### 3. AWS/Garage Credentials
- **Required**: Environment variables or AWS profile
  ```
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  ```
- **Storage**: Use OpenBao (not in repository)
- **Current status**: No credentials configured in environment
- **Note**: These are Garage S3 credentials, not AWS credentials

#### 4. Garage Compatibility Verification
- **Blocker**: Garage v2.2.0 does not implement:
  - S3 bucket versioning
  - Conditional `PutObject` operations
- **Impact**: Cannot provide rollback and lock guarantees required by ADR-001
- **Action Required**:
  1. Verify Garage cluster version on `ardenone-cluster`
  2. Upgrade to Garage version that supports versioning/conditional writes, OR
  3. Revise ADR-001 to select a different backend with these capabilities

### Migration Commands (DO NOT RUN until prerequisites met)

Once all prerequisites are satisfied:

```bash
# Root module (rs-manager)
terraform init -input=false -migrate-state
terraform plan -input=false -detailed-exitcode

# Cluster module (ord-devimprint)
terraform -chdir=clusters/ord-devimprint init -input=false -migrate-state
terraform -chdir=clusters/ord-devimprint plan -input=false -detailed-exitcode
```

### Current State Files

- **Local state**: `terraform.tfstate` (last modified 2026-04-15)
- **Backup**: `terraform.tfstate.backup` (2026-04-15)
- **Warning**: These are the only copies of rs-manager state
- **Post-migration**: Keep backups until remote state is verified

### Risk Assessment

- **State loss risk**: HIGH - local state files exist in only one location
- **Concurrent apply risk**: MEDIUM - no locking until migration completes
- **Migration risk**: MEDIUM - requires careful execution and verification

### Next Actions (Priority Order)

1. **Verify Garage version** on `ardenone-cluster` and document compatibility status
2. **Create terraform-state bucket** with required permissions (if compatible)
3. **Configure credentials** in OpenBao and set up environment
4. **Upgrade Terraform** to 1.10+ on all systems that run `terraform apply`
5. **Perform migration** using documented commands
6. **Verify** with `terraform plan` expecting exit code 0 (no diff)

### References

- ADR-001: `docs/plan/plan.md#adr-001`
- Migration docs: `docs/terraform-state.md`
- Backend config: `backend.tf`, `clusters/ord-devimprint/backend.tf`

**Last Updated**: 2026-08-24
