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
  
}
