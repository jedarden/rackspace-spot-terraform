data "spot_kubeconfig" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  depends_on      = [spot_spotnodepool.control, spot_spotnodepool.workers]
}

output "cloudspace_name" {
  value = "iad-ci"
}

output "api_server" {
  value = data.spot_kubeconfig.main.kubeconfigs[0].host
}

output "kubeconfig" {
  value     = data.spot_kubeconfig.main.raw
  sensitive = true
}
