# Bootstrap Guide

## Prerequisites

### 1. Install Tools

```bash
brew install kind clusterctl kubectl helm talosctl
```

### 2. Create Talos VM Template in Proxmox

Download the Talos nocloud image and create a VM template:

```bash
# On Proxmox host
wget https://github.com/siderolabs/talos/releases/download/v1.9.0/nocloud-amd64.raw.xz
xz -d nocloud-amd64.raw.xz

# Create VM and import disk
qm create 9000 --name talos-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 nocloud-amd64.raw nvme-zfs
qm set 9000 --scsi0 nvme-zfs:vm-9000-disk-0 --boot order=scsi0
qm template 9000
```

### 3. Create Proxmox API Token

```bash
# On Proxmox host
pveum user add capi@ryzen
pveum aclmod / -user capi@ryzen -role PVEVMAdmin
pveum user token add capi@ryzen capi-token --privsep=0
```

Save the token output — you'll need it for `PROXMOX_TOKEN`.

### 4. Set Environment Variables

```bash
export PROXMOX_URL="https://192.168.0.100:8006"
export PROXMOX_TOKEN="capi@ryzen!capi-token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
export CLOUDFLARE_EMAIL="your@email.com"
export DOMAIN="example.com"
export VAULT_TOKEN="your-vault-token"
```

## Usage

### Full Bootstrap (recommended)

```bash
./bootstrap.sh full
```

This runs the entire flow: kind cluster -> CAPI -> workload cluster -> core services -> pivot -> cleanup.

### Step-by-Step

```bash
# Step 1: Create management cluster
./bootstrap.sh management

# Step 2: Create workload cluster
./bootstrap.sh cluster

# Step 3: Install core services
./bootstrap.sh services

# Step 4: Pivot and cleanup
./bootstrap.sh pivot
```

## Recovery

If the cluster is destroyed, repeat the full bootstrap. All manifests are in git.

```bash
./bootstrap.sh full
```
