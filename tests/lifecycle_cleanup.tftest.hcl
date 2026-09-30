mock_provider "spot" {
  mock_resource "spot_cloudspace" {}
  mock_resource "spot_spotnodepool" {}
}

override_data {
  target = data.spot_kubeconfig.main
  values = {
    raw = "mock-kubeconfig"
  }
}

mock_provider "random" {
  mock_resource "random_pet" {
    defaults = {
      id = "mock-pet"
    }
  }
}

variables {
  rackspace_spot_token          = "test-spot-token"
  tailscale_oauth_client_id     = "test-tailscale-client"
  tailscale_oauth_client_secret = "test-tailscale-secret"
  github_token                  = "test-github-token"

  # Keep the lifecycle acceptance test focused on the first bootstrap step.
  # The mocked cluster and provider are still created and Terraform tears them
  # down after this apply run.
  skip_liqo         = true
  skip_traefik      = true
  skip_cert_manager = true
  skip_argocd       = true
}

run "applies_spot_resources_and_bootstraps_with_a_temporary_kubeconfig" {
  command = apply

  assert {
    condition = (
      spot_cloudspace.main.cloudspace_name == var.cloudspace_name &&
      spot_spotnodepool.workers.cloudspace_name == var.cloudspace_name &&
      length(null_resource.tailscale) == 1 &&
      fileexists(local_sensitive_file.spot_kubeconfig.filename)
    )
    error_message = "The apply must create the Spot cloudspace and pool, run bootstrap, and materialize its kubeconfig."
  }
}
