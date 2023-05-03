locals {
  cluster_name   = "gh-v1-cluster"
  cluster_issuer = "ca-issuer"
}

provider "kubernetes" {
  host                   = module.kind.parsed_kubeconfig.host
  client_certificate     = module.kind.parsed_kubeconfig.client_certificate
  client_key             = module.kind.parsed_kubeconfig.client_key
  cluster_ca_certificate = module.kind.parsed_kubeconfig.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host               = module.kind.parsed_kubeconfig.host
    client_certificate = module.kind.parsed_kubeconfig.client_certificate
    client_key         = module.kind.parsed_kubeconfig.client_key
    insecure           = true # This is needed because the Certificate Authority is self-signed.
  }
}

provider "argocd" {
  server_addr                 = "127.0.0.1:8080"
  auth_token                  = module.argocd_bootstrap.argocd_auth_token
  insecure                    = true
  plain_text                  = true
  port_forward                = true
  port_forward_with_namespace = "argocd"

  kubernetes {
    host                   = module.kind.parsed_kubeconfig.host
    client_certificate     = module.kind.parsed_kubeconfig.client_certificate
    client_key             = module.kind.parsed_kubeconfig.client_key
    cluster_ca_certificate = module.kind.parsed_kubeconfig.cluster_ca_certificate
  }
}

module "kind" {
  source = "git::https://github.com/camptocamp/devops-stack-module-kind.git?ref=v2.1.2"

  cluster_name = local.cluster_name
  # base_domain  = "127-0-0-1.nip.io" # I need this line in Windows to access my pods in WSL 2
  kubernetes_version = "v1.27.1"
}

module "metallb" {
  source = "git::https://github.com/camptocamp/devops-stack-module-metallb.git?ref=v1.0.1"

  subnet = module.kind.kind_subnet
}

module "argocd_bootstrap" {
  source = "git::https://github.com/camptocamp/devops-stack-module-argocd.git//bootstrap?ref=v1.1.0"

  depends_on = [module.kind]
}

module "ingress" {
  source = "git::https://github.com/camptocamp/devops-stack-module-traefik.git//kind?ref=v1.0.0"

  cluster_name = local.cluster_name

  # TODO fix: the base domain is defined later. Proposal: remove redirection from traefik module and add it in dependent modules.
  # For now random value is passed to base_domain. Redirections will not work before fix.
  base_domain = "placeholder.com"

  argocd_namespace = module.argocd_bootstrap.argocd_namespace
}

module "cert-manager" {
  source = "git::https://github.com/camptocamp/devops-stack-module-cert-manager.git//self-signed?ref=v2.0.0"

  # TODO remove useless base_domain and cluster_name variables from "self-signed" module.
  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  argocd_namespace = module.argocd_bootstrap.argocd_namespace
}

module "keycloak" {
  source = "git::https://github.com/camptocamp/devops-stack-module-keycloak.git?ref=v1.0.2"

  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  dependency_ids = {
    traefik      = module.ingress.id
    cert-manager = module.cert-manager.id # TODO Fix cert-manager ID as something similar as other modules
  }
}

provider "keycloak" {
  client_id                = "admin-cli"
  username                 = module.keycloak.admin_credentials.username
  password                 = module.keycloak.admin_credentials.password
  url                      = "https://keycloak.apps.${local.cluster_name}.${format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))}"
  tls_insecure_skip_verify = true  # Since we are in a testing environment, do not verify the authenticity of SSL certificates.
  initial_login            = false # Do no try to setup the provider before Keycloak is provisioned.
}

module "oidc" {
  source = "git::https://github.com/camptocamp/devops-stack-module-keycloak.git//oidc_bootstrap?ref=v1.0.2"

  cluster_name = local.cluster_name
  base_domain  = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))

  user_map = {
    gheleno = {
      username   = "gheleno"
      first_name = "Gonçalo"
      last_name  = "Heleno"
      email      = "goncalo.heleno@camptocamp.com"
    }
  }

  dependency_ids = {
    keycloak = module.keycloak.id
  }
}

resource "random_password" "loki_secretKey" {
  length  = 16
  special = false
}

resource "random_password" "thanos_secretKey" {
  length  = 16
  special = false
}

# TODO Propose a way to dinamically create these policies inside of the MinIO module just by passing a list of buckets.
# TODO We could also provide both interfaces, one for manually declaring things, another to just do this.
module "minio" {
  source          = "git::https://github.com/camptocamp/devops-stack-module-minio?ref=v1.0.0"

  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  config_minio = {
    policies = [
      {
        name = "loki-policy"
        statements = [
          {
            resources = ["arn:aws:s3:::loki-bucket"]
            actions   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
          },
          {
            resources = ["arn:aws:s3:::loki-bucket/*"]
            actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          }
        ]
      },
      {
        name = "thanos-policy"
        statements = [
          {
            resources = ["arn:aws:s3:::thanos-bucket"]
            actions   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
          },
          {
            resources = ["arn:aws:s3:::thanos-bucket/*"]
            actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          }
        ]
      }
    ],
    users = [
      {
        accessKey = "loki-user"
        secretKey = random_password.loki_secretKey.result
        policy    = "loki-policy"
      },{
        accessKey = "thanos-user"
        secretKey = random_password.thanos_secretKey.result
        policy    = "thanos-policy"
      }
    ],
    buckets = [
      {
        name = "loki-bucket"
      },
      {
        name = "thanos-bucket"
      }
    ]
  }

  dependency_ids = {
    traefik      = module.ingress.id
    cert-manager = module.cert-manager.id
  }
}

module "loki-stack" {
  source = "git::https://github.com/camptocamp/devops-stack-module-loki-stack//kind?ref=v2.0.2"

  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  distributed_mode = true

