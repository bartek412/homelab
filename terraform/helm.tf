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

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.argocd]
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
          ingressClass         = "traefik-internal"
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
