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
#   5. Install CCM/CSI (removes node taints), then ArgoCD (app-of-apps handles the rest)
#   6. Pivot CAPI into the workload cluster (self-managing)
#   7. Delete the kind cluster
#
# Prerequisites:
#   - kind, clusterctl, kubectl, helm, talosctl installed
#   - Proxmox API token with Administrator role
#   - Talos VM template created in Proxmox (see README.md)
#   - Environment variables set (see below)
#
# Required environment variables:
#   PROXMOX_URL          - Proxmox API URL (e.g., https://10.9.0.68:8006)
#   PROXMOX_TOKEN        - Proxmox API token (format: USER@REALM!TOKEN_ID=UUID)
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
# Helpers
# =============================================================================

# Wait until a Kubernetes API server is reachable.
wait_for_api() {
    local kubeconfig="$1"
    local max_attempts="${2:-30}"
    log "Waiting for API server to be reachable..."
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if KUBECONFIG="$kubeconfig" kubectl get --raw /healthz &>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    error "API server not reachable after $max_attempts attempts"
}

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

    # Parse token: format is USER@REALM!TOKEN_ID=SECRET
    local token_id="${PROXMOX_TOKEN%%=*}"
    local token_secret="${PROXMOX_TOKEN#*=}"

    # Secret for CAPMOX provider (management cluster)
    kubectl create secret generic "${CLUSTER_NAME}-proxmox-credentials" \
        --from-literal=token="${token_id}" \
        --from-literal=secret="${token_secret}" \
        --from-literal=url="${PROXMOX_URL}" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl label secret "${CLUSTER_NAME}-proxmox-credentials" \
        "platform.ionos.com/secret-type=proxmox-credentials" \
        --overwrite

    log "Proxmox credentials created."
}

apply_cluster_manifests() {
    log "Applying CAPI cluster manifests..."
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
        error "Timed out waiting for all nodes to be ready."
    fi

    log "Cluster provisioned. Kubeconfig at: $WORKLOAD_KUBECONFIG"
}

# =============================================================================
# Phase 4: Install Core Services + ArgoCD
# =============================================================================

install_core_services() {
    log "Installing core services on workload cluster..."

    # Install CCM/CSI first to remove node taints (required before pivot)
    install_proxmox_ccm_csi

    # Create secrets that ArgoCD apps depend on
    create_cloudflare_secret
    create_vault_secrets

    install_argocd

    log "All core services installed."
}

