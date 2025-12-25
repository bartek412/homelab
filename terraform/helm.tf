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
