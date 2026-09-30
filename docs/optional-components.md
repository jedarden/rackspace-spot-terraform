# Optional bootstrap components

The four component skip variables are independent switches for a new
cloudspace. A `true` value sets the corresponding Terraform `null_resource`
count to zero, so Terraform plans no local-exec installation for that
component and no resource address is created for it.

## Dependency and expected state

Bootstrap is ordered as follows:

```text
cloudspace -> worker pool -> kubeconfig file -> install_tools -> Tailscale
                                                    |             |
                                                    |             +-> Liqo -> Liqo peering
                                                    +-> Traefik ---+
                                                    +-> cert-manager -+-> ArgoCD -> App-of-Apps
```

The skip switches affect the graph this way:

| Variable | Resources omitted when `true` | Resources that still run |
| --- | --- | --- |
| `skip_liqo` | `null_resource.liqo`, `null_resource.liqo_peer` | tools, Tailscale, Traefik, cert-manager, ArgoCD, and App-of-Apps |
| `skip_traefik` | `null_resource.traefik` | tools, Tailscale, Liqo, Liqo peering, cert-manager, ArgoCD, and App-of-Apps |
| `skip_cert_manager` | `null_resource.cert_manager` | tools, Tailscale, Liqo, Liqo peering, Traefik, ArgoCD, and App-of-Apps |
| `skip_argocd` | `null_resource.argocd`, `null_resource.app_of_apps` | tools, Tailscale, Liqo, Liqo peering, Traefik, and cert-manager |

All sixteen combinations of these four boolean switches are valid Terraform
configurations. The choice should still match the workloads intended for the
cluster:

- Set `skip_liqo = true` for a standalone cluster that must not federate with
  ardenone-hub.
- Set `skip_traefik = true` when this cluster does not need the module's
  ingress controller. Set `skip_cert_manager = true` when certificate
  automation is not needed. They are commonly set together, but neither
  requires the other.
- Set `skip_argocd = true` when GitOps is managed elsewhere. This also skips
  the App-of-Apps resource, because it requires an ArgoCD namespace and API.
- Set all four to `true` for a cluster that only needs the core bootstrap
  (tools and Tailscale). The cloudspace, worker pool, and kubeconfig file are
  still created.

`skip_bootstrap = true` is broader than the four component switches: it omits
all bootstrap `null_resource` instances, including tools and Tailscale. It is
the appropriate setting when the cluster is already bootstrapped or bootstrap
permissions are intentionally unavailable.

## Reruns and changing a switch

- Re-running with the same skip values keeps skipped component resources
  absent. Existing enabled components use their existing Terraform triggers,
  so they are not reinstalled solely because Terraform was run again. The
  tools resource intentionally has a timestamp trigger because its binaries
  live in `/tmp`.
- Changing a switch from `true` to `false` adds the component resource and runs
  its installation on the next apply. For ArgoCD, the App-of-Apps resource is
  added with it.
- Changing a switch from `false` to `true` removes the corresponding
  `null_resource` from Terraform state, but does not uninstall an already
  installed Helm release: these resources have no destroy provisioner. Treat
  the switch as an installation/ownership decision, not as a cleanup command.
  If the switch is later changed back to `false`, Terraform recreates the
  resource and its `helm upgrade --install` command safely reconciles the
  release.
- `skip_liqo` removes both the Liqo install resource and peering resource. If
  peering was enabled previously, removing `null_resource.liqo_peer` runs its
  destroy provisioner and attempts `liqoctl unpeer`. The Liqo Helm release
  remains installed because its resource has no uninstall destroy action.
  The teardown needs the selected hub kubeconfig, Spot kubeconfig, and
  `liqoctl` on the Terraform runner. See
  [the Liqo and Tailscale contract](liqo-tailscale-contract.md) for context
  selection, permissions, and retry behavior.
