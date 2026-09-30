# Rackspace Spot Terraform Module

Provisions disposable Kubernetes clusters on Rackspace Spot and peers them with ardenone-hub via Liqo.

Licensed under the Apache License, Version 2.0.

## What This Manages

This Terraform module creates and bootstraps Kubernetes clusters on Rackspace Spot infrastructure:

- **Cloudspace** (`spot_cloudspace`): Rackspace Spot Kubernetes cluster with Calico CNI
- **Node Pool** (`spot_spotnodepool`): Spot worker nodes with configurable server class and bid pricing
- **Tailscale Operator**: Mesh connectivity via OAuth client credentials
- **Liqo**: Cluster federation with ardenone-hub (optional, for compute clusters)
- **Traefik**: Ingress controller (ClusterIP only - never LoadBalancer)
- **cert-manager**: TLS certificate automation
- **ArgoCD**: GitOps controller with App-of-Apps bootstrap

Clusters are disposable spot instances designed for cost-efficient batch workloads and horizontal scaling across the fleet.

## Module Layout

```
rackspace-spot-terraform/
├── backend.tf           # Remote state backend configuration
├── bootstrap.tf         # Cluster bootstrap tools and infrastructure
├── cloudspace.tf        # Rackspace Spot cloudspace resource
├── naming.tf           # Naming conventions and cloudspace generation
├── nodepools.tf        # Worker node pool configuration
├── peering.tf          # Liqo peering with ardenone-hub
├── outputs.tf          # Output values (kubeconfig, API endpoints)
├── providers.tf        # Terraform provider configuration
├── variables.tf        # Module variable definitions
├── clusters/           # Per-cluster Terraform configurations
│   └── ord-devimprint/
├── scripts/           # Wrapper scripts for Terraform operations
│   ├── tf-apply.sh    # OpenBao-aware apply wrapper
│   └── seed-openbao.sh # Secret migration script
└── docs/              # Design documentation and ADRs
```

## Required Variables and Secrets

### Variables

Required variables are defined in `variables.tf`:

| Variable | Description | Default |
|----------|-------------|---------|
| `rackspace_spot_token` | Rackspace Spot API refresh token (sensitive) | - |
| `cloudspace_name` | Cloudspace name (auto-generated if empty) | `""` |
| `region` | Rackspace Spot region | `"us-east-iad-1"` |
| `kubernetes_version` | Kubernetes version | `"1.31.1"` |
| `server_class` | Spot server class | `"gp.vs1.medium-iad"` |
| `node_count` | Number of worker nodes | `3` |
| `bid_price` | Hourly bid price | `0.001` |
| `tailscale_oauth_client_id` | Tailscale OAuth client ID (sensitive) | - |
| `tailscale_oauth_client_secret` | Tailscale OAuth client secret (sensitive) | - |
| `github_token` | GitHub PAT for ArgoCD (sensitive) | - |
| `skip_liqo` | Skip Liqo installation | `false` |
| `skip_traefik` | Skip Traefik installation | `false` |
| `skip_cert_manager` | Skip cert-manager installation | `false` |
| `skip_argocd` | Skip ArgoCD installation | `false` |

### Secrets (by name and source path)

Never commit credential values. Store secrets in OpenBao at these paths:

| Secret | OpenBao Path | Key | Variable |
|--------|--------------|-----|----------|
| Rackspace Spot refresh token | `secret/rs-manager/rackspace-spot-terraform/credentials` | `token` | `rackspace_spot_token` |
| Tailscale OAuth client ID | `secret/rs-manager/rackspace-spot-terraform/credentials` | `tailscale_oauth_client_id` | `tailscale_oauth_client_id` |
| Tailscale OAuth client secret | `secret/rs-manager/rackspace-spot-terraform/credentials` | `tailscale_oauth_client_secret` | `tailscale_oauth_client_secret` |
| GitHub PAT for ArgoCD | `secret/rs-manager/rackspace-spot-terraform/credentials` | `github_token` | `github_token` |

The Spot token is **organization-level**, not per-cloudspace - the same token provisions all clusters in your org.

### Secret Seeding

One-time secret migration from local tfvars to OpenBao:

```bash
export BAO_TOKEN=hvs.your-token-here
./scripts/seed-openbao.sh
```

This writes credentials to OpenBao via stdin only - values never appear in argv, logs, or commits.

## Plan/Apply Execution

### Prerequisites

1. **OpenBao Access**: Token with read access to `secret/rs-manager/rackspace-spot-terraform/*`
2. **Terraform**: Version 1.10+ for remote state migration
3. **bao CLI**: Available in PATH on ex44 and lab servers
4. **Remote State Backend**: S3-compatible Garage bucket with versioning enabled (see `docs/terraform-state.md`)

### Manual Execution

Use the OpenBao-aware wrapper script for all operations:

