output "cloudspace_name" {
  value = local.cloudspace_name
}

output "api_server" {
  value = data.spot_kubeconfig.main.kubeconfigs[0].host
}

output "kubeconfig" {
  value     = data.spot_kubeconfig.main.raw
  sensitive = true
}

output "estimated_hourly_cost" {
  value       = var.node_count * var.bid_price
  description = "Estimated hourly cost based on the bid price, not necessarily the clearing price."
}

data "spot_kubeconfig" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  depends_on      = [spot_spotnodepool.workers]
}
