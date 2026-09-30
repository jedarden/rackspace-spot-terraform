output "cloudspace_name" {
  value       = local.cloudspace_name
  description = "Cloudspace name for cluster inventory and provisioning automation."
}

output "api_server" {
  value       = data.spot_kubeconfig.main.kubeconfigs[0].host
  description = "Kubernetes API server URL for authorized cluster clients and inventory consumers."
}

output "kubeconfig" {
  value       = data.spot_kubeconfig.main.raw
  description = "Raw kubeconfig YAML for authorized cluster clients; contains access credentials."
  sensitive   = true
}

output "estimated_hourly_cost" {
  value       = var.node_count * var.bid_price
  description = "Estimated worker-pool cost in USD per hour at the configured bid price, not necessarily the clearing price."
}

data "spot_kubeconfig" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  depends_on      = [spot_spotnodepool.workers]
}
