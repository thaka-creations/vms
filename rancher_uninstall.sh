#!/bin/bash

# Full teardown of Rancher + Cilium + RKE2
# Run before a fresh rancher_setup.sh install
# Run on Ubuntu 22.04+ as root

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Run as root: sudo bash rancher_uninstall.sh"
    exit 1
fi

read -rp "This will destroy the entire cluster. Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# Make RKE2 kubectl available if it exists
RKE2_BIN="/var/lib/rancher/rke2/bin"
[[ -d "$RKE2_BIN" ]] && export PATH="$RKE2_BIN:$PATH"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

# ------------------------------
# Remove Helm releases (while API is still up)
# ------------------------------
log "Removing Helm releases..."
if command -v helm &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    helm uninstall rancher       -n cattle-system  2>/dev/null && log "Rancher removed"       || warning "Rancher not found"
    helm uninstall cert-manager  -n cert-manager   2>/dev/null && log "cert-manager removed"  || warning "cert-manager not found"
    helm uninstall ingress-nginx -n ingress-nginx  2>/dev/null && log "ingress-nginx removed" || warning "ingress-nginx not found"
fi

# ------------------------------
# Uninstall Cilium cleanly (removes eBPF programs from kernel)
# Must happen before RKE2 teardown while the API is still up
# ------------------------------
log "Uninstalling Cilium..."
if command -v cilium &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    cilium uninstall --wait 2>/dev/null && log "Cilium removed" \
        || { helm uninstall cilium -n kube-system 2>/dev/null && log "Cilium helm release removed"; } \
        || warning "Cilium not found"
fi

# ------------------------------
# Force-delete stuck namespaces
# ------------------------------
log "Removing namespaces..."
for NS in cattle-system cert-manager ingress-nginx cilium-secrets prod sandbox; do
    if kubectl get namespace "$NS" &>/dev/null 2>&1; then
        kubectl get namespace "$NS" -o json \
            | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
            | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
        kubectl delete namespace "$NS" --force --grace-period=0 2>/dev/null || true
        log "Namespace $NS removed"
    fi
done

# ------------------------------
# Remove cert-manager and Cilium CRDs
# ------------------------------
log "Removing CRDs..."
kubectl get crds 2>/dev/null | grep -E "cert-manager|cilium" | awk '{print $1}' \
    | xargs kubectl delete crd --ignore-not-found 2>/dev/null || true

# ------------------------------
# Uninstall RKE2 (removes etcd, kubelet state, CNI config)
# rke2-uninstall.sh is installed by the RKE2 installer at /usr/local/bin
# ------------------------------
log "Uninstalling RKE2..."
if command -v rke2-uninstall.sh &>/dev/null; then
    rke2-uninstall.sh
    success "RKE2 uninstalled"
elif [[ -f /usr/local/bin/rke2-uninstall.sh ]]; then
    /usr/local/bin/rke2-uninstall.sh
    success "RKE2 uninstalled"
else
    warning "rke2-uninstall.sh not found — RKE2 may not be installed"
fi

# ------------------------------
# Clean up leftover binaries and config
# ------------------------------
log "Cleaning up leftover files..."
rm -f /usr/local/bin/kubectl
rm -f /usr/local/bin/cilium
rm -f /usr/local/bin/helm

# Clean up root's kube config and profile entries
rm -rf /root/.kube
sed -i '/KUBECONFIG/d' /root/.bashrc 2>/dev/null || true
sed -i '/rke2\/bin/d' /root/.bashrc 2>/dev/null || true

# Clean up the invoking user's files too
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" ]]; then
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    rm -rf "$REAL_HOME/.kube"
    sed -i '/KUBECONFIG/d' "$REAL_HOME/.bashrc" 2>/dev/null || true
    sed -i '/rke2\/bin/d' "$REAL_HOME/.bashrc" 2>/dev/null || true
fi

echo ""
success "============================================"
success " Cluster fully removed."
success " Ready for a fresh: sudo bash rancher_setup.sh"
success "============================================"
