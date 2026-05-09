#!/bin/bash

# Rancher + Kubernetes (k3s) Single-VM Setup
# Installs k3s, Helm, nginx ingress, cert-manager, and Rancher.
# Creates prod and sandbox namespaces on the same cluster.
# Run on Ubuntu 22.04+ as root.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run as root: sudo bash rancher_setup.sh"
        exit 1
    fi
}

read -p "Enter your Rancher domain (e.g. rancher.yourdomain.com): " RANCHER_HOSTNAME
read -p "Enter your email for Let's Encrypt certs: " ACME_EMAIL
RANCHER_VERSION="2.8.4"

# ------------------------------
# Open required ports
# ------------------------------
open_ports() {
    log "Opening ports 80 and 443 in UFW..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload
    success "Ports opened"
}

# ------------------------------
# Install k3s with Flannel and default CNI disabled
# Required so Cilium can manage all networking via eBPF
# ------------------------------
install_k3s() {
    if command -v k3s &>/dev/null; then
        log "k3s already installed, skipping."
    else
        log "Installing k3s (Kubernetes) without Flannel..."
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="
            --disable traefik
            --disable-network-policy
            --flannel-backend=none
        " sh -
    fi

    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=~/.kube/config

    # Node stays NotReady until Cilium is installed — that is expected
    log "k3s installed (node will be NotReady until Cilium is up)"
}

# ------------------------------
# Install Cilium CNI
# eBPF-based networking with network policy and Hubble observability
# ------------------------------
install_cilium() {
    log "Installing Cilium..."

    # Install Cilium CLI
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    curl -sfL --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
    tar -xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
    rm cilium-linux-amd64.tar.gz

    # Install Cilium into the cluster
    cilium install \
        --set kubeProxyReplacement=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true

    log "Waiting for Cilium to be ready..."
    cilium status --wait

    log "Waiting for node to be Ready..."
    until kubectl get nodes | grep -q " Ready"; do sleep 3; done
    success "Cilium ready — $(cilium version --client 2>/dev/null | head -1)"
}

# ------------------------------
# Install Helm
# ------------------------------
install_helm() {
    if command -v helm &>/dev/null; then
        log "Helm already installed, skipping."
        return
    fi
    log "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    success "Helm installed"
}

# ------------------------------
# Install nginx ingress
# ------------------------------
install_nginx_ingress() {
    log "Installing nginx ingress controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer
    kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s
    success "nginx ingress ready"
}

# ------------------------------
# Install cert-manager
# ------------------------------
install_cert_manager() {
    log "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.14.4
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
    success "cert-manager ready"
}

# ------------------------------
# Install Rancher
# ------------------------------
install_rancher() {
    log "Installing Rancher $RANCHER_VERSION..."
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --version "$RANCHER_VERSION" \
        --set hostname="$RANCHER_HOSTNAME" \
        --set bootstrapPassword=admin \
        --set ingress.tls.source=letsEncrypt \
        --set letsEncrypt.email="$ACME_EMAIL" \
        --set letsEncrypt.ingress.class=nginx
    log "Waiting for Rancher to roll out (2-3 minutes)..."
    kubectl rollout status deployment/rancher -n cattle-system --timeout=300s
    success "Rancher deployed"
}

# ------------------------------
# Create prod and sandbox namespaces
# In Rancher UI these map to Projects for RBAC and resource quotas
# ------------------------------
setup_namespaces() {
    log "Creating prod and sandbox namespaces..."

    for NS in prod sandbox; do
        if kubectl get namespace "$NS" &>/dev/null; then
            warning "Namespace '$NS' already exists, skipping."
        else
            kubectl create namespace "$NS"
            # Label for Rancher project assignment (assign in UI after login)
            kubectl label namespace "$NS" environment="$NS"
            success "Namespace '$NS' created"
        fi
    done

    # Resource quotas — prod gets more, sandbox is capped
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: prod-quota
  namespace: prod
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "50"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: sandbox-quota
  namespace: sandbox
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "20"
EOF

    success "Resource quotas applied (prod: 8cpu/8Gi | sandbox: 2cpu/2Gi)"
}

check_root
open_ports
install_k3s
install_helm
install_cilium
install_nginx_ingress
install_cert_manager
install_rancher
setup_namespaces

echo ""
success "==========================================================="
success " Rancher:  https://$RANCHER_HOSTNAME"
success " Bootstrap password: admin  (change on first login!)"
success " Namespaces: prod, sandbox"
success "==========================================================="
echo ""
log "Next steps:"
echo "  1. Point DNS for $RANCHER_HOSTNAME → this VM's public IP"
echo "  2. Login to Rancher and change the admin password"
echo "  3. In Rancher UI: go to the local cluster → Projects/Namespaces"
echo "     and assign 'prod' and 'sandbox' namespaces to separate Projects"
echo "  4. Deploy workloads:"
echo "     kubectl apply -f your-app.yaml -n prod"
echo "     kubectl apply -f your-app.yaml -n sandbox"
