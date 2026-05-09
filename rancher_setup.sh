#!/bin/bash

# Rancher + Kubernetes (k3s) Single-VM Setup
# Installs k3s, Helm, Cilium CNI, nginx ingress, cert-manager, and Rancher.
# Creates prod and sandbox namespaces with quotas and network isolation.
# Run on Ubuntu 22.04+ as root.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Pinned versions — update deliberately, not automatically
RANCHER_VERSION="2.8.4"
CERT_MANAGER_VERSION="v1.14.4"
INGRESS_NGINX_VERSION="4.10.1"

# ------------------------------
# Must run as root first
# ------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run as root: sudo bash rancher_setup.sh"
        exit 1
    fi
}

check_root

# Collect inputs after root check
read -rp "Enter your Rancher domain (e.g. rancher.yourdomain.com): " RANCHER_HOSTNAME
read -rp "Enter your email for Let's Encrypt certs: " ACME_EMAIL

# Generate a random bootstrap password — never use a hardcoded default
BOOTSTRAP_PASSWORD=$(openssl rand -base64 24)

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_CILIUM="amd64" ;;
    aarch64) ARCH_CILIUM="arm64" ;;
    *)       error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ------------------------------
# Persist KUBECONFIG for the invoking user (not just root)
# ------------------------------
REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
KUBECONFIG_PATH="$REAL_HOME/.kube/config"

setup_kubeconfig() {
    mkdir -p "$REAL_HOME/.kube"
    cp /etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    chown "$REAL_USER:$REAL_USER" "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"

    # Persist to shell profile so it survives session
    PROFILE="$REAL_HOME/.bashrc"
    if ! grep -q "KUBECONFIG" "$PROFILE"; then
        echo "export KUBECONFIG=$KUBECONFIG_PATH" >> "$PROFILE"
    fi
}

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
# Install k3s with Flannel disabled
# Flannel must be off so Cilium owns all pod networking
# ------------------------------
install_k3s() {
    if command -v k3s &>/dev/null; then
        log "k3s already installed, skipping."
    else
        log "Installing k3s without Flannel..."
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable-network-policy --flannel-backend=none" sh -
    fi

    setup_kubeconfig
    log "k3s installed (node NotReady until Cilium is up — expected)"
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
# Install Cilium CNI with checksum verification
# ------------------------------
install_cilium() {
    if command -v cilium &>/dev/null && cilium status &>/dev/null 2>&1; then
        log "Cilium already running, skipping."
        return
    fi

    log "Downloading Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CILIUM_TAR="cilium-linux-${ARCH_CILIUM}.tar.gz"

    curl -fsSL -o "$CILIUM_TAR" \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_TAR}"
    curl -fsSL -o "${CILIUM_TAR}.sha256sum" \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_TAR}.sha256sum"

    sha256sum --check "${CILIUM_TAR}.sha256sum"
    tar -xzf "$CILIUM_TAR" -C /usr/local/bin
    rm "$CILIUM_TAR" "${CILIUM_TAR}.sha256sum"
    success "Cilium CLI checksum verified and installed"

    log "Installing Cilium into cluster..."
    cilium install \
        --set kubeProxyReplacement=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true

    log "Waiting for Cilium (timeout 5m)..."
    cilium status --wait --wait-duration=5m

    until kubectl get nodes | grep -q " Ready"; do sleep 3; done
    success "Cilium ready — $(cilium version --client 2>/dev/null | head -1)"
}

# ------------------------------
# Install nginx ingress (pinned version)
# ------------------------------
install_nginx_ingress() {
    log "Installing nginx ingress controller $INGRESS_NGINX_VERSION..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --version "$INGRESS_NGINX_VERSION" \
        --set controller.service.type=LoadBalancer \
        --atomic \
        --timeout 120s
    success "nginx ingress ready"
}

# ------------------------------
# Install cert-manager (pinned version)
# ------------------------------
install_cert_manager() {
    log "Installing cert-manager $CERT_MANAGER_VERSION..."
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --atomic \
        --timeout 120s
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
        --set bootstrapPassword="$BOOTSTRAP_PASSWORD" \
        --set ingress.tls.source=letsEncrypt \
        --set letsEncrypt.email="$ACME_EMAIL" \
        --set letsEncrypt.ingress.class=nginx \
        --atomic \
        --timeout 300s
    success "Rancher deployed"
}

# ------------------------------
# Create namespaces with quotas, LimitRanges, and network isolation
# LimitRange is required — quotas are enforced only on pods that declare
# requests/limits, so without defaults every unconfigured pod bypasses them
# ------------------------------
setup_namespaces() {
    log "Creating prod and sandbox namespaces..."

    for NS in prod sandbox; do
        kubectl get namespace "$NS" &>/dev/null || kubectl create namespace "$NS"
        kubectl label namespace "$NS" environment="$NS" --overwrite
    done

    kubectl apply -f - <<EOF
# ── Resource Quotas ────────────────────────────────────────────────────────────
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota
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
  name: quota
  namespace: sandbox
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "20"
---
# ── LimitRanges (enforce defaults on pods that omit resource fields) ───────────
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: prod
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: sandbox
spec:
  limits:
  - type: Container
    default:
      cpu: 250m
      memory: 128Mi
    defaultRequest:
      cpu: 50m
      memory: 64Mi
---
# ── Network Policies (default deny, then allow intra-namespace only) ──────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
  - to: []
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: sandbox
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-intra-namespace
  namespace: sandbox
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
  - to: []
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
EOF

    success "Namespaces, quotas, LimitRanges, and NetworkPolicies applied"
}

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
success " Rancher:            https://$RANCHER_HOSTNAME"
success " Bootstrap password: $BOOTSTRAP_PASSWORD"
success " Namespaces:         prod, sandbox (network-isolated)"
success "==========================================================="
warning "Save the bootstrap password above — it will not be shown again."
echo ""
log "Next steps:"
echo "  1. Point DNS: $RANCHER_HOSTNAME → this VM's public IP"
echo "  2. Login to Rancher and set your permanent admin password"
echo "  3. Cluster → Projects/Namespaces → assign prod and sandbox to separate Projects"
echo "  4. source ~/.bashrc   (or open a new terminal) to pick up KUBECONFIG"
