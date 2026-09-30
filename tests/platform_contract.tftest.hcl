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
  cloudspace_name               = "platform-contract-cluster"
}

run "keeps_the_calico_traefik_and_cert_manager_contracts" {
  command = plan

  assert {
    condition     = spot_cloudspace.main.cni == "calico"
    error_message = "New Rackspace Spot cloudspaces must use Calico as their CNI."
  }

  assert {
    condition = (
      length(null_resource.traefik) == 1 &&
      strcontains(
        split(
          "resource \"null_resource\" \"cert_manager\"",
          split("resource \"null_resource\" \"traefik\"", file("${path.root}/bootstrap.tf"))[1]
        )[0],
        "--set service.type=ClusterIP"
      ) &&
      !strcontains(
        split(
          "resource \"null_resource\" \"cert_manager\"",
          split("resource \"null_resource\" \"traefik\"", file("${path.root}/bootstrap.tf"))[1]
        )[0],
        "service.type=LoadBalancer"
      )
    )
    error_message = "Traefik must be installed with a ClusterIP service and must never request a LoadBalancer."
  }

  assert {
    condition = (
      length(null_resource.cert_manager) == 1 &&
      strcontains(
        split(
          "resource \"null_resource\" \"argocd\"",
          split("resource \"null_resource\" \"cert_manager\"", file("${path.root}/bootstrap.tf"))[1]
        )[0],
        "helm upgrade --install cert-manager jetstack/cert-manager"
      ) &&
      strcontains(
        split(
          "resource \"null_resource\" \"argocd\"",
          split("resource \"null_resource\" \"cert_manager\"", file("${path.root}/bootstrap.tf"))[1]
        )[0],
        "--set crds.enabled=true"
      )
    )
    error_message = "The default bootstrap must install cert-manager and its Certificate and Issuer CRDs."
  }
}
