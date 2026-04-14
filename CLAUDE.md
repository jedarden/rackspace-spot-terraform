# Rackspace Spot Terraform Module

Provisions disposable Kubernetes clusters on Rackspace Spot and peers them with ardenone-hub via Liqo.

## Networking Rules

### No LoadBalancers

Rackspace Spot clusters must NOT provision cloud load balancers. All service types must be `ClusterIP` or `NodePort` — never `LoadBalancer`.

Accepted patterns for exposing application services:

- **Tailscale operator** — annotate a ClusterIP service with `tailscale.com/expose: "true"` to make it reachable on the tailnet
- **Cloudflare Tunnels** — route public traffic through cloudflared, never through a cloud LB

This applies to every Helm install in this module:

- Traefik: `--set service.type=ClusterIP`
- Any future application chart: never set `service.type=LoadBalancer`

### Liqo WireGuard Gateway uses NodePort

The Liqo WireGuard gateway uses `NodePort` type. Liqo reads the node's public IP and the auto-assigned nodePort, then advertises them as the gateway endpoint. The hub's GatewayClient connects directly to `<node-ip>:<nodePort>` over UDP.

- `liqoctl peer`: `--gw-server-service-type NodePort`
- `bootstrap.tf` Liqo Helm: `gateway.service.type=NodePort`

**Why NodePort instead of ClusterIP:** Liqo v1.1.2's `gateway.config.addressOverride` setting is inert — it's in the Helm values but `--gateway-address-override` is never passed to `liqo-controller-manager`. With ClusterIP, the WgGatewayServer status advertises an unreachable in-cluster IP. With NodePort, Liqo reads the node's public IP and nodePort, which are reachable from ardenone-hub over the internet. WireGuard authenticates via pre-shared keys, so public UDP port exposure is safe.

### Why (general)

Spot clusters are ephemeral and connected primarily via the Tailscale mesh. Cloud load balancers are unnecessary, add cost, and expose services to the public internet without cause.
