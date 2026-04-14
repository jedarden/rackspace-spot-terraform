# Rackspace Spot Terraform Module

Provisions disposable Kubernetes clusters on Rackspace Spot and peers them with ardenone-hub via Liqo.

## Networking Rules

### No LoadBalancers (with one exception)

Rackspace Spot clusters must NOT provision cloud load balancers for application workloads. All application service types must be `ClusterIP`.

Accepted patterns for exposing application services:

- **Tailscale operator** — annotate a ClusterIP service with `tailscale.com/expose: "true"` to make it reachable on the tailnet
- **Cloudflare Tunnels** — route public traffic through cloudflared, never through a cloud LB

This applies to every Helm install in this module:

- Traefik: `--set service.type=ClusterIP`
- Any future application chart: never set `service.type=LoadBalancer`

### Exception: Liqo WireGuard Gateway

The Liqo WireGuard gateway service MUST use `LoadBalancer` type. This is the one exception.

- `liqoctl peer`: `--gw-server-service-type LoadBalancer` (default, do not override to ClusterIP)
- `bootstrap.tf` Liqo Helm: `gateway.service.type=LoadBalancer`

**Why the exception:** Liqo v1.1.2's `gateway.config.addressOverride` setting is inert — it's in the Helm values but `--gateway-address-override` is never passed to `liqo-controller-manager`. The WgGatewayServer status always advertises the service's actual IP. With ClusterIP, that's an unreachable in-cluster IP. With LoadBalancer, Rackspace Spot's cloud controller assigns a public IP that the hub can reach. WireGuard authenticates via pre-shared keys, so public exposure is safe.

### Why (general)

Spot clusters are ephemeral and connected primarily via the Tailscale mesh. Cloud load balancers for applications are unnecessary, add cost, and expose services to the public internet without cause.
