#!/bin/bash

# Rancher + Kubernetes (RKE2) Single-VM Setup
# Installs RKE2, Helm, Cilium CNI, nginx ingress, cert-manager, and Rancher.
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
RANCHER_VERSION="2.14.1"
CERT_MANAGER_VERSION="v1.20.2"
INGRESS_NGINX_VERSION="4.15.1"

RKE2_CONFIG_DIR="/etc/rancher/rke2"
RKE2_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
RKE2_BIN="/var/lib/rancher/rke2/bin"

# ------------------------------
# Wait for kube-apiserver to accept connections
# ------------------------------
wait_for_api() {
    log "Waiting for Kubernetes API server..."
    local i=0
    until kubectl cluster-info &>/dev/null; do
        ((i++))
        if [[ $i -gt 30 ]]; then
            error "API server not ready after 60s — check: journalctl -u rke2-server -n 50"
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
    local i=0
    until kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null \
            | grep -q "1/1.*Running"; do
        ((i++))
        if [[ $i -gt 24 ]]; then
            error "CoreDNS not ready after 2m — check: kubectl describe pods -n kube-system -l k8s-app=kube-dns"
            exit 1
        fi
        sleep 5
    done
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
    cp "$RKE2_KUBECONFIG" "$KUBECONFIG_PATH"
    chmod 600 "$KUBECONFIG_PATH"
    chown "$REAL_USER:$REAL_USER" "$KUBECONFIG_PATH"
    export KUBECONFIG="$KUBECONFIG_PATH"

    local PROFILE="$REAL_HOME/.bashrc"
    if ! grep -q "KUBECONFIG" "$PROFILE"; then
        echo "export KUBECONFIG=$KUBECONFIG_PATH" >> "$PROFILE"
    fi
    if ! grep -q "$RKE2_BIN" "$PROFILE"; then
        echo "export PATH=\"$RKE2_BIN:\$PATH\"" >> "$PROFILE"
    fi
}

# ------------------------------
# Open required ports
# ------------------------------
open_ports() {
    log "Opening required ports in UFW..."

    # Detect the active SSH port so UFW never locks us out.
    # Reads from sshd -T (runtime config) which reflects what sshd is
    # actually using, regardless of which config file set it.
    local SSH_PORT
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | head -1)
    SSH_PORT=${SSH_PORT:-22}
    log "SSH port detected as $SSH_PORT — keeping it open"
    ufw allow "${SSH_PORT}/tcp"

    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 6443/tcp   # Kubernetes API
    ufw allow 9345/tcp   # RKE2 supervisor API (needed when adding agent nodes)
    ufw allow 10250/tcp  # kubelet API (metrics-server)
    # RKE2 pod CIDR (10.42.0.0/16) and service CIDR (10.43.0.0/16)
    ufw allow from 10.42.0.0/16
    ufw allow from 10.43.0.0/16
    ufw allow to 10.42.0.0/16
    ufw allow to 10.43.0.0/16
    ufw --force enable
    ufw reload
    success "Ports and RKE2 CIDRs opened (SSH on ${SSH_PORT})"
}

# ------------------------------
# Install RKE2 server
# cni: none        — Cilium owns all pod networking
# disable-kube-proxy — Cilium takes over via eBPF (kubeProxyReplacement=true);
#                      both running causes ClusterIP i/o timeouts
# disable rke2-ingress-nginx — we install our own nginx via Helm
# ------------------------------
install_rke2() {
    if command -v rke2 &>/dev/null; then
        log "RKE2 already installed — verifying configuration..."
        local cfg="$RKE2_CONFIG_DIR/config.yaml"
        local needs_restart=false
        if ! grep -q "cni: none" "$cfg" 2>/dev/null; then
            warning "RKE2 config missing 'cni: none' — patching..."
            echo "cni: none" >> "$cfg"
            needs_restart=true
        fi
        if ! grep -q "disable-kube-proxy" "$cfg" 2>/dev/null; then
            warning "RKE2 config missing 'disable-kube-proxy' — patching..."
            echo "disable-kube-proxy: true" >> "$cfg"
            needs_restart=true
        fi
        [[ "$needs_restart" == true ]] && systemctl restart rke2-server
    else
        log "Installing RKE2..."
        mkdir -p "$RKE2_CONFIG_DIR"
        cat > "$RKE2_CONFIG_DIR/config.yaml" <<EOF
cni: none
disable-kube-proxy: true
EOF
        curl -sfL https://get.rke2.io | sh -
        systemctl enable rke2-server
        systemctl start rke2-server
    fi

    # Make kubectl available for the rest of this session
    export PATH="$RKE2_BIN:$PATH"
    export KUBECONFIG="$RKE2_KUBECONFIG"
    ln -sf "$RKE2_BIN/kubectl" /usr/local/bin/kubectl 2>/dev/null || true

    setup_kubeconfig
    wait_for_api
    log "RKE2 ready (node NotReady until Cilium is up — expected)"
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
    # Filter for IPv4 only — dual-stack nodes expose both IPv4 and IPv6 InternalIPs
    # and the jsonpath returns them space-separated; passing both is invalid.
    local NODE_IP
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

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
install_rke2
install_helm
install_cilium
wait_for_coredns
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