install_proxmox_ccm_csi() {
    # Parse Proxmox token
    local token_id="${PROXMOX_TOKEN%%=*}"
    local token_secret="${PROXMOX_TOKEN#*=}"
    # Extract Proxmox node name from the allowedNodes in cluster.yaml
    local proxmox_node
    proxmox_node=$(grep -A1 'allowedNodes' "$REPO_ROOT/cluster/cluster.yaml" | tail -1 | tr -d ' -')

    # CCM and CSI both need Proxmox credentials as Secrets on the workload cluster.
    # Format: config.yaml with clusters[] array.
    local cloud_config
    cloud_config=$(cat <<EOF
clusters:
  - url: ${PROXMOX_URL}/api2/json
    insecure: true
    token_id: "${token_id}"
    token_secret: "${token_secret}"
    region: "${proxmox_node}"
EOF
)

    log "Creating Proxmox CCM/CSI credential secrets..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic proxmox-cloud-controller-manager \
        --namespace kube-system \
        --from-literal=config.yaml="$cloud_config" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic proxmox-csi-plugin \
        --namespace kube-system \
        --from-literal=config.yaml="$cloud_config" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

    log "Installing Proxmox CCM..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" helm install proxmox-cloud-controller-manager \
        oci://ghcr.io/sergelogvinov/charts/proxmox-cloud-controller-manager \
        --namespace kube-system \
        --set "tolerations[0].key=node.cloudprovider.kubernetes.io/uninitialized" \
        --set "tolerations[0].operator=Exists" \
        --set "tolerations[0].effect=NoSchedule"

    log "Installing Proxmox CSI..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" helm install proxmox-csi-plugin \
        oci://ghcr.io/sergelogvinov/charts/proxmox-csi-plugin \
        --namespace kube-system \
        --values "$REPO_ROOT/kubernetes/infrastructure/proxmox-ccm-csi/values-csi.yaml"

    log "Waiting for CCM to initialize nodes..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait --for=condition=Ready nodes --all --timeout=300s

    # The CCM must remove the "uninitialized" taint before workloads can schedule
    # on worker nodes. condition=Ready doesn't guarantee the taint is gone.
    log "Waiting for CCM to remove uninitialized taint from workers..."
    local retries=0
    while [[ $retries -lt 60 ]]; do
        local tainted
        tainted=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes \
            -o jsonpath='{range .items[*]}{.spec.taints}{"\n"}{end}' 2>/dev/null \
            | grep -c "cloudprovider.kubernetes.io/uninitialized" || true)
        if [[ "$tainted" -eq 0 ]]; then
            log "All nodes initialized by CCM."
            break
        fi
        retries=$((retries + 1))
        if [[ $((retries % 10)) -eq 0 ]]; then
            log "Still waiting for CCM to initialize $tainted node(s)... (attempt $retries/60)"
        fi
        sleep 5
    done
    if [[ $retries -ge 60 ]]; then
        warn "Timed out waiting for CCM to remove uninitialized taint, continuing anyway..."
    fi
}

create_cloudflare_secret() {
    log "Creating Cloudflare API token secret..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create namespace cert-manager --dry-run=client -o yaml | \
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic cloudflare-api-token \
        --namespace cert-manager \
        --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -
}

create_vault_secrets() {
    log "Creating Vault token secrets..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create namespace external-secrets --dry-run=client -o yaml | \
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic vault-token \
        --namespace external-secrets \
        --from-literal=token="$VAULT_TOKEN" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create namespace argocd --dry-run=client -o yaml | \
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic argocd-vault-token \
        --namespace argocd \
        --from-literal=token="$VAULT_TOKEN" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create configmap argocd-vars \
        --namespace argocd \
        --from-literal=DOMAIN="$DOMAIN" \
        --dry-run=client -o yaml | KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -
}

install_argocd() {
    log "Installing ArgoCD..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update argo
    KUBECONFIG="$WORKLOAD_KUBECONFIG" helm install argocd argo/argo-cd \
        --namespace argocd \
        --timeout 600s \
        --values "$REPO_ROOT/kubernetes/infrastructure/argocd/values.yaml" \
        --wait

    log "Applying ArgoCD root applications..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f "$REPO_ROOT/kubernetes/infrastructure/infra-root-app.yaml"
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f "$REPO_ROOT/kubernetes/apps/apps-root-app.yaml"
}

# =============================================================================
# Phase 5: Pivot
# =============================================================================

