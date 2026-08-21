terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "state/root/terraform.tfstate"
    region = "garage"

    # Garage does not provide virtual-host bucket DNS. Keep the endpoint on
    # the independently-provisioned cluster's Tailscale-only ingress.
    endpoints = {
      s3 = "https://garage-s3-ardenone-cluster-ts.ardenone.com"
    }
    use_path_style = true

    # Terraform >= 1.10 uses the sibling .tflock object for native locking.
    use_lockfile = true

    # Garage is S3-compatible, not AWS S3. Credentials still come from the
    # normal AWS environment/profile configuration and are intentionally not
    # stored in this file.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}
