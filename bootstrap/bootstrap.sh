#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Homelab Cluster Bootstrap Script
#
# This script bootstraps a Talos Kubernetes cluster on Proxmox using Cluster API.
#
# Flow:
#   1. Create a temporary kind management cluster
#   2. Install CAPI providers (CAPMOX + Talos)
#   3. Create Proxmox credentials and apply cluster manifests
#   4. Wait for workload cluster to be provisioned
#   5. Install core services (CCM, CSI, MetalLB, Traefik, cert-manager, ESO, ArgoCD)
#   6. Pivot CAPI into the workload cluster (self-managing)
#   7. Delete the kind cluster
#
# Prerequisites:
#   - kind, clusterctl, kubectl, helm, talosctl installed
#   - Proxmox API token with PVEVMAdmin role
#   - Talos VM template created in Proxmox (see README.md)
#   - Environment variables set (see below)
#
# Required environment variables:
#   PROXMOX_URL          - Proxmox API URL (e.g., https://192.168.0.100:8006)
#   PROXMOX_TOKEN        - Proxmox API token (format: USER@pam!TOKEN_ID=UUID)
#   CLOUDFLARE_API_TOKEN - Cloudflare API token for DNS-01 challenge
#   CLOUDFLARE_EMAIL     - Email for Let's Encrypt
#   DOMAIN               - Primary domain (e.g., example.com)
#   VAULT_TOKEN          - HashiCorp Vault token
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="homelab-cluster"
WORKLOAD_KUBECONFIG="/tmp/${CLUSTER_NAME}-kubeconfig"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# =============================================================================
# Preflight Checks
# =============================================================================

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=()
    for cmd in kind clusterctl kubectl helm talosctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi

    local env_missing=()
    for var in PROXMOX_URL PROXMOX_TOKEN CLOUDFLARE_API_TOKEN CLOUDFLARE_EMAIL DOMAIN VAULT_TOKEN; do
        if [[ -z "${!var:-}" ]]; then
            env_missing+=("$var")
        fi
    done
    if [[ ${#env_missing[@]} -gt 0 ]]; then
        error "Missing required environment variables: ${env_missing[*]}"
    fi

    log "All prerequisites met."
}

# =============================================================================
# Phase 1: Management Cluster
# =============================================================================

create_management_cluster() {
    log "Creating kind management cluster..."
    if kind get clusters 2>/dev/null | grep -q capi-management; then
        warn "Kind cluster 'capi-management' already exists, reusing it."
    else
        kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
    fi
    kubectl config use-context kind-capi-management
}

# =============================================================================
# Phase 2: Install CAPI Providers
# =============================================================================

install_capi_providers() {
    log "Installing CAPI providers..."

    # Enable ClusterResourceSet feature
    export CLUSTER_TOPOLOGY=true
    export EXP_CLUSTER_RESOURCE_SET=true

    clusterctl init \
        --infrastructure proxmox \
        --bootstrap talos \
        --control-plane talos \
        --ipam in-cluster

    log "Waiting for CAPI controllers to be ready..."
    kubectl wait --for=condition=Available deployment --all -n capmox-system --timeout=120s
    kubectl wait --for=condition=Available deployment --all -n cabpt-system --timeout=120s
    kubectl wait --for=condition=Available deployment --all -n cacppt-system --timeout=120s
    kubectl wait --for=condition=Available deployment --all -n capi-system --timeout=120s
    kubectl wait --for=condition=Available deployment --all -n capi-ipam-in-cluster-system --timeout=120s

    log "CAPI providers ready."
}

# =============================================================================
# Phase 3: Create Cluster
# =============================================================================

create_proxmox_credentials() {
    log "Creating Proxmox credentials secret..."

    # Parse token: format is USER@pam!TOKEN_ID=SECRET
    local token_id="${PROXMOX_TOKEN%%=*}"
    local token_secret="${PROXMOX_TOKEN#*=}"
    local proxmox_api_url="${PROXMOX_URL%/}/api2/json"

    # Secret for CAPMOX provider (management cluster)
    # CAPMOX expects keys: 'token', 'secret', 'url'
    kubectl create secret generic "${CLUSTER_NAME}-proxmox-credentials" \
        --from-literal=token="${token_id}" \
        --from-literal=secret="${token_secret}" \
        --from-literal=url="${PROXMOX_URL}" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl label secret "${CLUSTER_NAME}-proxmox-credentials" \
        "platform.ionos.com/secret-type=proxmox-credentials" \
        --overwrite

    # Secret for ClusterResourceSet (applied to workload cluster for CCM/CSI)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: proxmox-crs-credentials
  namespace: default
type: addons.cluster.x-k8s.io/resource-set
stringData:
  proxmox-ccm-secret.yaml: |
    apiVersion: v1
    kind: Secret
    metadata:
      name: proxmox-cloud-controller-manager
      namespace: kube-system
    type: Opaque
    stringData:
      config.yaml: |
        clusters:
          - url: "${proxmox_api_url}"
            insecure: true
            token_id: "${token_id}"
            token_secret: "${token_secret}"
            region: "ryzen"
  proxmox-csi-secret.yaml: |
    apiVersion: v1
    kind: Secret
    metadata:
      name: proxmox-csi-plugin
      namespace: kube-system
    type: Opaque
    stringData:
      config.yaml: |
        clusters:
          - url: "${proxmox_api_url}"
            insecure: true
            token_id: "${token_id}"
            token_secret: "${token_secret}"
            region: "ryzen"
EOF

    log "Proxmox credentials created."
}

apply_cluster_manifests() {
    log "Applying CAPI cluster manifests..."
    kubectl apply -f "$REPO_ROOT/cluster/clusterresourcesets/"
    kubectl apply -f "$REPO_ROOT/cluster/cluster.yaml"
    kubectl apply -f "$REPO_ROOT/cluster/control-plane.yaml"
    kubectl apply -f "$REPO_ROOT/cluster/workers.yaml"
    log "Cluster manifests applied. Waiting for provisioning..."
}

wait_for_cluster() {
    log "Waiting for control plane to be initialized..."
    kubectl wait --for=condition=ControlPlaneInitialized cluster/"$CLUSTER_NAME" --timeout=600s

    log "Retrieving workload cluster kubeconfig..."
    clusterctl get kubeconfig "$CLUSTER_NAME" > "$WORKLOAD_KUBECONFIG"
    chmod 600 "$WORKLOAD_KUBECONFIG"

    log "Waiting for all nodes to be ready in workload cluster..."
    local retries=0
    local max_retries=120
    while [[ $retries -lt $max_retries ]]; do
        local ready_nodes
        ready_nodes=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
        if [[ "$ready_nodes" -ge 5 ]]; then
            log "All $ready_nodes nodes are ready."
            break
        fi
        retries=$((retries + 1))
        if [[ $((retries % 10)) -eq 0 ]]; then
            log "Waiting for nodes to be ready... ($ready_nodes/5 ready, attempt $retries/$max_retries)"
        fi
        sleep 5
    done

    if [[ $retries -ge $max_retries ]]; then
        warn "Timed out waiting for all nodes, but continuing anyway..."
    fi

    log "Cluster provisioned. Kubeconfig at: $WORKLOAD_KUBECONFIG"
}

# =============================================================================
# Phase 4: Install ArgoCD (app-of-apps handles the rest)
# =============================================================================

install_core_services() {
    log "Installing ArgoCD (app-of-apps pattern)..."
    export KUBECONFIG="$WORKLOAD_KUBECONFIG"

    # Create secrets that ArgoCD apps depend on
    create_ccm_csi_secrets
    create_cloudflare_secret
    create_vault_secrets

    install_argocd

    log "All core services installed via ArgoCD."
}

create_ccm_csi_secrets() {
    log "Creating Proxmox CCM/CSI secrets..."

    local token_id="${PROXMOX_TOKEN%%=*}"
    local token_secret="${PROXMOX_TOKEN#*=}"
    local proxmox_api_url="${PROXMOX_URL%/}/api2/json"

    # CCM secret
    kubectl create secret generic proxmox-cloud-controller-manager \
        --namespace kube-system \
        --from-literal=config.yaml="$(cat <<EOF
clusters:
  - url: "${proxmox_api_url}"
    insecure: true
    token_id: "${token_id}"
    token_secret: "${token_secret}"
    region: "ryzen"
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -

    # CSI secret
    kubectl create secret generic proxmox-csi-plugin \
        --namespace kube-system \
        --from-literal=config.yaml="$(cat <<EOF
clusters:
  - url: "${proxmox_api_url}"
    insecure: true
    token_id: "${token_id}"
    token_secret: "${token_secret}"
    region: "ryzen"
EOF
)" \
        --dry-run=client -o yaml | kubectl apply -f -
}

create_cloudflare_secret() {
    log "Creating Cloudflare API token secret..."
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic cloudflare-api-token \
        --namespace cert-manager \
        --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
}

create_vault_secrets() {
    log "Creating Vault token secrets..."
    kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic vault-token \
        --namespace external-secrets \
        --from-literal=token="$VAULT_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic argocd-vault-token \
        --namespace argocd \
        --from-literal=token="$VAULT_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create configmap argocd-vars \
        --namespace argocd \
        --from-literal=DOMAIN="$DOMAIN" \
        --dry-run=client -o yaml | kubectl apply -f -
}

install_argocd() {
    log "Installing ArgoCD..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update argo
    helm install argocd argo/argo-cd \
        --namespace argocd \
        --timeout 600s \
        --values "$REPO_ROOT/kubernetes/infrastructure/argocd/values.yaml" \
        --wait

    log "Applying ArgoCD root applications..."
    kubectl apply -f "$REPO_ROOT/kubernetes/infrastructure/infra-root-app.yaml"
    kubectl apply -f "$REPO_ROOT/kubernetes/apps/apps-root-app.yaml"
}

# =============================================================================
# Phase 5: Pivot
# =============================================================================

pivot_to_workload_cluster() {
    log "Pivoting CAPI to workload cluster..."

    # Install CAPI providers on workload cluster
    KUBECONFIG="$WORKLOAD_KUBECONFIG" clusterctl init \
        --infrastructure proxmox \
        --bootstrap talos \
        --control-plane talos \
        --ipam in-cluster \
        --wait-providers-timeout 600

    log "Waiting for CAPI controllers on workload cluster..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
        --for=condition=Available deployment --all -n capmox-system --timeout=300s
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
        --for=condition=Available deployment --all -n cabpt-system --timeout=300s
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
        --for=condition=Available deployment --all -n cacppt-system --timeout=300s
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
        --for=condition=Available deployment --all -n capi-system --timeout=300s
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
        --for=condition=Available deployment --all -n capi-ipam-in-cluster-system --timeout=300s

    # Switch back to management cluster for the move
    unset KUBECONFIG
    kubectl config use-context kind-capi-management

    log "Moving CAPI resources to workload cluster..."
    clusterctl move --to-kubeconfig="$WORKLOAD_KUBECONFIG"

    log "Pivot complete. Verifying..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get clusters
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get machines
}

cleanup_management_cluster() {
    log "Deleting kind management cluster..."
    kind delete cluster --name capi-management
    log "Kind cluster deleted."
}

# =============================================================================
# Phase 6: Finalize
# =============================================================================

finalize() {
    log "Copying workload kubeconfig to ~/.kube/config..."
    mkdir -p "$HOME/.kube"
    cp "$WORKLOAD_KUBECONFIG" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"

    echo ""
    log "========================================="
    log "  Cluster bootstrap complete!"
    log "========================================="
    echo ""
    log "Kubeconfig: ~/.kube/config"
    log "ArgoCD UI:  https://argocd.local.${DOMAIN}"
    log ""
    log "Get ArgoCD admin password:"
    log "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    log ""
    log "Verify cluster:"
    log "  kubectl get nodes"
    log "  kubectl get machines"
    log "  clusterctl describe cluster ${CLUSTER_NAME}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  full        Run full bootstrap (default)"
    echo "  management  Create management cluster + install CAPI only"
    echo "  cluster     Create workload cluster (requires management cluster)"
    echo "  services    Install core services (requires workload cluster)"
    echo "  pivot       Pivot CAPI to workload cluster"
    echo "  cleanup     Delete kind management cluster"
    echo ""
}

main() {
    local command="${1:-full}"

    check_prerequisites

    case "$command" in
        full)
            create_management_cluster
            install_capi_providers
            create_proxmox_credentials
            apply_cluster_manifests
            wait_for_cluster
            install_core_services
            pivot_to_workload_cluster
            cleanup_management_cluster
            finalize
            ;;
        management)
            create_management_cluster
            install_capi_providers
            ;;
        cluster)
            create_proxmox_credentials
            apply_cluster_manifests
            wait_for_cluster
            ;;
        services)
            export KUBECONFIG="$WORKLOAD_KUBECONFIG"
            install_core_services
            ;;
        pivot)
            pivot_to_workload_cluster
            cleanup_management_cluster
            finalize
            ;;
        cleanup)
            cleanup_management_cluster
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