# Fix the providerID mismatch between CAPMOX (proxmox://UUID) and the Proxmox
# CCM (proxmox://node/vmid). CAPI matches machines to nodes by providerID, so
# without this patch machines stay in "Provisioned" phase and clusterctl move
# refuses to proceed.
fix_provider_ids() {
    local kubeconfig="$1"
    log "Fixing providerID mismatch (CAPMOX UUID → CCM node/vmid)..."

    # Build mapping: ProxmoxMachine name → node providerID
    # ProxmoxMachine names match node names in the workload cluster.
    local node_map
    node_map=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}')

    # Pause all ProxmoxMachines so CAPMOX doesn't reset providerIDs mid-patch
    local pm_names
    pm_names=$(KUBECONFIG="$kubeconfig" kubectl get proxmoxmachines -o name)
    for pm in $pm_names; do
        KUBECONFIG="$kubeconfig" kubectl annotate "$pm" \
            cluster.x-k8s.io/paused=true --overwrite 2>/dev/null || true
    done

    # Patch each ProxmoxMachine + its owning Machine to the CCM-format providerID
    while IFS=$'\t' read -r node_name node_pid; do
        [[ -z "$node_name" || -z "$node_pid" ]] && continue

        # Find the Machine that references this ProxmoxMachine
        local machine_name
        machine_name=$(KUBECONFIG="$kubeconfig" kubectl get machines \
            -o jsonpath="{.items[?(@.spec.infrastructureRef.name=='$node_name')].metadata.name}" 2>/dev/null)

        if [[ -n "$machine_name" ]]; then
            KUBECONFIG="$kubeconfig" kubectl patch proxmoxmachine "$node_name" \
                --type=merge -p "{\"spec\":{\"providerID\":\"$node_pid\"}}" 2>/dev/null || true
            KUBECONFIG="$kubeconfig" kubectl patch machine "$machine_name" \
                --type=merge -p "{\"spec\":{\"providerID\":\"$node_pid\"}}" 2>/dev/null || true
        fi
    done <<< "$node_map"

    # Wait for CAPI to match machines to nodes (phase → Running)
    log "Waiting for machines to reach Running phase..."
    local retries=0
    local expected=5
    while [[ $retries -lt 60 ]]; do
        local running
        running=$(KUBECONFIG="$kubeconfig" kubectl get machines --no-headers 2>/dev/null | grep -c "Running" || true)
        if [[ "$running" -ge "$expected" ]]; then
            log "All $running machines Running."
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    # Unpause all ProxmoxMachines
    for pm in $pm_names; do
        KUBECONFIG="$kubeconfig" kubectl annotate "$pm" \
            cluster.x-k8s.io/paused- 2>/dev/null || true
    done

    log "ProviderID fix complete."
}

pivot_to_workload_cluster() {
    log "Pivoting CAPI to workload cluster..."

    # Install CAPI providers on workload cluster
    KUBECONFIG="$WORKLOAD_KUBECONFIG" clusterctl init \
        --infrastructure proxmox \
        --bootstrap talos \
        --control-plane talos \
        --ipam in-cluster

    # Wait for API server to stabilize after installing providers + cert-manager
    wait_for_api "$WORKLOAD_KUBECONFIG" 60

    log "Waiting for CAPI controllers on workload cluster..."
    for ns in capmox-system cabpt-system cacppt-system capi-system capi-ipam-in-cluster-system; do
        local attempt=0
        while [[ $attempt -lt 5 ]]; do
            if KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl wait \
                --for=condition=Available deployment --all -n "$ns" --timeout=300s 2>/dev/null; then
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -lt 5 ]]; then
                warn "Waiting for $ns (attempt $attempt/5), retrying in 10s..."
                sleep 10
            fi
        done
    done

    # Fix providerID mismatch on management cluster so clusterctl move succeeds
    fix_provider_ids "$HOME/.kube/config"

    log "Moving CAPI resources to workload cluster..."
    kubectl config use-context kind-capi-management
    clusterctl move --to-kubeconfig="$WORKLOAD_KUBECONFIG"

    # Remove pause annotations that clusterctl move leaves behind
    log "Removing pause annotations..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl annotate cluster homelab-cluster \
        cluster.x-k8s.io/paused- 2>/dev/null || true
    for pm in $(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl get proxmoxmachine -o name); do
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl annotate "$pm" \
            cluster.x-k8s.io/paused- 2>/dev/null || true
    done

    # Fix providerID mismatch on the workload cluster after the move
    fix_provider_ids "$WORKLOAD_KUBECONFIG"

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

    # Ensure the context is set (the kubeconfig from clusterctl uses a compound
    # context name like "clustername-admin@clustername")
    local ctx
    ctx=$(kubectl --kubeconfig="$HOME/.kube/config" config get-contexts -o name | head -1)
    if [[ -n "$ctx" ]]; then
        kubectl config use-context "$ctx"
    fi

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
