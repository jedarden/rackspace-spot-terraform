# Liqo and Tailscale integration contract

This module gives a Spot cluster tailnet connectivity and, unless
`skip_liqo = true`, peers it with `ardenone-hub` so the hub can consume compute
resources from the Spot cluster. Liqo is configured as a one-way relationship:
the hub is the consumer and the Spot cluster is the provider.

## How the hub is selected

There is no lookup by cluster name, Tailscale DNS name, or inventory record.
Terraform runs `liqoctl` on the machine executing `terraform apply`. The
peering script selects the hub's Kubernetes context in this order:

1. `HUB_KUBECONFIG`, when set in the Terraform runner's environment.
2. `/etc/rancher/k3s/k3s.yaml`, when that file exists on the runner.
3. The runner's normal `kubectl`/`liqoctl` context, usually
   `$HOME/.kube/config` and its current context.

The script first uses the Spot kubeconfig at
`/tmp/<cloudspace-name>.kubeconfig` to check Liqo readiness. It then switches to
the selected hub context and passes the Spot kubeconfig to `liqoctl` as
`--remote-kubeconfig`. The selected local context must therefore be
`ardenone-hub`; if it points at another cluster, peering and recovery actions
will target that cluster. Set `HUB_KUBECONFIG` explicitly when the runner has
multiple kubeconfigs.

For the WireGuard gateway, Liqo creates a `NodePort` service on the Spot
provider. The hub reaches the endpoint Liqo advertises from the Spot node IP
and NodePort over UDP. The `tailscale.com/expose` and `tailscale.com/hostname`
annotations on that service request a tailnet service for the named gateway;
they do not select or locate `ardenone-hub` for `liqoctl`.

## Tailscale registration

Bootstrap creates the `tailscale` namespace and an `operator-oauth` Secret
from `tailscale_oauth_client_id` and `tailscale_oauth_client_secret`, then
installs the pinned Tailscale Kubernetes Operator chart. The operator device
uses the cloudspace name as its hostname and `tag:k8s-operator`; operator-
managed proxy devices use `tag:k8s` and `tag:spot`.

Create a Tailscale OAuth client with **Read and Write** access for **Devices:
Core**, **Auth Keys**, and **Services**, and allow it to use
`tag:k8s-operator`. The
tailnet policy must allow administrators to assign `tag:k8s-operator`, and the
operator tag must own both proxy tags. For example, merge these entries into
the existing `tagOwners` policy:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:spot": ["tag:k8s-operator"]
  }
}
```

Store the OAuth ID and secret in OpenBao at
`secret/rs-manager/rackspace-spot-terraform/credentials` under
`tailscale_oauth_client_id` and `tailscale_oauth_client_secret`. The runner
needs read access to that secret when using `scripts/tf-apply.sh`. The OAuth
client secret is also stored in the Kubernetes Secret and Terraform state;
protect access to both.

Successful Helm installation and operator Deployment readiness confirm that
the operator can start. To confirm tailnet registration itself, check the
Tailscale admin console's Machines page for the operator device named after
the cloudspace and tagged `tag:k8s-operator`.

## Spot and hub permissions

- The runner needs Rackspace Spot organization-token permission to create the
  cloudspace and node pool. That same Spot API token is shared by all
  cloudspaces managed by this module.
- The Spot kubeconfig must allow cluster bootstrap: namespaces and Secrets,
  Helm-managed CRDs, service accounts, roles, deployments, and Liqo resources.
  Treat it as a cluster-admin credential and keep it private.
- The hub kubeconfig must allow Liqo peering and unpeering, access to Liqo
  cluster-ID configmaps, deletion of the matching `liqo-tenant-*` namespace,
  and restart/status checks for the hub's `liqo-controller-manager` and
  `liqo-crd-replicator` Deployments. The recovery path also lists and removes
  stale `liqo-tenant-*` namespaces on the Spot cluster. Use a dedicated
  hub-side identity with only the permissions these operations need where
  practical; the current automation expects these actions to be authorized.
- The Terraform runner also needs network access to both Kubernetes APIs,
  the Tailscale and Liqo Helm repositories, and the Liqo gateway endpoint.

## Compute cluster distinction and `skip_liqo`

There is no separate `compute_cluster` flag. `skip_liqo = false` (the default)
installs Liqo and makes the Spot cluster a provider for hub workloads. Set
`skip_liqo = true` for management or standalone clusters, as in
`rs-manager.tfvars.example`; Tailscale, Traefik, cert-manager, and ArgoCD are
independent of that choice. Tailscale's `tag:spot` labels operator-managed
proxy devices and is not itself the Liqo compute-role switch.

When true, `skip_liqo` omits both the Liqo Helm install resource and the Liqo
peering resource. If an existing peering resource is removed by changing the
switch from false to true, Terraform runs its destroy provisioner to issue
`liqoctl unpeer`. The Liqo Helm release is not uninstalled; the install
resource has no Helm uninstall destroy action. Re-enabling Liqo recreates the
resources and reconciles the chart and peering. The unpeer attempt requires
the hub context, the Spot kubeconfig, and `liqoctl` on the runner (in `PATH` or
`/tmp`). The unpeer command is idempotent from Terraform's perspective and
its error is tolerated during teardown.

`skip_bootstrap = true` is broader: it omits all bootstrap resources, including
Tailscale, Liqo, and peering. As with other `null_resource` destroy
provisioners, changing this switch removes Terraform resources; only the Liqo
peering resource has an explicit cleanup action.

## Failure, retry, and teardown

The peering script waits for the Spot Liqo controller and fabric. If they do
not become ready, or `liqoctl peer` fails, the provisioner returns a nonzero
status so Terraform reports the failure. It prints controller diagnostics and
does not claim that peering succeeded.

After correcting the underlying issue, rerun `terraform apply`. Each peering
attempt first tries to unpeer stale state, removes stale tenant namespaces,
restarts both hub controllers to refresh namespace UID caches, and retries
`liqoctl peer` with the Spot cluster as the remote provider. This is the
supported recovery path; the next apply repeats the cleanup sequence.

Destroying or disabling peering runs `liqoctl unpeer` from the selected hub
context with the Spot kubeconfig as the remote cluster. Removing this
relationship does not uninstall the Spot cluster's Liqo Helm release or
Tailscale operator.

## Smoke checks

Run `bash tests/integration-smoke.sh` from the repository root. It executes
the same bootstrap and peering scripts used by Terraform against stubbed
`kubectl`, `helm`, and `liqoctl` commands. It checks the Tailscale Secret and
registration settings, verifies that a failed peering attempt is reported,
that a subsequent attempt recovers after cleanup, and that teardown tolerates
an already-removed peering. It does not contact a real tailnet or Kubernetes
cluster.

For the upstream permission requirements, see Tailscale's [Kubernetes
Operator installation guide](https://tailscale.com/docs/kubernetes-operator/install-operator),
[tag customization guide](https://tailscale.com/docs/kubernetes-operator/reference/tags),
and Liqo's [`liqoctl peer` reference](https://docs.liqo.io/en/latest/usage/liqoctl/liqoctl_peer.html).
