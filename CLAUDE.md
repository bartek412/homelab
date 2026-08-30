# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

GitOps-driven homelab using Talos Linux on Proxmox VMs, managed by Cluster API for infrastructure lifecycle and ArgoCD for application deployment, with Vault-based secret management.

## Directory Structure

- `bootstrap/` — One-time bootstrap script and kind config for cluster creation
- `cluster/` — Cluster API manifests (Cluster, TalosControlPlane, MachineDeployment, ClusterResourceSets)
- `kubernetes/infrastructure/` — ArgoCD-managed platform components (MetalLB, Traefik, cert-manager, ESO, ArgoCD)
- `kubernetes/apps/` — ArgoCD-managed application workloads

## Cluster API (CAPI)

The cluster lifecycle is managed by CAPI with these providers:
- **CAPMOX** (ionos-cloud/cluster-api-provider-proxmox) — Proxmox VM provisioning
- **CABPT** (siderolabs/cluster-api-bootstrap-provider-talos) — Talos machine config generation
- **CACPPT** (siderolabs/cluster-api-control-plane-provider-talos) — Talos control plane lifecycle

Key files:
- `cluster/cluster.yaml` — Cluster + ProxmoxCluster (VIP, IP ranges, allowed nodes)
- `cluster/control-plane.yaml` — TalosControlPlane + ProxmoxMachineTemplate (3 CP nodes)
- `cluster/workers.yaml` — MachineDeployment + ProxmoxMachineTemplate (2 workers)
- `cluster/clusterresourcesets/` — Auto-applied resources (Proxmox credentials, MetalLB namespace)

The cluster is self-managing (pivot approach): CAPI controllers run inside the workload cluster.

## Bootstrap

**Full bootstrap from zero (run from `bootstrap/`):**
```bash
export PROXMOX_URL="https://192.168.0.100:8006"
export PROXMOX_TOKEN="capi@ryzen!capi-token=..."
export CLOUDFLARE_API_TOKEN="..."
export CLOUDFLARE_EMAIL="..."
export DOMAIN="..."
export VAULT_TOKEN="..."
./bootstrap.sh full
```

See `bootstrap/README.md` for prerequisites (Talos VM template, Proxmox API token).

## Kubernetes / ArgoCD

Two-tier app-of-apps pattern:

**Infrastructure** (`kubernetes/infrastructure/`):
```
infra-root-app.yaml              # Discovers */application.yaml recursively
metallb/                          # LoadBalancer IP allocation
traefik/                          # Internal (10.9.0.230) + External (10.9.0.231) ingress
cert-manager/                     # TLS certs via Let's Encrypt + Cloudflare DNS-01
external-secrets/                 # Vault → K8s Secret sync
nfs-csi/                          # NFS storage driver
cloudnative-pg/                   # PostgreSQL operator (CNPG) for app databases
volsync/                          # Asynchronous PVC backup operator (Restic → SeaweedFS)
argocd/                           # Self-managed ArgoCD with Vault Plugin (AVP)
```

**Apps** (`kubernetes/apps/<app-name>/`):
```
apps-root-app.yaml               # Discovers */application.yaml recursively
<app-name>/
  application.yaml                # ArgoCD Application (multi-source: Helm + values + manifests)
  values.yaml                     # Helm chart overrides
  manifests/
    external-secret.yaml          # Pulls secrets from Vault
    certificate.yaml              # cert-manager Certificate
    ingress.yaml                  # Traefik IngressRoute
```

Sync waves control infrastructure ordering: MetalLB(1) → Traefik(2) → cert-manager/ESO(3) → ArgoCD(5).

## Secrets Architecture

1. **Vault** (10.9.0.50:8200) holds secrets at paths like `secret/kubernetes/<app>`
2. **ExternalSecret** CRDs sync Vault secrets → K8s Secrets in the app namespace
3. **ArgoCD Vault Plugin (AVP)** processes manifests in `manifests/` directories, substituting `<placeholder>` values using `avp.kubernetes.io/path` annotations
4. Bootstrap secrets (Proxmox token, Cloudflare token, Vault token) are created by `bootstrap.sh` from environment variables

## Networking

| Component | IP | Role |
|-----------|-----|------|
| Control Plane VIP | 192.168.0.210 | Kubernetes API endpoint |
| CP Nodes | 192.168.0.211-213 | Control plane |
| Worker Nodes | 192.168.0.214-215 | Workload nodes |
| Traefik Internal | 10.9.0.230 | LAN ingress |
| Traefik External | 10.9.0.231 | Internet-facing ingress |
| MetalLB pool | 10.9.0.230-240 | LoadBalancer IPs |
| Vault / MinIO | 10.9.0.50 | Secrets + state |

## Cluster Architecture

- 3 control plane nodes (2 CPU, 2GB RAM, 20GB disk)
- 2 worker nodes (4 CPU, 4GB RAM, 50GB disk)
- OS: Talos Linux (immutable, API-driven — no SSH)
- Proxmox node: `ryzen`, VM template ID: 9000
- StorageClasses: `proxmox` (SSD, Proxmox CSI), `nfs` (NFS CSI)
