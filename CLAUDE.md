# Rackspace Spot Terraform Module

Provisions disposable Kubernetes clusters on Rackspace Spot and peers them with ardenone-hub via Liqo.

## Networking Rules

### No LoadBalancers

Rackspace Spot clusters must NEVER provision cloud load balancers. All service types must be `ClusterIP`.

Accepted patterns for exposing services:

- **Tailscale operator** — annotate a ClusterIP service with `tailscale.com/expose: "true"` to make it reachable on the tailnet
- **Cloudflare Tunnels** — route public traffic through cloudflared, never through a cloud LB

This applies to every Helm install and `liqoctl` flag in this module:

- Traefik: `--set service.type=ClusterIP`
- Liqo gateway: `--set gateway.service.type=ClusterIP`
- `liqoctl peer`: `--gw-server-service-type ClusterIP`
- Any future chart: never set `service.type=LoadBalancer`

### Why

Spot clusters are ephemeral and connected exclusively via the Tailscale mesh. Cloud load balancers are unnecessary, add cost, and expose services to the public internet without cause.
