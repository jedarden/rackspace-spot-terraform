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

run "provisions_cloudspace_workers_and_outputs" {
  command = plan

  variables {
    cloudspace_name = "acceptance-cluster"
    region          = "us-east-iad-1"
    server_class    = "gp.vs1.medium-iad"
    node_count      = 3
    bid_price       = 0.02
    skip_bootstrap  = true
  }

  assert {
    condition     = spot_cloudspace.main.cloudspace_name == "acceptance-cluster"
    error_message = "The cloudspace must use the requested name."
  }

  assert {
    condition     = spot_cloudspace.main.region == "us-east-iad-1"
    error_message = "The cloudspace must use the requested region."
  }

  assert {
    condition     = spot_cloudspace.main.hacontrol_plane == false && spot_cloudspace.main.cni == "calico"
    error_message = "The cloudspace must use a worker-managed Calico control plane."
  }

  assert {
    condition     = spot_spotnodepool.workers.cloudspace_name == spot_cloudspace.main.cloudspace_name
    error_message = "The worker node pool must attach to the created cloudspace."
  }

  assert {
    condition     = spot_spotnodepool.workers.server_class == "gp.vs1.medium-iad"
    error_message = "The worker node pool must use the requested server class."
  }

  assert {
    condition     = spot_spotnodepool.workers.desired_server_count == 3
    error_message = "The worker node pool must request the configured number of nodes."
  }

  assert {
    condition     = spot_spotnodepool.workers.bid_price == 0.02
    error_message = "The worker node pool must use the configured hourly bid."
  }

  assert {
    condition     = output.cloudspace_name == "acceptance-cluster"
    error_message = "The cloudspace name output must identify the created cluster."
  }

  assert {
    condition     = output.estimated_hourly_cost == 0.06
    error_message = "Estimated hourly cost must be node_count multiplied by bid_price."
  }
}

run "generates_a_cloudspace_name_when_unspecified" {
  command = plan

  variables {
    cloudspace_name = ""
    skip_bootstrap  = true
  }

  assert {
    condition = strcontains(
      file("${path.root}/naming.tf"),
      "var.cloudspace_name != \"\" ? var.cloudspace_name : \"iad-$${random_pet.cluster.id}\""
    )
    error_message = "An omitted cloudspace name must use the generated iad-prefixed name."
  }
}

run "plans_bootstrap_components_and_contracts" {
  command = plan

  variables {
    cloudspace_name = "acceptance-cluster"
  }

  assert {
    condition = (
      length(null_resource.install_tools) == 1 &&
      length(null_resource.tailscale) == 1 &&
      length(null_resource.liqo) == 1 &&
      length(null_resource.traefik) == 1 &&
      length(null_resource.cert_manager) == 1 &&
      length(null_resource.argocd) == 1 &&
      length(null_resource.app_of_apps) == 1
    )
    error_message = "A normal bootstrap plan must include each ordered bootstrap component."
  }

  assert {
    condition = (
      null_resource.tailscale[0].triggers.cloudspace == "acceptance-cluster" &&
      null_resource.liqo[0].triggers.cloudspace == "acceptance-cluster" &&
      null_resource.traefik[0].triggers.cloudspace == "acceptance-cluster" &&
      null_resource.cert_manager[0].triggers.cloudspace == "acceptance-cluster" &&
      null_resource.argocd[0].triggers.cloudspace == "acceptance-cluster" &&
      null_resource.app_of_apps[0].triggers.cloudspace == "acceptance-cluster"
    )
    error_message = "Bootstrap components must be scoped to the requested cloudspace."
  }

  assert {
    condition = alltrue([
      strcontains(file("${path.root}/bootstrap.tf"), "--set oauth.secretName=operator-oauth"),
      strcontains(file("${path.root}/bootstrap.tf"), "liqo/liqo"),
      strcontains(file("${path.root}/bootstrap.tf"), "gateway.service.type=NodePort"),
      strcontains(file("${path.root}/bootstrap.tf"), "traefik/traefik"),
      strcontains(file("${path.root}/bootstrap.tf"), "--set service.type=ClusterIP"),
      strcontains(file("${path.root}/bootstrap.tf"), "jetstack/cert-manager"),
      strcontains(file("${path.root}/bootstrap.tf"), "--set crds.enabled=true"),
      strcontains(file("${path.root}/bootstrap.tf"), "argo/argo-cd"),
      strcontains(file("${path.root}/bootstrap.tf"), "--wait"),
      strcontains(file("${path.root}/bootstrap.tf"), "kind: Application"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on      = [spot_spotnodepool.workers]"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on = [local_sensitive_file.spot_kubeconfig]"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on = [null_resource.install_tools]"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on = [null_resource.tailscale]"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on = [null_resource.cert_manager, null_resource.traefik]"),
      strcontains(file("${path.root}/bootstrap.tf"), "depends_on = [null_resource.argocd]")
    ])
    error_message = "Bootstrap commands and explicit dependency edges must retain the Tailscale, Liqo, Traefik, cert-manager, and ArgoCD contracts."
  }
}

run "rejects_nonpositive_or_fractional_node_counts" {
  command = plan

  variables {
    node_count = 0
  }

  expect_failures = [var.node_count]
}

run "rejects_fractional_node_counts" {
  command = plan

  variables {
    node_count = 1.5
  }

  expect_failures = [var.node_count]
}

run "rejects_nonpositive_bid_prices" {
  command = plan

  variables {
    bid_price = 0
  }

  expect_failures = [var.bid_price]
}

run "rejects_malformed_regions" {
  command = plan

  variables {
    region = "iad"
  }

  expect_failures = [var.region]
}

run "rejects_malformed_server_classes" {
  command = plan

  variables {
    server_class = "medium"
  }

  expect_failures = [var.server_class]
}

run "rejects_server_classes_for_a_different_region" {
  command = plan

  variables {
    server_class = "gp.vs1.medium-ord"
  }

  expect_failures = [var.server_class]
}
