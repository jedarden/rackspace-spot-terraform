resource "spot_cloudspace" "main" {
  cloudspace_name    = local.cloudspace_name
  region             = var.region
  hacontrol_plane    = false
  wait_until_ready   = true
  kubernetes_version = var.kubernetes_version
  cni                = "calico"
}