  logs_storage = {
    bucket_name       = "loki-bucket"
    endpoint          = module.minio.endpoint
    access_key        = "loki-user"
    secret_access_key = random_password.loki_secretKey.result
  }

  dependency_ids = {
    minio = module.minio.id
  }
}


module "thanos" {
  source = "git::https://github.com/camptocamp/devops-stack-module-thanos//kind?ref=v1.0.0"

  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  metrics_storage = {
    bucket_name       = "thanos-bucket"
    endpoint          = module.minio.endpoint
    access_key        = "thanos-user"
    secret_access_key = random_password.thanos_secretKey.result
  }

  thanos = {
    oidc = module.oidc.oidc
  }

  dependency_ids = {
    oidc  = module.oidc.id
    minio = module.minio.id
  }
}

module "prometheus-stack" {
  source = "git::https://github.com/camptocamp/devops-stack-module-kube-prometheus-stack//kind?ref=v2.0.0"

  cluster_name     = local.cluster_name
  base_domain      = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  cluster_issuer   = local.cluster_issuer
  argocd_namespace = module.argocd_bootstrap.argocd_namespace

  metrics_storage = {
    bucket     = "thanos-bucket"
    endpoint   = module.minio.endpoint
    access_key = "thanos-user"
    secret_key = random_password.thanos_secretKey.result
  }

  prometheus = {
    oidc = module.oidc.oidc
  }
  alertmanager = {
    oidc = module.oidc.oidc
  }
  grafana = {
    enabled                 = true
    oidc                    = module.oidc.oidc
    additional_data_sources = false
  }

  helm_values = [{
    kube-prometheus-stack = {
      grafana = {
        extraSecretMounts = [
          {
            name       = "ca-certificate"
            secretName = "grafana-tls"
            mountPath  = "/etc/ssl/certs/ca.crt"
            readOnly   = true
            subPath    = "ca.crt"
          },
        ]
      }
    }
  }]

  dependency_ids = {
    oidc   = module.oidc.id
    minio  = module.minio.id
    thanos = module.thanos.id
  }
}

# module "grafana" {
#   source = "git::https://github.com/camptocamp/devops-stack-module-grafana.git?ref=v1.0.0-alpha.1"

#   cluster_name     = module.kind.cluster_name
#   argocd_namespace = local.argocd_namespace
#   base_domain      = module.kind.base_domain
#   cluster_issuer   = local.cluster_issuer

#   grafana = {
#     oidc = module.oidc.oidc
#     # We need to explicitly tell Grafana to ignore the self-signed certificate on the OIDC provider.
#     generic_oauth_extra_args = {
#       tls_skip_verify_insecure = true
#     }
#   }

#   depends_on = [module.prometheus-stack, module.loki-stack]
# }


module "argocd" {
  source = "git::https://github.com/camptocamp/devops-stack-module-argocd.git?ref=v1.1.0"

  cluster_name   = local.cluster_name
  base_domain    = format("%s.nip.io", replace(module.ingress.external_ip, ".", "-"))
  cluster_issuer = local.cluster_issuer

  admin_enabled            = false
  namespace                = module.argocd_bootstrap.argocd_namespace
  accounts_pipeline_tokens = module.argocd_bootstrap.argocd_accounts_pipeline_tokens
  server_secretkey         = module.argocd_bootstrap.argocd_server_secretkey

  oidc = {
    name         = "OIDC"
    issuer       = module.oidc.oidc.issuer_url
    clientID     = module.oidc.oidc.client_id
    clientSecret = module.oidc.oidc.client_secret
    requestedIDTokenClaims = {
      groups = {
        essential = true
      }
    }
    requestedScopes = ["openid", "profile", "email", "groups"]
  }

  depends_on = [
    module.oidc,
    # module.cert-manager,
    module.prometheus-stack,
    # module.grafana,
  ]
}

# module "helloworld_apps" {
#   source = "git::https://github.com/camptocamp/devops-stack-module-applicationset.git?ref=v1.1.0"

#   depends_on = [module.argocd]

#   name                   = "helloworld-apps"
#   argocd_namespace       = local.argocd_namespace
#   project_dest_namespace = "*"
#   project_source_repo    = "https://github.com/camptocamp/devops-stack-helloworld-templates.git"

#   generators = [
#     {
#       git = {
#         repoURL  = "https://github.com/camptocamp/devops-stack-helloworld-templates.git"
#         revision = "main"

#         directories = [
#           {
#             path = "apps/*"
#           }
#         ]
#       }
#     }
#   ]
#   template = {
#     metadata = {
#       name = "{{path.basename}}"
#     }

#     spec = {
#       project = "helloworld-apps"

#       source = {
#         repoURL        = "https://github.com/camptocamp/devops-stack-helloworld-templates.git"
#         targetRevision = "main"
#         path           = "{{path}}"

#         helm = {
#           valueFiles = []
#           # The following value defines this global variables that will be available to all apps in apps/*
#           # These are needed to generate the ingresses containing the name and base domain of the cluster.
#           values = <<-EOT
#             cluster:
#               name: "${module.kind.cluster_name}"
#               domain: "${module.kind.base_domain}"
#             apps:
#               traefik_dashboard: false
#               grafana: true
#               prometheus: true
#               thanos: true
#               alertmanager: true
#           EOT
#         }
#       }

#       destination = {
#         name      = "in-cluster"
#         namespace = "{{path.basename}}"
#       }

#       syncPolicy = {
#         automated = {
#           allowEmpty = false
#           selfHeal   = true
#           prune      = true
#         }
#         syncOptions = [
#           "CreateNamespace=true"
#         ]
#       }
#     }
#   }
# }