```bash
# Set your OpenBao token
export BAO_TOKEN=hvs.your-token-here

# Plan changes
./scripts/tf-apply.sh plan

# Apply changes
./scripts/tf-apply.sh apply

# Apply with auto-approval
./scripts/tf-apply.sh apply -auto-approve

# Pass additional terraform arguments
./scripts/tf-apply.sh apply -lock-timeout=5m
```

The wrapper fetches secrets from OpenBao and exports them as `TF_VAR_*` environment variables before invoking Terraform.

### CI via Argo Workflows

Once the `rackspac-53091284` workflow template exists (see bead `rackspac-53091284`), CI will run automatically on commits to `main`. The workflow will:

1. Initialize Terraform with remote state backend
2. Run `terraform plan` with OpenBao credentials
3. Wait for approval or auto-apply based on policy
4. Run `terraform apply` on approval
5. Capture outputs and update cluster inventory

Until the workflow is deployed, use the manual execution path above.

## Storage Class Rule

**Always use `sata` or `sata-large` storage classes. Never `ssd` or `ssd-large`.**

Rackspace Spot clusters are ephemeral and cost-optimized. SSD storage is unnecessary and adds cost. Always set `storageClassName` explicitly:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-pvc
spec:
  storageClassName: sata  # or sata-large
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

Cinder volumes cannot be expanded or reclassed in place on Rackspace Spot.

## Networking Rules

### No LoadBalancers

Rackspace Spot clusters must NOT provision cloud load balancers. All service types must be `ClusterIP` or `NodePort` — never `LoadBalancer`.

Accepted patterns for exposing application services:

- **Tailscale operator**: Annotate a ClusterIP service with `tailscale.com/expose: "true"` to make it reachable on the tailnet
- **Cloudflare Tunnels**: Route public traffic through cloudflared, never through a cloud LB

### Liqo WireGuard Gateway

The Liqo WireGuard gateway uses `NodePort` type. Liqo reads the node's public IP and the auto-assigned nodePort, then advertises them as the gateway endpoint. The hub's GatewayClient connects directly to `<node-ip>:<nodePort>` over UDP.

## Per-Cluster Configurations

Each managed cluster has its own configuration under `clusters/<name>/`:

- **rs-manager** (repository root): Management cluster for Rackspace Spot operations
- **ord-devimprint** (`clusters/ord-devimprint/`): Chicago-based development cluster

Each configuration uses the same module structure with cluster-specific `.tfvars` files.

## Terraform Output Contract

The repository has two independent Terraform root configurations. The root
configuration provisions the IAD cluster; `clusters/ord-devimprint` manages
node pools for the existing Chicago cluster. Their complete output sets are:

| Configuration | Output | Terraform value format | Intended consumer | Sensitive |
| --- | --- | --- | --- | --- |
| Repository root | `cloudspace_name` | String containing the explicit or generated Rackspace Spot cloudspace name. | Provisioning automation and cluster inventory use it to identify the cluster. | No |
| Repository root | `api_server` | String containing the Kubernetes API server URL from the Spot kubeconfig data source, normally an HTTPS URL. | Authorized clients and inventory consumers that need the API endpoint. Bootstrap reads the data source directly rather than consuming this output. | No |
| Repository root | `kubeconfig` | String containing the raw serialized kubeconfig YAML, not a file path. | An authorized operator or automation that needs Kubernetes credentials. The bootstrap resources separately write the same provider value to `/tmp/<cloudspace>.kubeconfig` with mode `0600`. | **Yes** |
| Repository root | `estimated_hourly_cost` | Number in USD per hour, calculated as `node_count * bid_price` for the configured worker pool. It is a bid-based estimate, not the clearing price. | Cost summaries and provisioning inventory. | No |
| `clusters/ord-devimprint` | `estimated_hourly_cost` | Number in USD per hour, calculated as `node_count * bid_price` for the general worker pool. It excludes the separately configured Postgres pool and any clearing-price difference. | Cost summaries and inventory for the existing Chicago cluster's general worker pool. | No |

The kubeconfig is redacted in normal Terraform output, but Terraform still
stores it in state. Treat access to the state as access to cluster credentials;
avoid printing the value or writing it to logs. No Terraform output named
`cluster_id` is defined: the peering provisioner queries the cluster ID from
Kubernetes internally when it needs it.

## Documentation

- `CLAUDE.md`: Project-specific instructions and constraints
- `docs/liqo-tailscale-contract.md`: Hub discovery, credentials, compute role,
  skip behavior, and Liqo/Tailscale smoke-test contract
- `docs/optional-components.md`: Skip switches, bootstrap dependencies, valid
  combinations, and rerun behavior
- `docs/argocd-bootstrap.md`: App-of-Apps source, credentials, sync policy,
  readiness criteria, and smoke check
- `docs/terraform-state.md`: Remote state backend architecture (ADR-001)
- `docs/plan/plan.md`: Implementation planning and architecture decisions
- `MIGRATION_STATUS.md`: Migration status and compatibility notes

## License

Licensed under the Apache License, Version 2.0. See LICENSE for the full text.
