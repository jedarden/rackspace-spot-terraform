# Terraform-Cluster Reconciliation: bf-1qt

**Date:** 2026-07-28

## Issue

`clusters/iad-devimprint/main.tf` referenced a cloudspace that no longer exists, creating drift between tracked configuration and live infrastructure.

## Investigation Findings

### Confirmed Facts

1. **iad-devimprint cloudspace does NOT exist**
   - Verified via `spotctl cloudspace list` on 2026-07-28
   - No cloudspace with name "iad-devimprint" found in apexalgo org

2. **ord-devimprint cloudspace exists and is healthy**
   - Region: us-central-ord-1 (Chicago)
   - Created: 2026-04-22T14:21:47Z
   - Status: Ready
   - 6 worker nodes (ch.vs1.medium-ord)
   - SpotNodepool: desired=6, fulfilled=6, bidPrice=$0.001
   - Kubernetes v1.33.0

3. **No local Terraform state for iad-devimprint**
   - Searched entire /home/coding directory tree
   - No `*iad-devimprint*.tfstate` files found
   - The old config had no matching state file

### Conclusion

The iad-devimprint cloudspace was destroyed (outside of Terraform) and replaced by ord-devimprint in the Chicago region. The tracked configuration was stale, dead weight with no associated state.

## Actions Taken

1. **Deleted stale configuration**
   - Removed `clusters/iad-devimprint/` directory entirely
   - No state cleanup required (none existed)

2. **Created ord-devimprint configuration**
   - Created `clusters/ord-devimprint/main.tf`
   - Configured to match live cluster:
     - `cloudspace_name = "ord-devimprint"`
     - `server_class = "ch.vs1.medium-ord"` (2 CPU, 3.75GB, $0.001/hr)
     - `node_count = 6` (matches live cluster)
     - `bid_price = 0.001` (matches live nodepool)

## Related Documentation

This drift was cited in ADR-001 (docs/plan/plan.md) as evidence for why local, unsynced Terraform state is risky and motivates the planned migration to a remote S3 backend with locking.

## Next Steps

- The new `clusters/ord-devimprint/main.tf` will need to be initialized with `terraform init` before it can be applied
- Since ord-devimprint already exists, apply would only affect the nodepool (consistent with the module's design)
