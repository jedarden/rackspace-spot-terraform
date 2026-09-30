# Credential rotation and revocation

This runbook covers the Rackspace Spot organization token, the Tailscale
operator OAuth client, and the GitHub PAT used by ArgoCD. It keeps the new
credential in OpenBao before consumers are reapplied, proves the new value
works before retiring the old provider credential, and removes the superseded
OpenBao version after validation.

## Storage and consumers

All three credentials are fields in the same KV v2 secret, owned by the
rs-manager OpenBao instance:

| Credential | OpenBao key | Consumer |
| --- | --- | --- |
| Rackspace Spot organization refresh token | `token` | Spot provider in the root and `clusters/*` Terraform states |
| Tailscale OAuth client ID and secret | `tailscale_oauth_client_id`, `tailscale_oauth_client_secret` | `tailscale/operator-oauth` Secret and the Tailscale operator in the root Terraform state |
| GitHub PAT for `jedarden/declarative-config` | `github_token` | `argocd/declarative-config-repo` Secret in the root Terraform state |

The path is `secret/rs-manager/rackspace-spot-terraform/credentials`. The
Terraform wrappers read this path on each plan or apply. Do not put values in
tfvars, command arguments, plan files, logs, or notes. Terraform state is
sensitive; protect its access and do not print it. The trigger fingerprints
described below are SHA-256 digests, not raw credentials.

## Safe OpenBao update

Use the rs-manager provisioning identity because it can update this path
without reading its current values. Do not write to a replica. Its KV v2 mount
requires compare-and-set (CAS), so first capture the current version using
metadata only:

```bash
OPENBAO_KEY='rs-manager/rackspace-spot-terraform/credentials'
bao-as rs-manager-provision bao kv metadata get -mount=secret -format=json "$OPENBAO_KEY" \
  | jq -r '.data.current_version'
```

Save that version number as `CAS_VERSION`. For each field being changed, enter
the replacement without echo, pipe it to the write-only identity, then clear
the shell variable. Keep shell tracing off. The key names below are examples;
use the relevant key from the table above:

```bash
set +x
read -r -s -p 'New credential: ' NEW_CREDENTIAL
printf '\n'
printf '%s' "$NEW_CREDENTIAL" \
  | bao-as rs-manager-provision bao kv patch -mount=secret -method=patch \
      -cas="$CAS_VERSION" "$OPENBAO_KEY" token=-
unset NEW_CREDENTIAL
```

`-method=patch` prevents a read-and-rewrite fallback that the provisioning
identity is not allowed to perform. When rotating both Tailscale fields, write
each field with the latest CAS version and do not start Terraform between the
two writes. Read `current_version` again from metadata after each write. Verify
the final version and timestamp with `bao kv metadata get`; never read the
credential back to check a write.

During a normal rotation, leave the old provider credential valid until the
new one is stored and the consumer has passed its checks. Pause any overlapping
Terraform automation while updating a pair of Tailscale fields or applying the
root Terraform state.

## Rackspace Spot token

The token is organization-level and is used by every configured Spot Terraform
root. Create a replacement token with the same required organization access,
then update the OpenBao `token` key with the safe procedure above.

The token is consumed by the provider for API requests; it is not stored in
the cluster. Validate the replacement with the root state:

```bash
./scripts/tf-apply.sh plan
```

Review the plan and apply only reviewed infrastructure changes. A token
replacement alone does not require recreating a cloudspace or node pool; a
successful provider plan confirms that Terraform can authenticate with the
stored token. The `ord-devimprint` backend is under the compatibility hold in
[`terraform-state.md`](terraform-state.md). Do not run its cluster wrapper
while that hold remains. Once resolved, validate any changes in that state
with:

```bash
./scripts/tf-cluster.sh ord-devimprint plan
```

After the root plan succeeds (and any available active cluster plans succeed),
revoke the old token in the Rackspace Spot account and run the root plan again.
It must still succeed, proving Terraform is using the replacement. Run plans
for blocked cluster states after their backend is available; the
organization-level OpenBao token is already replaced for every wrapper.

## Tailscale OAuth client

Create a replacement OAuth client with the same operator permissions and tags.
Update `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` in
OpenBao before running Terraform. Their SHA-256 trigger fingerprints in
`null_resource.tailscale` make a changed value replace that resource. The
installer reapplies `operator-oauth`, upgrades the chart, explicitly restarts
the operator so it reloads the new secret, and waits for the rollout.

Plan and apply the root state interactively:

```bash
./scripts/tf-apply.sh plan
./scripts/tf-apply.sh apply
```

Confirm the plan replaces `null_resource.tailscale`, the operator deployment
rollout completes, and the operator reconnects and registers as online in the
Tailscale admin console. Check that operator logs do not show OAuth
authentication failures; never inspect the Secret value. Then revoke the old
OAuth client in Tailscale and run another plan. It must succeed without
replacing the Tailscale resource again, and the operator must remain online.

## GitHub PAT for ArgoCD

Create a replacement PAT with the same minimum read-only access to
`jedarden/declarative-config`. Update the OpenBao `github_token` key. Its
SHA-256 trigger fingerprint makes `null_resource.argocd` replace so the
`declarative-config-repo` Secret is reapplied.

Plan and apply the root state interactively:

```bash
./scripts/tf-apply.sh plan
./scripts/tf-apply.sh apply
```

Confirm the plan replaces `null_resource.argocd`, then check the ArgoCD
repository connection status reports successful and the managed Application
can refresh or sync. Do not print the repository Secret. Revoke the old PAT in
GitHub and repeat the plan and repository connection check; both must remain
successful with the replacement.

## Retirement, revocation, and recovery

For a planned rotation, revoke the old credential at its issuer only after the
new value is in OpenBao and the corresponding consumer has passed validation.
Then repeat its plan and validation after revocation. A successful
post-revocation check confirms that no consumer still relies on the old value.

If compromise is suspected, revoke the exposed credential at its issuer
immediately, create a replacement, update OpenBao, and reapply the dependent
resources as soon as possible. Expect an interruption until the replacement
is active. Do not restore a revoked value from Terraform state or OpenBao
history.

The latest OpenBao value replaces the active key, but KV v2 retains prior
versions. Record the pre-update version number. After the provider credential
is revoked and all dependent checks pass, an OpenBao operator using the human
OIDC role must permanently purge the specific old KV v2 version(s) that
contained the superseded value. Preserve the current version and any older
version required by another active rotation. The provisioning identity used
above cannot remove history. Verify cleanup with metadata only; do not inspect
secret values. Do not delete all metadata for the shared credentials path.

If Terraform or the consumer fails before old-token revocation, keep the old
provider credential active, correct the OpenBao value or Terraform issue, and
reapply. Do not purge the previous OpenBao version until the replacement is
validated. If the old credential has already been revoked, restore service
with a newly issued credential rather than restoring that revoked value.

The first apply after deploying credential fingerprints may replace the
Tailscale and ArgoCD bootstrap resources once because their prior Terraform
state has no fingerprint fields. Review this one-time plan before applying.
