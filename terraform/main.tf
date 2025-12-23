locals {
  # Computed IP addresses
  cp_ips     = [for i in range(var.cp_count) : "${var.ip_prefix}.${var.start_ip + i}"]
  worker_ips = [for i in range(var.worker_count) : "${var.ip_prefix}.${var.start_ip + var.cp_count + i}"]

  # First control plane is the cluster endpoint
  cluster_endpoint = "https://${local.cp_ips[0]}:6443"

  # Talos installer image
  #currently hardcoded due to provider bug
  # talos_installer = "ghcr.io/siderolabs/installer:${var.talos_version}"

  # VM ID ranges
  cp_vm_id_start     = 800
  worker_vm_id_start = 900

  # MAC address prefixes
  cp_mac_prefix     = "BC:24:11:00:08:0"
  worker_mac_prefix = "BC:24:11:00:09:0"
}


resource "talos_machine_secrets" "this" {}

# ==============================================================================
# Talos Machine Configuration - Control Plane
# ==============================================================================

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "controlplane"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = "ghcr.io/siderolabs/installer:v1.12.0"
        }
      }
    })
  ]
}

# ==============================================================================
# Talos Machine Configuration - Worker
# ==============================================================================

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  cluster_endpoint = local.cluster_endpoint
  machine_type     = "worker"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = "ghcr.io/siderolabs/installer:v1.12.0"
        }
      }
    })
  ]
}

# ==============================================================================
# Proxmox VMs - Control Plane
# ==============================================================================

resource "proxmox_virtual_environment_vm" "control_plane" {
  count      = var.cp_count
  name       = "talos-cp-${count.index + 1}"
  node_name  = var.target_node
  vm_id      = local.cp_vm_id_start + count.index
  boot_order = ["virtio0", "ide2"]

  cpu {
    cores = var.cp_cores
    type  = "host"
  }

  memory {
    dedicated = var.cp_memory
  }

  agent {
    enabled = false
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "${local.cp_mac_prefix}${count.index}"
  }

  cdrom {
    file_id   = var.talos_iso_id
    interface = "ide2"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.cp_disk_size
    file_format  = "raw"
  }

  operating_system {
    type = "l26"
  }
}

# ==============================================================================
# Proxmox VMs - Workers
# ==============================================================================

resource "proxmox_virtual_environment_vm" "worker" {
  count      = var.worker_count
  name       = "talos-worker-${count.index + 1}"
  node_name  = var.target_node
  vm_id      = local.worker_vm_id_start + count.index
  boot_order = ["virtio0", "ide2"]

  cpu {
    cores = var.worker_cores
    type  = "host"
  }

  memory {
    dedicated = var.worker_memory
  }

  agent {
    enabled = false
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "${local.worker_mac_prefix}${count.index}"
  }

  cdrom {
    file_id   = var.talos_iso_id
    interface = "ide2"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = var.worker_disk_size
    file_format  = "raw"
  }

  operating_system {
    type = "l26"
  }
}

# ==============================================================================
# Talos Configuration Apply - Control Plane
# ==============================================================================

resource "talos_machine_configuration_apply" "controlplane" {
  depends_on                  = [proxmox_virtual_environment_vm.control_plane]
  count                       = var.cp_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.cp_ips[count.index]
  endpoint                    = local.cp_ips[count.index]
}

# ==============================================================================
# Talos Bootstrap
# ==============================================================================

resource "talos_machine_bootstrap" "this" {
  depends_on           = [talos_machine_configuration_apply.controlplane]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
}

# ==============================================================================
# Talos Configuration Apply - Workers
# ==============================================================================

resource "talos_machine_configuration_apply" "worker" {
  depends_on                  = [talos_machine_bootstrap.this]
  count                       = var.worker_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = local.worker_ips[count.index]
  endpoint                    = local.worker_ips[count.index]
}

# ==============================================================================
# Talos Kubeconfig
# ==============================================================================

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this, talos_machine_configuration_apply.worker]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ips[0]
  endpoint             = local.cp_ips[0]
}