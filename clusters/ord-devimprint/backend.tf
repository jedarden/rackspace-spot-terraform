terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "state/ord-devimprint/terraform.tfstate"
    region = "garage"

    # Keep state on the independently-provisioned cluster's Tailscale-only
    # Garage ingress; Garage does not provide virtual-host bucket DNS.
    endpoints = {
      s3 = "https://garage-s3-ardenone-cluster-ts.ardenone.com"
    }
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}
