resource "spot_spotnodepool" "workers" {
  cloudspace_name      = spot_cloudspace.main.cloudspace_name
  server_class         = var.server_class
  bid_price            = var.bid_price
  desired_server_count = var.node_count
}
