terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "state/ord-devimprint/terraform.tfstate"
    region = "garage"

    # Garage does not provide virtual-host bucket DNS. Use the direct
    # Tailscale-only S3 service on the independently-provisioned cluster.
    # Tailscale provides transport encryption; Garage's service itself is HTTP.
    endpoints = {
      s3 = "http://garage-ardenone-cluster.tail1b1987.ts.net:3900"
    }
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}
