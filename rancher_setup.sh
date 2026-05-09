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
# Wait for kube-apiserver to accept connections
# ------------------------------
wait_for_api() {
    log "Waiting for Kubernetes API server..."
    local i=0
    until kubectl cluster-info &>/dev/null; do
        ((i++))
        if [[ $i -gt 30 ]]; then
            error "API server not ready after 60s — check: journalctl -u k3s -n 50"
            exit 1
        fi
        sleep 2
    done
}

# ------------------------------
# Wait for CoreDNS before installing anything that needs DNS
# ------------------------------
wait_for_coredns() {
    log "Waiting for CoreDNS to be ready..."
    kubectl rollout status deployment/coredns -n kube-system --timeout=120s
    success "CoreDNS ready"
}

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
    log "Opening required ports in UFW..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 6443/tcp   # Kubernetes API (kubectl from outside the VM)
    ufw allow 10250/tcp  # kubelet API (metrics-server scrapes this)
    # k3s pod CIDR (10.42.0.0/16) and service CIDR (10.43.0.0/16) must be
    # whitelisted so pods can reach the Kubernetes API server and each other
    ufw allow from 10.42.0.0/16
    ufw allow from 10.43.0.0/16
    ufw allow to 10.42.0.0/16
    ufw allow to 10.43.0.0/16
    ufw reload
    success "Ports and k3s CIDRs opened"
}

# ------------------------------
# Install k3s with Flannel disabled
# Flannel must be off so Cilium owns all pod networking
# ------------------------------
install_k3s() {
    if command -v k3s &>/dev/null; then
        log "k3s already installed — verifying configuration..."
        # --disable-kube-proxy is required: Cilium takes over kube-proxy duties.
        # Without it, k3s's built-in proxy and Cilium's eBPF conflict, causing
        # i/o timeouts on 10.43.0.1:443 for every pod that calls the API server.
        local has_flag=false
        grep -q "disable-kube-proxy" /etc/systemd/system/k3s.service 2>/dev/null && has_flag=true
        grep -q "disable-kube-proxy" /etc/rancher/k3s/config.yaml 2>/dev/null && has_flag=true
        if [[ "$has_flag" == false ]]; then
            warning "k3s running without --disable-kube-proxy — patching and restarting..."
            mkdir -p /etc/rancher/k3s
            echo "disable-kube-proxy: true" >> /etc/rancher/k3s/config.yaml
            systemctl restart k3s
        fi
    else
        log "Installing k3s..."
        # --disable-kube-proxy: Cilium takes over kube-proxy duties (kubeProxyReplacement=true).
        # Without this, k3s's built-in proxy and Cilium's eBPF programs conflict,
        # causing i/o timeouts on 10.43.0.1:443 for every pod that calls the API.
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable-network-policy --disable-kube-proxy --flannel-backend=none --write-kubeconfig-mode=644" sh -
    fi

    setup_kubeconfig
    wait_for_api
    log "k3s ready (node NotReady until Cilium is up — expected)"
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
# Install Cilium CLI binary (idempotent)
# ------------------------------
install_cilium_cli() {
    if command -v cilium &>/dev/null; then
        log "Cilium CLI already installed ($(cilium version --client 2>/dev/null | head -1)), skipping."
        return
    fi
    log "Downloading Cilium CLI..."
    local CILIUM_CLI_VERSION CILIUM_TAR
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
}

# ------------------------------
# Install Cilium CNI into the cluster
# ------------------------------
install_cilium() {
    install_cilium_cli

    # Health check via Helm (more reliable than parsing cilium status output,
    # which returns non-zero when agents can't reach the API — a chicken-and-egg
    # situation on a broken cluster that would confuse the reinstall guard).
    if helm status cilium -n kube-system &>/dev/null; then
        local ready
        ready=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null \
            | grep -c "1/1 *Running" || true)
        if [[ "${ready:-0}" -gt 0 ]]; then
            log "Cilium already running and healthy, skipping."
            return
        fi
        warning "Cilium helm release exists but pods are unhealthy — reinstalling..."
        # cilium uninstall removes eBPF programs; helm uninstall alone does not.
        cilium uninstall --wait 2>/dev/null \
            || helm uninstall cilium -n kube-system --wait 2>/dev/null \
            || true
        kubectl delete namespace cilium-secrets --force --grace-period=0 2>/dev/null || true
        sleep 5
    fi

    # Pass the actual node IP so Cilium can reach the API server during bootstrap.
    # Without this, kube-proxy replacement can't redirect ClusterIP (10.43.0.1:443)
    # because Cilium doesn't know the real API server address.
    local NODE_IP
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    log "Installing Cilium into cluster (API server: ${NODE_IP}:6443)..."
    cilium install \
        --set k8sServiceHost="${NODE_IP}" \
        --set k8sServicePort=6443 \
        --set kubeProxyReplacement=true \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true

    log "Waiting for Cilium to be ready (timeout 5m)..."
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
        --timeout 300s
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
wait_for_coredns
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
