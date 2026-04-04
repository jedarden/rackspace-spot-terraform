# Control node: 2 vCPU / 3.75 GB — Argo controller/server, Liqo, Tailscale.
resource "spot_spotnodepool" "control" {
  cloudspace_name      = spot_cloudspace.main.cloudspace_name
  server_class         = "gp.vs1.medium-iad"
  bid_price            = 0.001
  desired_server_count = 1

  labels = {
    "ci" = "worker"
  }
}

# Worker nodes: 4 vCPU / 7.5 GB — build pods (kaniko/buildkit).
resource "spot_spotnodepool" "workers" {
  cloudspace_name      = spot_cloudspace.main.cloudspace_name
  server_class         = "ch.vs1.large-iad"
  bid_price            = 0.01
  desired_server_count = 1

  labels = {
    "ci" = "worker"
  }
}
