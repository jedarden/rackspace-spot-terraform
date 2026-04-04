resource "spot_cloudspace" "main" {
  cloudspace_name    = "iad-ci"
  region             = "us-east-iad-1"
  hacontrol_plane    = false
  wait_until_ready   = true
  kubernetes_version = var.kubernetes_version
  cni                = "calico"
}
