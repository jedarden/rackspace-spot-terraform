# Control node: always-on, runs Argo controller/server, ESO, Liqo, Tailscale.
# 2 vCPU / 3.75 GB — enough for control plane services.
resource "spot_spotnodepool" "control" {
  cloudspace_name      = spot_cloudspace.main.cloudspace_name
  server_class         = "gp.vs1.medium-iad"
  bid_price            = 0.001
  desired_server_count = 1

  labels = {
    "node-role" = "control"
  }

  taints = [
    {
      key    = "node-role"
      value  = "control"
      effect = "NoSchedule"
    }
  ]
}

# Worker nodes: build pods schedule here via node affinity.
# 4 vCPU / 7.5 GB — handles Docker builds (kaniko/buildkit).
# Autoscales 1-3 nodes based on pending pod demand.
resource "spot_spotnodepool" "workers" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  server_class    = "ch.vs1.large-iad"
  bid_price       = 0.001

  autoscaling = {
    min_nodes = 1
    max_nodes = 3
  }

  labels = {
    "node-role" = "worker"
  }
}
