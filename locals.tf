locals {
  kubernetes_version     = "v1.29.2"
  cluster_name           = "gh-kind-cluster"
  base_domain            = format("%s.nip.io", replace(module.traefik.external_ip, ".", "-"))
  subdomain              = ""
  cluster_issuer         = module.cert-manager.cluster_issuers.ca
  enable_service_monitor = false # Can be enabled after the first bootstrap.
  app_autosync           = true ? { allow_empty = false, prune = true, self_heal = true } : {}
}
