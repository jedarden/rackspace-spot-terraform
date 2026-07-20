# rackspace-spot-terraform — Plan

This file is being created 2026-07-20 during a fleet-wide deployed-artifact
improvement review, following this workspace's standard repo layout
(`docs/plan/plan.md` as the single living plan doc). This repo predates that
convention and has operated via commit history + the root `CLAUDE.md`
(networking rules) alone — this is not a retroactive rewrite of that history,
just an honest starting point: a short description of what the repo actually
does today, followed by the first ADR.

## What this repo ships

`rackspace-spot-terraform` is a Terraform module (not a running service) that:

- Provisions Rackspace Spot cloudspaces/nodepools (`cloudspace.tf`,
  `nodepools.tf`, `naming.tf`) via the `rackerlabs/spot` provider.
- Bootstraps a freshly-created cloudspace with the baseline platform stack
  (`bootstrap.tf`, via `local-exec` + `helm`): Tailscale operator → Liqo →
  Traefik → cert-manager → ArgoCD → an App-of-Apps `Application` pointed at
  `jedarden/declarative-config`, which then owns everything after that.
- Is run by hand (`terraform apply`) from a checkout on ex44 or the lab
  server — there is no CI/CD automation applying it. This is deliberate: an
  earlier in-cluster automation approach (tofu-controller on rs-manager +
  the Galleybytes terraform-operator on ardenone-hub) was removed
  2026-04-22 after it leaked ~48 zombie `spot_spotnodepool` objects because
  no state backend was ever wired up. Manual, one-cluster-at-a-time applies
  from this repo replaced it and remain the intended workflow.

The root module (`terraform.tfstate` at repo root) currently manages the
**rs-manager** cloudspace itself — the management cluster that runs ArgoCD
for the rest of the Spot fleet. `clusters/<name>/` holds per-cluster
submodules that manage a nodepool against an already-existing cloudspace
(currently `clusters/iad-devimprint/`).

`tftask/` is a container image (Dockerfile + a small C++ entrypoint) built
for the retired Galleybytes terraform-operator runner — it predates the
2026-04-22 retirement and is not consumed by anything in the current
manual-apply workflow.

## ADR-001: 2026-07-20 — Remote Terraform state backend with locking

### Context

- `terraform.tfstate` / `terraform.tfstate.backup` at the repo root are
  local-only files (excluded from git by `.gitignore`) and, as of this
  review, exist in exactly **one place**: this ex44 checkout. The lab
  server (`100.81.129.38`) does not even have this repo cloned. That one
  file (serial 19, 11 resources) is the entire record of how the
  **rs-manager** cloudspace — the cluster that runs ArgoCD for every other
  Spot cluster in the fleet — was provisioned and bootstrapped.
- `clusters/iad-devimprint/main.tf` is tracked in git but has **no**
  matching local state file anywhere found during this review. Combined
  with the 2026-07-11 correction on file (the `iad-devimprint` cloudspace
  was being replaced by `ord-devimprint` in Chicago) this submodule may
  already be stale config for a cloudspace that no longer matches
  production — exactly the kind of drift that local, unsynced state makes
  invisible until someone runs `apply` against it.
- This is not a hypothetical risk: this workspace already hit this exact
  failure mode once, in a different implementation. The retired
  tofu-controller/Galleybytes automation leaked ~48 zombie
  `spot_spotnodepool` objects over 41 hours specifically because "no state
  backend was ever wired up" (removed 2026-04-22, three commits on
  `jedarden/declarative-config`). This repo replaced that automation but
  kept the same underlying weakness — a single local state file with no
  locking — just running by hand instead of via a controller, which has
  hidden the risk rather than removed it.
- No locking also means two concurrent `terraform apply` runs (e.g. from
  ex44 and lab, or a human and a NEEDLE-dispatched agent) against the same
  state could corrupt it or issue conflicting calls to the Rackspace Spot
  API. The cloudspace resource's admission webhook rejects most
  post-creation changes (noted in `clusters/iad-devimprint/main.tf`), so
  state loss or corruption for a live cloudspace is not cleanly
  recoverable by re-importing.

### Decision

Migrate this repo's Terraform state to a remote `s3` backend pointed at a
Garage bucket, using Terraform's native S3 state locking
(`use_lockfile = true`, Terraform >= 1.10 — no DynamoDB table needed).

- Host the bucket on an already-stable, independently-provisioned cluster's
  Garage instance (e.g. ardenone-manager) — explicitly **not** on
  rs-manager itself, so that losing the rs-manager cloudspace doesn't also
  destroy the only record of how to reconstruct it.
- Give the root module and each `clusters/<name>/` submodule its own state
  key in the same bucket (e.g. `state/root/terraform.tfstate`,
  `state/iad-devimprint/terraform.tfstate`) so a bad apply against one
  cluster cannot corrupt another's state.
- Enable bucket versioning so a bad apply can be rolled back to the prior
  state serial.
- Out of scope: this ADR only moves *where state lives*, not *how applies
  happen*. Manual, one-cluster-at-a-time `terraform apply` remains the
  process, per the lesson from the 2026-04-22 retirement.

### Alternatives Considered

1. **Commit `terraform.tfstate` to git instead.** Rejected — state can
   contain sensitive computed values (e.g. the `kubeconfig` data source
   output), and git provides no locking, so the concurrent-apply corruption
   risk remains.
2. **Terraform Cloud / HCP free tier.** Rejected — adds an external SaaS
   dependency for infrastructure whose whole point is to run inside an
   already self-hosted, Tailscale-only environment (Forgejo-primary,
   self-hosted-first is the norm elsewhere in this workspace).
3. **Host the bucket on rs-manager's own Garage instance** (already running
   there). Rejected as the primary target — circular dependency: if the
   rs-manager cloudspace is lost, the compute *and* the only copy of the
   state needed to rebuild it disappear together, which defeats the
   purpose. It may still be worth a secondary/DR copy later.
4. **Reintroduce a Kubernetes Terraform operator with built-in state
   management** (tofu-controller / Galleybytes) instead of manual applies.
   Rejected — this is the exact approach retired 2026-04-22 after producing
   48 zombie objects, and is against the explicit standing direction not to
   reintroduce automated Terraform provisioning.
5. **Do nothing.** Rejected — the failure mode has already occurred once in
   this workspace under a different implementation of the same root cause,
   and this review found the risk is not hypothetical: `clusters/
   iad-devimprint` already has no matching local state on the only machine
   that has ever run `apply` against it.

### Consequences

- rs-manager's and each cluster's state survive an ex44 disk loss;
  concurrent applies from ex44 and lab become safe (locked) instead of
  silently risky.
- Removes the "which checkout has the real state" ambiguity that already
  exists today for `clusters/iad-devimprint` (see Context).
- One-time migration risk: `terraform init -migrate-state` must be run
  carefully against the live rs-manager state. Mitigate by pre-creating
  the bucket with versioning on, and keeping the existing
  `terraform.tfstate.backup` as an out-of-band copy until the migration is
  verified against a `terraform plan` (expect no diff).
- Adds a runtime dependency on the Garage bucket being reachable over
  Tailscale at apply time — acceptable, since `plan`/`apply` already
  require reaching the Rackspace Spot API and, during bootstrap, the
  target cluster's own API server; this doesn't add a new class of
  dependency, just one more host.
- Follow-up work identified during this review but intentionally kept out
  of this ADR (filed as beads instead): reconcile the
  `iad-devimprint`/`ord-devimprint` drift, move `rs-manager.tfvars`
  secrets out of a local plaintext file into OpenBao, and commit
  `.terraform.lock.hcl`.
