# Talos Kubernetes Cluster on Proxmox

Terraform configuration for deploying a Talos Linux Kubernetes cluster on Proxmox VE.

## Prerequisites

1. **Proxmox VE** with API access configured
2. **Talos ISO** uploaded to Proxmox storage
3. **DHCP reservations** for VM MAC addresses (see below)
4. **Terraform** >= 1.5.0

## Quick Start

```bash
# 1. Copy example variables
cp secret.tfvars.example secret.tfvars

# 2. Edit with your values
vim secret.tfvars

# 3. Initialize Terraform
terraform init

# 4. Deploy cluster
terraform apply -var-file="secret.tfvars"

# 5. Get kubeconfig
terraform output -raw kubeconfig > kubeconfig.yaml
export KUBECONFIG=$(pwd)/kubeconfig.yaml

# 6. Verify cluster
kubectl get nodes
```

## DHCP Reservations

Configure these MAC → IP mappings on your router:

### Control Plane
| VM           | MAC Address        | IP           |
|--------------|-------------------|--------------|
| talos-cp-1   | BC:24:11:00:08:00 | 192.168.0.211 |
| talos-cp-2   | BC:24:11:00:08:01 | 192.168.0.212 |
| talos-cp-3   | BC:24:11:00:08:02 | 192.168.0.213 |

### Workers
| VM             | MAC Address        | IP           |
|----------------|-------------------|--------------|
| talos-worker-1 | BC:24:11:00:09:00 | 192.168.0.214 |
| talos-worker-2 | BC:24:11:00:09:01 | 192.168.0.215 |

## Variables

See `secret.tfvars.example` for all available configuration options.

## Outputs

| Output            | Description                    |
|-------------------|--------------------------------|
| cluster_endpoint  | Kubernetes API URL             |
| control_plane_ips | Control plane node IPs         |
| worker_ips        | Worker node IPs                |
| kubeconfig        | Kubernetes admin config        |
| talosconfig       | Talos client config (JSON)     |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Proxmox VE Host                       │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐        │
│  │  talos-cp-1 │ │  talos-cp-2 │ │  talos-cp-3 │        │
│  │  (control)  │ │  (control)  │ │  (control)  │        │
│  └─────────────┘ └─────────────┘ └─────────────┘        │
│                                                          │
│  ┌───────────────────┐ ┌───────────────────┐            │
│  │   talos-worker-1  │ │   talos-worker-2  │            │
│  │     (worker)      │ │     (worker)      │            │
│  └───────────────────┘ └───────────────────┘            │
└─────────────────────────────────────────────────────────┘
```

## Destroy

```bash
terraform destroy -var-file="secret.tfvars"
```
