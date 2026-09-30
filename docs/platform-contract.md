# Baseline platform contract

The module establishes a small set of cluster-wide networking and TLS
prerequisites when bootstrap is enabled. Terraform plan tests check the Spot
cloudspace CNI and the Helm installation settings without connecting to or
changing a live cluster.

## Calico CNI

Every cloudspace created by this module sets `cni = "calico"`. The Spot
provider provisions the cluster network with Calico; applications do not
choose or install the cluster CNI.

## Traefik exposure

When `skip_traefik` is false, bootstrap installs the Traefik Helm chart and
sets its Service type explicitly to `ClusterIP`. The Traefik Service therefore
does not request a Rackspace cloud LoadBalancer. The websecure entry point is
exposed by the chart for in-cluster Service traffic. External access must use
the cluster's approved routing path, such as Tailscale or Cloudflare Tunnel,
and must not change Traefik's Service to `LoadBalancer`.

## cert-manager and TLS

When `skip_cert_manager` is false, bootstrap installs the cert-manager Helm
chart in the `cert-manager` namespace with its CRDs enabled. This makes the
cert-manager controller and Kubernetes `Issuer`, `ClusterIssuer`, and
`Certificate` APIs available for workload TLS configuration.

The module does not create an issuer, request a certificate, or create a TLS
Secret by itself. Workloads or GitOps configuration must define the appropriate
issuer and `Certificate` resources. Traefik and cert-manager are independently
optional; skipping Traefik does not skip cert-manager, and vice versa.

## Skip settings and dependency behavior

`skip_liqo` removes both the Liqo installation and peer resources. The
`skip_traefik` and `skip_cert_manager` flags each remove only their respective
install resource. ArgoCD may remain enabled when either or both are skipped;
its Terraform dependencies on those zero-count resources are valid. Setting
`skip_argocd` removes ArgoCD and its dependent App-of-Apps resource. These
settings change Terraform ownership and installation planning; they do not
uninstall existing Helm releases. See [Optional bootstrap components](optional-components.md)
for the full resource matrix and rerun behavior.

`tests/platform_contract.tftest.hcl` checks the Calico, Traefik, and
cert-manager installation contracts. `tests/skip_components.tftest.hcl` plans
representative individual and combined skip settings to check resource counts
and dependency validity. These are plan tests with mocked Spot resources; they
do not verify a live cluster or certificate issuance against an external CA.
