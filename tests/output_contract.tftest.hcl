mock_provider "spot" {
  mock_resource "spot_cloudspace" {}
  mock_resource "spot_spotnodepool" {}
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
}

run "publishes_the_complete_root_output_contract" {
  command = plan

  variables {
    cloudspace_name = "output-contract-cluster"
    node_count      = 3
    bid_price       = 0.02
    skip_bootstrap  = true
  }

  assert {
    condition     = output.cloudspace_name == "output-contract-cluster"
    error_message = "The cloudspace_name output must be the cluster's configured name."
  }

  assert {
    condition     = output.estimated_hourly_cost == 0.06
    error_message = "The estimated_hourly_cost output must be the configured worker bid estimate."
  }

  assert {
    condition     = !issensitive(output.cloudspace_name) && !issensitive(output.estimated_hourly_cost)
    error_message = "The cluster name and cost estimate outputs must not be marked sensitive."
  }

  # The kubeconfig data source depends on the newly planned node pool, so its
  # values are unknown until apply. Check those output declarations directly
  # instead of applying infrastructure or writing a kubeconfig during tests.
  assert {
    condition = alltrue([
      can(regex("(?s)output\\s+\"cloudspace_name\"\\s*\\{", file("${path.root}/outputs.tf"))),
      can(regex("(?s)output\\s+\"api_server\"\\s*\\{", file("${path.root}/outputs.tf"))),
      can(regex("(?s)output\\s+\"kubeconfig\"\\s*\\{", file("${path.root}/outputs.tf"))),
      can(regex("(?s)output\\s+\"estimated_hourly_cost\"\\s*\\{", file("${path.root}/outputs.tf")))
    ])
    error_message = "All four documented root outputs must be declared."
  }

  assert {
    condition = alltrue([
      can(regex("(?s)output\\s+\"api_server\"\\s*\\{[^}]*value\\s*=\\s*data\\.spot_kubeconfig\\.main\\.kubeconfigs\\[0\\]\\.host", file("${path.root}/outputs.tf"))),
      can(regex("(?s)output\\s+\"kubeconfig\"\\s*\\{[^}]*value\\s*=\\s*data\\.spot_kubeconfig\\.main\\.raw[^}]*sensitive\\s*=\\s*true", file("${path.root}/outputs.tf"))),
      !can(regex("(?s)output\\s+\"cloudspace_name\"\\s*\\{[^}]*sensitive\\s*=\\s*true", file("${path.root}/outputs.tf"))),
      !can(regex("(?s)output\\s+\"api_server\"\\s*\\{[^}]*sensitive\\s*=\\s*true", file("${path.root}/outputs.tf"))),
      !can(regex("(?s)output\\s+\"estimated_hourly_cost\"\\s*\\{[^}]*sensitive\\s*=\\s*true", file("${path.root}/outputs.tf")))
    ])
    error_message = "The API endpoint must map to the provider host; only the raw kubeconfig is sensitive."
  }
}
