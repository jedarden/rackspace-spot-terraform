terraform {
  required_version = ">= 1.5"

  required_providers {
    spot = {
      source  = "rackerlabs/spot"
      version = ">= 0.1.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

provider "spot" {
  token = var.rackspace_spot_token
}

# Providers targeting the newly created spot cluster
provider "helm" {
  kubernetes {
    host     = data.spot_kubeconfig.main.kubeconfigs[0].host
    token    = data.spot_kubeconfig.main.kubeconfigs[0].token
    insecure = data.spot_kubeconfig.main.kubeconfigs[0].insecure
  }
}

provider "kubernetes" {
  host     = data.spot_kubeconfig.main.kubeconfigs[0].host
  token    = data.spot_kubeconfig.main.kubeconfigs[0].token
  insecure = data.spot_kubeconfig.main.kubeconfigs[0].insecure
}
