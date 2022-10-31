# Cluster

locals {
  cluster_name     = "gh-v1-cluster"
  cluster_issuer   = "ca-issuer"
  argocd_namespace = "argocd"
}

module "kind" {
  source = "../devops-stack-module-kind" # TODO change to git source eventually

  cluster_name = local.cluster_name
  base_domain  = "127-0-0-1.nip.io" # I need this line in Windows to access my pods in WSL 2
  
  # Need to use < v1.25 because of Keycloak trying to deploy a PodDisruptionBudget https://kubernetes.io/docs/reference/using-api/deprecation-guide/#poddisruptionbudget-v125 
  kubernetes_version = "v1.24.7"
}

#######

# Providers

provider "kubernetes" {
  host                   = module.kind.kubernetes_host
  client_certificate     = module.kind.kubernetes_client_certificate
  client_key             = module.kind.kubernetes_client_key
  cluster_ca_certificate = module.kind.kubernetes_cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host               = module.kind.kubernetes_host
    client_certificate = module.kind.kubernetes_client_certificate
    client_key         = module.kind.kubernetes_client_key
    insecure           = true # This is needed because the Certificate Authority is self-signed.
  }
}

provider "argocd" {
  server_addr                 = "127.0.0.1:8080"
  auth_token                  = module.argocd_bootstrap.argocd_auth_token
  insecure                    = true
  plain_text                  = true
  port_forward                = true
  port_forward_with_namespace = local.argocd_namespace

  kubernetes {
    host                   = module.kind.kubernetes_host
    client_certificate     = module.kind.kubernetes_client_certificate
    client_key             = module.kind.kubernetes_client_key
    cluster_ca_certificate = module.kind.kubernetes_cluster_ca_certificate
  }
}

#######

# Bootstrap Argo CD

module "argocd_bootstrap" {
  source = "git::https://github.com/camptocamp/devops-stack-module-argocd.git//bootstrap"

  cluster_name = module.kind.cluster_name
  base_domain  = module.kind.base_domain

  # An empty cluster issuer is the only way I got the bootstrap Argo CD to be deployed.
  # The `ca-issuer` is only available after we deployed `cert-manager`.
  cluster_issuer = ""

  depends_on = [module.kind]
}

#######

# Cluster apps

module "ingress" {
  source = "git::https://github.com/camptocamp/devops-stack-module-traefik.git//nodeport"

  cluster_name     = module.kind.cluster_name
  base_domain      = module.kind.base_domain
  argocd_namespace = local.argocd_namespace

  # We cannot have multiple Traefik replicas binding to the same ports while both are deployed on 
  # the same KinD container in Docker, which is our case as we only deploy the control-plane node. 
  helm_values = [{
    traefik = {
      deployment = {
        replicas = 1
      }
    }
  }]

  depends_on = [module.argocd_bootstrap]
}

module "cert-manager" {
  source = "git::https://github.com/camptocamp/devops-stack-module-cert-manager.git//self-signed"

  cluster_name     = module.kind.cluster_name
  base_domain      = module.kind.base_domain
  argocd_namespace = local.argocd_namespace

  depends_on = [module.argocd_bootstrap]
}


module "oidc" {
  source = "git::https://github.com/camptocamp/devops-stack-module-keycloak.git"

  cluster_name = module.kind.cluster_name
  argocd = { # TODO Simplify this variable in the Keycloak module because we only need the namespace and not the domain
    namespace = local.argocd_namespace
    domain    = module.argocd_bootstrap.argocd_domain
  }
  base_domain    = module.kind.base_domain
  cluster_issuer = local.cluster_issuer

  depends_on = [module.ingress, module.cert-manager]
}

########
