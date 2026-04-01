output "cloudspace_name" {
  value = spot_cloudspace.main.cloudspace_name
}

data "spot_kubeconfig" "main" {
  cloudspace_name = spot_cloudspace.main.cloudspace_name
  depends_on      = [spot_spotnodepool.workers]
}

output "kubeconfig" {
  value     = data.spot_kubeconfig.main.raw
  sensitive = true
}
