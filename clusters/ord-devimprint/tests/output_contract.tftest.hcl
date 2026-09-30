mock_provider "spot" {
  mock_resource "spot_spotnodepool" {}
}

variables {
  rackspace_spot_token = "test-spot-token"
  node_count           = 6
  bid_price            = 0.001
}

run "publishes_the_ord_devimprint_cost_output" {
  command = plan

  assert {
    condition     = output.estimated_hourly_cost == 0.006
    error_message = "The output must report the bid-based general worker-pool estimate."
  }

  assert {
    condition     = !issensitive(output.estimated_hourly_cost)
    error_message = "The cost estimate must be a non-sensitive output."
  }
}
