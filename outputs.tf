output "kubernetes_kubeconfig" {
  description = "Configuration that can be copied into `.kube/config in order to access the cluster with `kubectl`."
  value       = module.kind.raw_kubeconfig
  sensitive   = true
}

output "keycloak_admin_credentials" {
  description = "TODO" # TODO
  value       = module.keycloak.admin_credentials
  sensitive   = true
}

output "keycloak_users" {
  description = "TODO" # TODO
  value       = module.oidc.devops_stack_users_passwords
  sensitive   = true
}
