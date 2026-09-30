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
  cloudspace_name               = "skip-components-cluster"
}

run "skip_liqo_removes_install_and_peering_only" {
  command = plan

  variables {
    skip_liqo = true
  }

  assert {
    condition = (
      length(null_resource.install_tools) == 1 &&
      length(null_resource.tailscale) == 1 &&
      length(null_resource.liqo) == 0 &&
      length(null_resource.liqo_peer) == 0 &&
      length(null_resource.traefik) == 1 &&
      length(null_resource.cert_manager) == 1 &&
      length(null_resource.argocd) == 1 &&
      length(null_resource.app_of_apps) == 1
    )
    error_message = "skip_liqo must remove Liqo and peering without blocking the remaining bootstrap steps."
  }
}

run "skip_traefik_keeps_tls_and_gitops_bootstrap" {
  command = plan

  variables {
    skip_traefik = true
  }

  assert {
    condition = (
      length(null_resource.liqo) == 1 &&
      length(null_resource.liqo_peer) == 1 &&
      length(null_resource.traefik) == 0 &&
      length(null_resource.cert_manager) == 1 &&
      length(null_resource.argocd) == 1 &&
      length(null_resource.app_of_apps) == 1
    )
    error_message = "skip_traefik must omit only Traefik while cert-manager, ArgoCD, and Liqo continue."
  }
}

run "skip_cert_manager_keeps_ingress_and_gitops_bootstrap" {
  command = plan

  variables {
    skip_cert_manager = true
  }

  assert {
    condition = (
      length(null_resource.liqo) == 1 &&
      length(null_resource.liqo_peer) == 1 &&
      length(null_resource.traefik) == 1 &&
      length(null_resource.cert_manager) == 0 &&
      length(null_resource.argocd) == 1 &&
      length(null_resource.app_of_apps) == 1
    )
    error_message = "skip_cert_manager must omit only cert-manager while Traefik, ArgoCD, and Liqo continue."
  }
}

run "skip_traefik_and_cert_manager_is_valid" {
  command = plan

  variables {
    skip_traefik      = true
    skip_cert_manager = true
  }

  assert {
    condition = (
      length(null_resource.liqo) == 1 &&
      length(null_resource.liqo_peer) == 1 &&
      length(null_resource.traefik) == 0 &&
      length(null_resource.cert_manager) == 0 &&
      length(null_resource.argocd) == 1 &&
      length(null_resource.app_of_apps) == 1
    )
    error_message = "Traefik and cert-manager may be skipped together without blocking ArgoCD."
  }
}

run "skip_argocd_removes_argocd_and_app_of_apps_only" {
  command = plan

  variables {
    skip_argocd = true
  }

  assert {
    condition = (
      length(null_resource.install_tools) == 1 &&
      length(null_resource.tailscale) == 1 &&
      length(null_resource.liqo) == 1 &&
      length(null_resource.liqo_peer) == 1 &&
      length(null_resource.traefik) == 1 &&
      length(null_resource.cert_manager) == 1 &&
      length(null_resource.argocd) == 0 &&
      length(null_resource.app_of_apps) == 0
    )
    error_message = "skip_argocd must omit ArgoCD and App-of-Apps without blocking earlier bootstrap steps."
  }
}

run "skip_liqo_and_argocd_is_valid" {
  command = plan

  variables {
    skip_liqo   = true
    skip_argocd = true
  }

  assert {
    condition = (
      length(null_resource.install_tools) == 1 &&
      length(null_resource.tailscale) == 1 &&
      length(null_resource.liqo) == 0 &&
      length(null_resource.liqo_peer) == 0 &&
      length(null_resource.traefik) == 1 &&
      length(null_resource.cert_manager) == 1 &&
      length(null_resource.argocd) == 0 &&
      length(null_resource.app_of_apps) == 0
    )
    error_message = "Independent Liqo and ArgoCD skips must compose without breaking core bootstrap."
  }
}

run "skip_all_optional_components_keeps_core_bootstrap" {
  command = plan

  variables {
    skip_liqo         = true
    skip_traefik      = true
    skip_cert_manager = true
    skip_argocd       = true
  }

  assert {
    condition = (
      length(null_resource.install_tools) == 1 &&
      length(null_resource.tailscale) == 1 &&
      length(null_resource.liqo) == 0 &&
      length(null_resource.liqo_peer) == 0 &&
      length(null_resource.traefik) == 0 &&
      length(null_resource.cert_manager) == 0 &&
      length(null_resource.argocd) == 0 &&
      length(null_resource.app_of_apps) == 0
    )
    error_message = "All optional components may be skipped while tools and Tailscale still bootstrap."
  }
}
