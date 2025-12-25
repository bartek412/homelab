# ==============================================================================
# Variables - Proxmox Connection
# ==============================================================================

variable "proxmox_api_url" {
  type        = string
  description = "Proxmox API URL (e.g., https://192.168.0.100:8006/)"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token (format: USER@pam!TOKEN_ID=UUID)"
}

variable "target_node" {
  type        = string
  default     = "pve"
  description = "Proxmox node name where VMs will be created"
}

variable "datastore_id" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage for VM disks"
}

variable "talos_iso_id" {
  type        = string
  default     = "local:iso/talos-nocloud-amd64.iso"
  description = "Talos ISO file ID in Proxmox storage"
}

# ==============================================================================
# Variables - Talos Configuration
# ==============================================================================

variable "cluster_name" {
  type        = string
  default     = "homelab-cluster"
  description = "Kubernetes cluster name"
}

variable "talos_version" {
  type        = string
  default     = "v1.12.0"
  description = "Talos Linux version"
}

variable "install_disk" {
  type        = string
  default     = "/dev/vda"
  description = "Disk device for Talos installation (currently hardcoded due to provider bug)"
}

variable "csi_storage_class_name" {
  type        = string
  default     = "proxmox"
  description = "Name of the StorageClass created by Proxmox CSI"
}

variable "nfs_server" {
  type        = string
  default     = "192.168.0.78"
  description = "NFS server IP address"
}

variable "nfs_share_path" {
  type        = string
  default     = "/mnt/user/kubernetes-nfs"
  description = "NFS export path on the server"
}

# ==============================================================================
# Variables - Network
# ==============================================================================

variable "ip_prefix" {
  type        = string
  default     = "192.168.0"
  description = "IP address prefix (first 3 octets)"

  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.ip_prefix))
    error_message = "IP prefix must be in format X.X.X (e.g., 192.168.0)"
  }
}

variable "start_ip" {
  type        = number
  default     = 211
  description = "Starting IP (last octet) for first control plane node"

  validation {
    condition     = var.start_ip >= 1 && var.start_ip <= 254
    error_message = "Start IP must be between 1 and 254"
  }
}

# ==============================================================================
# Variables - Control Plane VMs
# ==============================================================================

variable "cp_count" {
  type        = number
  default     = 3
  description = "Number of control plane nodes"

  validation {
    condition     = var.cp_count >= 1 && var.cp_count <= 5
    error_message = "Control plane count must be between 1 and 5"
  }
}

variable "cp_memory" {
  type        = number
  default     = 2048
  description = "Memory for control plane VMs (MB)"
}

variable "cp_cores" {
  type        = number
  default     = 2
  description = "CPU cores for control plane VMs"
}

variable "cp_disk_size" {
  type        = number
  default     = 20
  description = "Disk size for control plane VMs (GB)"
}

# ==============================================================================
# Variables - Worker VMs
# ==============================================================================

variable "worker_count" {
  type        = number
  default     = 2
  description = "Number of worker nodes"

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 10
    error_message = "Worker count must be between 0 and 10"
  }
}

variable "worker_memory" {
  type        = number
  default     = 4096
  description = "Memory for worker VMs (MB)"
}

variable "worker_cores" {
  type        = number
  default     = 4
  description = "CPU cores for worker VMs"
}

variable "worker_disk_size" {
  type        = number
  default     = 50
  description = "Disk size for worker VMs (GB)"
}

# ==============================================================================
# Variables - Cert-Manager / Cloudflare
# ==============================================================================

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read permissions"
}

variable "cloudflare_email" {
  type        = string
  description = "Email address for Let's Encrypt certificate notifications"
}

variable "domain" {
  type        = string
  description = "Primary domain for certificates (e.g., example.com)"
}

# ==============================================================================
# Variables - External Secrets / Vault
# ==============================================================================

variable "vault_token" {
  type        = string
  sensitive   = true
  description = "HashiCorp Vault token for External Secrets Operator"
}