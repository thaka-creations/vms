#!/bin/bash

# Full teardown of Rancher + Cilium + k3s
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

# ------------------------------
# Remove Helm releases
# ------------------------------
log "Removing Helm releases..."
if command -v helm &>/dev/null; then
    helm uninstall rancher      -n cattle-system    2>/dev/null && log "Rancher removed"       || warning "Rancher not found"
    helm uninstall cert-manager -n cert-manager     2>/dev/null && log "cert-manager removed"  || warning "cert-manager not found"
    helm uninstall ingress-nginx -n ingress-nginx   2>/dev/null && log "ingress-nginx removed" || warning "ingress-nginx not found"
    helm uninstall cilium       -n kube-system      2>/dev/null && log "Cilium helm removed"   || warning "Cilium helm release not found"
fi

# ------------------------------
# Remove Cilium CRDs and resources
# ------------------------------
log "Removing Cilium resources..."
kubectl delete daemonset cilium cilium-envoy -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete deployment cilium-operator hubble-relay hubble-ui -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole cilium cilium-operator --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding cilium cilium-operator --ignore-not-found 2>/dev/null || true
kubectl delete configmap cilium-config -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete secret cilium-ca -n kube-system --ignore-not-found 2>/dev/null || true
kubectl get crds 2>/dev/null | grep cilium | awk '{print $1}' | xargs kubectl delete crd --ignore-not-found 2>/dev/null || true

# ------------------------------
# Force-delete stuck namespaces
# ------------------------------
log "Removing namespaces..."
for NS in cilium-secrets cilium-test cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2 \
          cattle-system cert-manager ingress-nginx prod sandbox; do
    if kubectl get namespace "$NS" &>/dev/null; then
        # Strip finalizers so terminating namespaces don't hang
        kubectl get namespace "$NS" -o json \
            | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
            | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
        kubectl delete namespace "$NS" --force --grace-period=0 2>/dev/null || true
        log "Namespace $NS removed"
    fi
done

# ------------------------------
# Remove cert-manager CRDs
# ------------------------------
log "Removing cert-manager CRDs..."
kubectl get crds 2>/dev/null | grep cert-manager | awk '{print $1}' | xargs kubectl delete crd --ignore-not-found 2>/dev/null || true

# ------------------------------
# Uninstall k3s (removes everything: etcd, kubelet, CNI state)
# ------------------------------
log "Uninstalling k3s..."
if command -v k3s-uninstall.sh &>/dev/null; then
    k3s-uninstall.sh
    success "k3s uninstalled"
else
    warning "k3s-uninstall.sh not found — k3s may not be installed"
fi

# ------------------------------
# Clean up leftover files
# ------------------------------
log "Cleaning up leftover files..."
rm -rf ~/.kube
rm -f /usr/local/bin/cilium
rm -f /usr/local/bin/helm
sed -i '/KUBECONFIG/d' ~/.bashrc 2>/dev/null || true

# Clean up real user's files too
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" ]]; then
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    rm -rf "$REAL_HOME/.kube"
    sed -i '/KUBECONFIG/d' "$REAL_HOME/.bashrc" 2>/dev/null || true
fi

echo ""
success "============================================"
success " Cluster fully removed."
success " Ready for a fresh: sudo bash rancher_setup.sh"
success "============================================"
