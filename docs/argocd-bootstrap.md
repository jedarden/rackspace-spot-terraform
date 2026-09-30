# ArgoCD App-of-Apps bootstrap

Terraform installs ArgoCD, registers the declarative-config Git repository,
then creates one `Application` named `applications-<cloudspace-name>` in the
`argocd` namespace. For the default `rs-manager` cloudspace, its name is
`applications-rs-manager`.

## Application source and authentication

| Setting | Value |
| --- | --- |
| Repository URL | `https://github.com/jedarden/declarative-config` (the read-only GitHub mirror; commit changes to Forgejo) |
| Revision | `main` |
| Path | `k8s/<declarative_config_path>`; defaults to `k8s/rs-manager` |
| Directory selection | Top-level `*-application.yml` files only (`recurse: false`) |
| ArgoCD project | `default` |
| Destination | The in-cluster Kubernetes API, namespace `argocd` |

ArgoCD authenticates with the repository Secret `declarative-config-repo` in
namespace `argocd`. Terraform creates it with username `jedarden` and the
`github_token` input as the password. The token must have read access to
`jedarden/declarative-config`; use a token with repository contents read
permission. The `tf-apply.sh` wrapper reads the value from
`secret/rs-manager/rackspace-spot-terraform/credentials`, key `github_token`,
and supplies it as `TF_VAR_github_token`. Never put the token in this document,
Terraform output, or command history. See `scripts/README.md` for secret
handling.

Forgejo (`git.ardenone.com`) remains the source of truth. Push changes there;
the server-side mirror updates GitHub. Do not push directly to the GitHub
mirror.

## Sync and readiness

The Application enables automated sync, pruning, and self-healing, and sets
`CreateNamespace=true`. Terraform's Helm `--wait` only waits for the ArgoCD
chart; it does not wait for this Application to finish syncing its child
Applications.

Bootstrap is ready when the Application exists with the source and sync policy
above, has no ArgoCD comparison, sync, invalid-spec, or unknown-error
conditions, reports `Synced`, and reports health `Healthy`.

After Terraform apply, run the read-only smoke check with a kubeconfig/context
for the new cluster and `kubectl` and `jq` installed:

```bash
./scripts/check-argocd-bootstrap.sh rs-manager
```

For a different cloudspace or `declarative_config_path`, pass both values:

```bash
./scripts/check-argocd-bootstrap.sh <cloudspace-name> <declarative-config-path>
```

On failure, the check prints the mismatched field or ArgoCD condition and a
next step. For further diagnosis, inspect the Application with
`kubectl -n argocd describe application applications-<cloudspace-name>` and
verify repository credentials and that `k8s/<declarative_config_path>` exists
on the `main` branch.
