# ==============================================================================
# Proxmox Cloud Controller Manager and CSI Plugin
# ==============================================================================

# Wait for Kubernetes API to be ready
resource "time_sleep" "wait_for_cluster" {
  depends_on      = [talos_cluster_kubeconfig.this]
  create_duration = "60s"
}

# Secret for Cloud Controller Manager
resource "kubernetes_secret_v1" "proxmox_ccm" {
  metadata {
    name      = "proxmox-cloud-controller-manager"
    namespace = "kube-system"
  }

  data = {
    "config.yaml" = yamlencode({
      clusters = [{
        url          = "${trimsuffix(var.proxmox_api_url, "/")}/api2/json"
        insecure     = true
        token_id     = split("=", var.proxmox_api_token)[0]
        token_secret = split("=", var.proxmox_api_token)[1]
        region       = var.target_node
      }]
    })
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Secret for CSI Plugin
resource "kubernetes_secret_v1" "proxmox_csi" {
  metadata {
    name      = "proxmox-csi-plugin"
    namespace = "kube-system"
  }

  data = {
    "config.yaml" = yamlencode({
      clusters = [{
        url          = "${trimsuffix(var.proxmox_api_url, "/")}/api2/json"
        insecure     = true
        token_id     = split("=", var.proxmox_api_token)[0]
        token_secret = split("=", var.proxmox_api_token)[1]
        region       = var.target_node
      }]
    })
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Proxmox Cloud Controller Manager
resource "helm_release" "proxmox_ccm" {
  name       = "proxmox-cloud-controller-manager"
  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-cloud-controller-manager"
  namespace  = "kube-system"

  depends_on = [kubernetes_secret_v1.proxmox_ccm]
}

# Proxmox CSI Plugin
resource "helm_release" "proxmox_csi" {
  name       = "proxmox-csi-plugin"
  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-csi-plugin"
  namespace  = "kube-system"

  values = [
    yamlencode({
      storageClass = [{
        name          = var.csi_storage_class_name
        storage       = var.datastore_id
        reclaimPolicy = "Delete"
        default       = true
        ssd           = true
        backup        = true
      }]
    })
  ]

  depends_on = [
    kubernetes_secret_v1.proxmox_csi,
    helm_release.proxmox_ccm
  ]
}

# ==============================================================================
# NFS CSI Driver
# ==============================================================================

resource "helm_release" "nfs_csi" {
  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  namespace  = "kube-system"
  version    = "v4.9.0"

  depends_on = [helm_release.proxmox_csi]
}

resource "kubernetes_storage_class_v1" "nfs" {
  metadata {
    name = "nfs"
  }

  storage_provisioner = "nfs.csi.k8s.io"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  parameters = {
    server = var.nfs_server
    share  = var.nfs_share_path
  }

  depends_on = [helm_release.nfs_csi]
}

# ==============================================================================
# ArgoCD
# ==============================================================================

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  timeout    = 600

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
        # Configure AVP as config management plugin
        cmp = {
          create = true
          plugins = {
            avp = {
              allowConcurrency = true
              discover = {
                find = {
                  command = ["sh", "-c"]
                  args    = ["find . -name '*.yaml' | xargs -I {} grep -l 'avp\\.kubernetes\\.io' {} || true"]
                }
              }
              generate = {
                command = ["argocd-vault-plugin"]
                args    = ["generate", "./"]
              }
              lockRepo = false
            }
          }
        }
      }
      # AVP sidecar for repo-server
      repoServer = {
        volumes = [
          {
            name = "custom-tools"
            emptyDir = {}
          },
          {
            name = "cmp-plugin"
            configMap = {
              name = "argocd-cmp-cm"
            }
          }
        ]
        initContainers = [
          {
            name  = "download-avp"
            image = "alpine:3.18"
            command = ["sh", "-c"]
            args = [
              "wget -O /custom-tools/argocd-vault-plugin https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v1.17.0/argocd-vault-plugin_1.17.0_linux_amd64 && chmod +x /custom-tools/argocd-vault-plugin"
            ]
            volumeMounts = [
              {
                name      = "custom-tools"
                mountPath = "/custom-tools"
              }
            ]
          }
        ]
        extraContainers = [
          {
            name    = "avp"
            command = ["/var/run/argocd/argocd-cmp-server"]
            image   = "quay.io/argoproj/argocd:v2.9.3"
            securityContext = {
              runAsNonRoot = true
              runAsUser    = 999
            }
            env = [
              {
                name  = "AVP_TYPE"
                value = "vault"
              },
              {
                name  = "AVP_ADDR"
                value = "http://10.9.0.50:8200"
              },
              {
                name  = "AVP_AUTH_TYPE"
                value = "token"
              },
              {
                name = "AVP_TOKEN"
                valueFrom = {
                  secretKeyRef = {
                    name = "argocd-vault-token"
                    key  = "token"
                  }
                }
              }
            ]
            volumeMounts = [
              {
                name      = "var-files"
                mountPath = "/var/run/argocd"
              },
              {
                name      = "plugins"
                mountPath = "/home/argocd/cmp-server/plugins"
              },
              {
                name      = "cmp-plugin"
                mountPath = "/home/argocd/cmp-server/config/plugin.yaml"
                subPath   = "avp.yaml"
              },
              {
                name      = "custom-tools"
                mountPath = "/usr/local/bin/argocd-vault-plugin"
                subPath   = "argocd-vault-plugin"
              }
            ]
          }
        ]
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.argocd]
}

# AVP Token Secret
resource "kubernetes_secret_v1" "argocd_vault_token" {
  metadata {
    name      = "argocd-vault-token"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    token = var.vault_token
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

# ArgoCD Variable Substitution ConfigMap
resource "kubernetes_config_map_v1" "argocd_vars" {
  metadata {
    name      = "argocd-vars"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    DOMAIN = var.domain
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

# ArgoCD Certificate
resource "kubectl_manifest" "argocd_certificate" {
  yaml_body = <<-EOF
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: argocd-tls
      namespace: argocd
    spec:
      secretName: argocd-tls
      issuerRef:
        name: letsencrypt-production
        kind: ClusterIssuer
      dnsNames:
        - argocd.local.${var.domain}
  EOF

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.letsencrypt_production
  ]
}

# ArgoCD IngressRoute (internal only)
resource "kubectl_manifest" "argocd_ingress" {
  yaml_body = <<-EOF
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: argocd
      namespace: argocd
    spec:
      entryPoints:
        - websecure
      routes:
        - match: Host(`argocd.local.${var.domain}`)
          kind: Rule
          services:
            - name: argocd-server
              port: 80
      tls:
        secretName: argocd-tls
  EOF

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.argocd_certificate,
    helm_release.traefik_internal
  ]
}

# ==============================================================================
# MetalLB
# ==============================================================================

resource "kubernetes_namespace_v1" "metallb" {
  metadata {
    name = "metallb-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }

  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  namespace  = kubernetes_namespace_v1.metallb.metadata[0].name
  timeout    = 600
  wait       = false

  values = [
    yamlencode({
      speaker = {
        tolerations = [
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
        frr = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.metallb]
}

# Wait for MetalLB to be ready before creating IP pool
resource "time_sleep" "wait_for_metallb" {
  depends_on      = [helm_release.metallb]
  create_duration = "30s"
}

resource "kubectl_manifest" "metallb_ip_pool" {
  yaml_body = <<-EOF
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: default-pool
      namespace: metallb-system
    spec:
      addresses:
        - "10.9.0.230-10.9.0.240"
  EOF

  depends_on = [time_sleep.wait_for_metallb]
}

resource "kubectl_manifest" "metallb_l2_advertisement" {
  yaml_body = <<-EOF
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: default
      namespace: metallb-system
    spec:
      ipAddressPools:
        - default-pool
  EOF

  depends_on = [kubectl_manifest.metallb_ip_pool]
}

# ==============================================================================
# Traefik
# ==============================================================================

resource "kubernetes_namespace_v1" "traefik" {
  metadata {
    name = "traefik"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Internal Traefik (LAN only)
resource "helm_release" "traefik_internal" {
  name       = "traefik-internal"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = kubernetes_namespace_v1.traefik.metadata[0].name

  values = [
    yamlencode({
      deployment = {
        replicas = 1
      }
      ingressClass = {
        enabled        = true
        isDefaultClass = true
        name           = "traefik-internal"
      }
      ingressRoute = {
        dashboard = {
          enabled = true
        }
      }
      providers = {
        kubernetesCRD = {
          enabled              = true
          allowCrossNamespace  = true
        }
        kubernetesIngress = {
          enabled      = true
          ingressClass = "traefik-internal"
        }
      }
      ports = {
        web = {
          port        = 8000
          exposedPort = 80
          expose = {
            default = true
          }
          redirections = {
            entryPoint = {
              to     = "websecure"
              scheme = "https"
            }
          }
        }
        websecure = {
          port        = 8443
          exposedPort = 443
          expose = {
            default = true
          }
          tls = {
            enabled = true
          }
        }
      }
      service = {
        type = "LoadBalancer"
        annotations = {
          "metallb.universe.tf/loadBalancerIPs" = "10.9.0.230"
        }
      }
      serversTransport = {
        insecureSkipVerify = true
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.traefik,
    kubectl_manifest.metallb_l2_advertisement
  ]
}

# External Traefik (exposed to internet)
resource "helm_release" "traefik_external" {
  name       = "traefik-external"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = kubernetes_namespace_v1.traefik.metadata[0].name

  values = [
    yamlencode({
      deployment = {
        replicas = 1
      }
      ingressClass = {
        enabled        = true
        isDefaultClass = false
        name           = "traefik-external"
      }
      providers = {
        kubernetesCRD = {
          enabled              = true
          allowCrossNamespace  = true
          ingressClass         = "traefik-external"
        }
        kubernetesIngress = {
          enabled      = true
          ingressClass = "traefik-external"
        }
      }
      ports = {
        web = {
          port        = 8000
          exposedPort = 80
          expose = {
            default = true
          }
          redirections = {
            entryPoint = {
              to     = "websecure"
              scheme = "https"
            }
          }
        }
        websecure = {
          port        = 8443
          exposedPort = 443
          expose = {
            default = true
          }
          tls = {
            enabled = true
          }
        }
      }
      service = {
        type = "LoadBalancer"
        annotations = {
          "metallb.universe.tf/loadBalancerIPs" = "10.9.0.231"
        }
      }
      serversTransport = {
        insecureSkipVerify = true
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.traefik,
    kubectl_manifest.metallb_l2_advertisement
  ]
}

# ==============================================================================
# Cert-Manager
# ==============================================================================

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = kubernetes_namespace_v1.cert_manager.metadata[0].name
  version    = "v1.16.2"

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.cert_manager]
}

# Cloudflare API Token Secret
resource "kubernetes_secret_v1" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  depends_on = [helm_release.cert_manager]
}

# Wait for cert-manager to be ready
resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

# ClusterIssuer - Let's Encrypt Staging (for testing)
resource "kubectl_manifest" "letsencrypt_staging" {
  yaml_body = <<-EOF
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-staging
    spec:
      acme:
        server: https://acme-staging-v02.api.letsencrypt.org/directory
        email: ${var.cloudflare_email}
        privateKeySecretRef:
          name: letsencrypt-staging-key
        solvers:
          - dns01:
              cloudflare:
                apiTokenSecretRef:
                  name: cloudflare-api-token
                  key: api-token
  EOF

  depends_on = [
    time_sleep.wait_for_cert_manager,
    kubernetes_secret_v1.cloudflare_api_token
  ]
}

# ClusterIssuer - Let's Encrypt Production
resource "kubectl_manifest" "letsencrypt_production" {
  yaml_body = <<-EOF
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-production
    spec:
      acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: ${var.cloudflare_email}
        privateKeySecretRef:
          name: letsencrypt-production-key
        solvers:
          - dns01:
              cloudflare:
                apiTokenSecretRef:
                  name: cloudflare-api-token
                  key: api-token
  EOF

  depends_on = [
    time_sleep.wait_for_cert_manager,
    kubernetes_secret_v1.cloudflare_api_token
  ]
}

# ==============================================================================
# External Secrets Operator
# ==============================================================================

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }

  depends_on = [time_sleep.wait_for_cluster]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name
  timeout    = 300

  values = [
    yamlencode({
      installCRDs = true
    })
  ]

  depends_on = [kubernetes_namespace_v1.external_secrets]
}

resource "time_sleep" "wait_for_external_secrets" {
  depends_on      = [helm_release.external_secrets]
  create_duration = "30s"
}

# Vault Token Secret
resource "kubernetes_secret_v1" "vault_token" {
  metadata {
    name      = "vault-token"
    namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name
  }

  data = {
    token = var.vault_token
  }

  depends_on = [kubernetes_namespace_v1.external_secrets]
}

# ClusterSecretStore for Vault
resource "kubectl_manifest" "vault_secret_store" {
  yaml_body = <<-EOF
    apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    metadata:
      name: vault-backend
    spec:
      provider:
        vault:
          server: "http://10.9.0.50:8200"
          path: "secret"
          version: "v2"
          auth:
            tokenSecretRef:
              name: vault-token
              namespace: external-secrets
              key: token
  EOF

  depends_on = [
    time_sleep.wait_for_external_secrets,
    kubernetes_secret_v1.vault_token
  ]
}

