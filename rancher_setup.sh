#!/bin/bash

# Rancher + Kubernetes (RKE2) Single-VM Setup
# Installs RKE2, Helm, Cilium CNI, Envoy Gateway (Gateway API), cert-manager,
# and Rancher. Creates prod and sandbox namespaces with quotas and network
# isolation.
#
# Traffic path:  internet → :80/:443 on the node IP (Cilium node IPAM, eBPF)
#                → Envoy proxy (envoy-gateway-system) → HTTPRoute → Service
# TLS is terminated at Envoy with Let's Encrypt certs issued by cert-manager.
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
ENVOY_GATEWAY_VERSION="v1.9.2"
GATEWAY_API_MIN_VERSION="v1.6.0"   # Envoy Gateway 1.9 is built against Gateway API v1.6
HELM_VERSION="v3.19.0"
# Rancher 2.14.x requires Kubernetes < 1.36 — the "stable" channel is already
# 1.36, so pin the minor. Bump together with RANCHER_VERSION.
RKE2_CHANNEL="v1.35"

GATEWAY_NS="envoy-gateway-system"
GATEWAY_NAME="public"

# RKE2 defaults. Cilium's pod pool is pinned to POD_CIDR and UFW trusts both
# ranges — keep them in sync or pod→node traffic (API, DNS) gets dropped.
POD_CIDR="10.42.0.0/16"
SERVICE_CIDR="10.43.0.0/16"

BOOTSTRAP_FILE="/root/.rancher_bootstrap_password"

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
        i=$((i + 1))
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
        i=$((i + 1))
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
read -rp "Trusted admin CIDR for direct kube-API access (e.g. 203.0.113.4/32, blank = none): " ADMIN_CIDR
read -rp "App hostnames served from prod/sandbox, space-separated (e.g. api.example.com, blank = none): " APP_HOSTNAMES_INPUT
read -ra APP_HOSTNAMES <<< "$APP_HOSTNAMES_INPUT"

# These go into `helm --set`, where a comma or '=' would inject extra chart
# values — validate strictly.
HOSTNAME_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?[.])+[a-zA-Z]{2,}$'
[[ "$RANCHER_HOSTNAME" =~ $HOSTNAME_RE ]] || {
    error "Invalid hostname: $RANCHER_HOSTNAME"; exit 1; }
# Hostnames are also interpolated into Gateway YAML — same strict check.
for h in ${APP_HOSTNAMES[@]+"${APP_HOSTNAMES[@]}"}; do
    [[ "$h" =~ $HOSTNAME_RE ]] || { error "Invalid app hostname: $h"; exit 1; }
    [[ "$h" != "$RANCHER_HOSTNAME" ]] || { error "App hostname must differ from the Rancher hostname."; exit 1; }
done
[[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$ ]] || {
    error "Invalid email: $ACME_EMAIL"; exit 1; }
if [[ -n "$ADMIN_CIDR" ]]; then
    [[ "$ADMIN_CIDR" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || {
        error "Invalid CIDR: $ADMIN_CIDR"; exit 1; }
    [[ "$ADMIN_CIDR" == "0.0.0.0/0" ]] && { error "0.0.0.0/0 is not a trusted CIDR."; exit 1; }
fi

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
    # Kubernetes API (6443), RKE2 supervisor (9345) and kubelet (10250) are
    # NOT opened to the internet. On a single node nothing external needs
    # them — Rancher proxies kubectl over 443 (/k8s/clusters/local), and
    # pods reach them via the pod/service CIDR rules below. Exposing them
    # publicly invites credential brute force and CVE exploitation.
    if [[ -n "$ADMIN_CIDR" ]]; then
        ufw allow from "$ADMIN_CIDR" to any port 6443 proto tcp
        log "Kube API 6443 allowed from $ADMIN_CIDR only"
    fi
    # When adding agent nodes later, allow 9345/6443 from each node's IP only:
    #   ufw allow from <node-ip> to any port 9345,6443 proto tcp
    # RKE2 pod CIDR (10.42.0.0/16) and service CIDR (10.43.0.0/16)
    ufw allow from "$POD_CIDR"
    ufw allow from "$SERVICE_CIDR"
    ufw allow to "$POD_CIDR"
    ufw allow to "$SERVICE_CIDR"
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
        # Envoy Gateway replaces the bundled ingress controllers.
        if ! grep -q "rke2-ingress-nginx" "$cfg" 2>/dev/null; then
            if grep -qE '^disable:' "$cfg"; then
                error "$cfg already has a 'disable:' list — add rke2-ingress-nginx and rke2-traefik to it, then re-run."
                exit 1
            fi
            warning "RKE2 config: disabling bundled ingress controllers — patching..."
            printf 'disable:\n  - rke2-ingress-nginx\n  - rke2-traefik\n' >> "$cfg"
            needs_restart=true
        fi
        [[ "$needs_restart" == true ]] && systemctl restart rke2-server
    else
        log "Installing RKE2..."
        mkdir -p "$RKE2_CONFIG_DIR"
        cat > "$RKE2_CONFIG_DIR/config.yaml" <<EOF
cni: none
disable-kube-proxy: true
write-kubeconfig-mode: "0600"
secrets-encryption: true
# Envoy Gateway is the only entry point; the bundled controllers would
# otherwise bind :80/:443 on the host.
disable:
  - rke2-ingress-nginx
  - rke2-traefik
EOF
        chmod 600 "$RKE2_CONFIG_DIR/config.yaml"
        # Download, then run — piping into sh executes a truncated script if
        # the connection drops. The installer verifies the RKE2 tarball's
        # sha256 itself.
        local installer
        installer=$(mktemp)
        curl -fsSL https://get.rke2.io -o "$installer"
        INSTALL_RKE2_CHANNEL="$RKE2_CHANNEL" sh "$installer"
        rm -f "$installer"
        systemctl enable rke2-server
        systemctl start rke2-server
    fi

    # Make kubectl available for the rest of this session
    export PATH="$RKE2_BIN:$PATH"
    export KUBECONFIG="$RKE2_KUBECONFIG"
    ln -sf "$RKE2_BIN/kubectl" /usr/local/bin/kubectl 2>/dev/null || true

    setup_kubeconfig
    wait_for_api

    # Disabling in config.yaml stops new deploys; an already-running bundled
    # controller must be removed explicitly (helm-controller uninstalls it).
    kubectl delete helmchart rke2-ingress-nginx rke2-traefik -n kube-system --ignore-not-found
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
    # Pinned release tarball + checksum instead of piping the installer script
    # from the helm repo's main branch into a root shell.
    log "Installing Helm ${HELM_VERSION}..."
    local tmp tarball
    tmp=$(mktemp -d)
    tarball="helm-${HELM_VERSION}-linux-${ARCH_CILIUM}.tar.gz"
    curl -fsSL -o "$tmp/$tarball"           "https://get.helm.sh/${tarball}"
    curl -fsSL -o "$tmp/$tarball.sha256sum" "https://get.helm.sh/${tarball}.sha256sum"
    (cd "$tmp" && sha256sum --check "$tarball.sha256sum")
    tar -xzf "$tmp/$tarball" -C "$tmp"
    install -m 755 "$tmp/linux-${ARCH_CILIUM}/helm" /usr/local/bin/helm
    rm -rf "$tmp"
    success "Helm ${HELM_VERSION} checksum verified and installed"
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
    local CILIUM_CLI_VERSION CILIUM_TAR tmp
    CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    [[ "$CILIUM_CLI_VERSION" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
        error "Unexpected Cilium CLI version string: $CILIUM_CLI_VERSION"; exit 1; }
    CILIUM_TAR="cilium-linux-${ARCH_CILIUM}.tar.gz"

    # Private temp dir — not the (possibly shared/writable) current directory
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/$CILIUM_TAR" \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_TAR}"
    curl -fsSL -o "$tmp/${CILIUM_TAR}.sha256sum" \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_TAR}.sha256sum"

    (cd "$tmp" && sha256sum --check "${CILIUM_TAR}.sha256sum")
    tar -xzf "$tmp/$CILIUM_TAR" -C "$tmp"
    install -m 755 "$tmp/cilium" /usr/local/bin/cilium
    rm -rf "$tmp"
    success "Cilium CLI checksum verified and installed"
}

# ------------------------------
# Pods that got an IP from a previous Cilium pool keep it until recreated.
# UFW doesn't trust those IPs, so e.g. CoreDNS can't reach the API server.
# ------------------------------
recreate_stale_pods() {
    local pod_prefix="${POD_CIDR%.*.*}."   # 10.42.0.0/16 → "10.42."
    local stale
    stale=$(kubectl get pods -A --no-headers \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.hostNetwork,IP:.status.podIP \
        | awk -v p="$pod_prefix" '$3 != "true" && $4 != "<none>" && index($4, p) != 1 {print $1, $2}')
    [[ -z "$stale" ]] && return
    log "Recreating pods with IPs outside $POD_CIDR..."
    while read -r ns name; do
        kubectl delete pod -n "$ns" "$name" --wait=false
    done <<< "$stale"
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
        local ready pool_ok=false
        ready=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null \
            | grep -c "1/1 *Running" || true)
        # Pods must get IPs from POD_CIDR — UFW only trusts that range, so
        # Cilium's default pool (10.0.0.0/8) gets pod→node traffic dropped.
        # Check both the configured pool and what each node was actually
        # allocated: a node keeps its CIDR (on its CiliumNode) across a pool
        # change.
        local pod_prefix="${POD_CIDR%.*.*}." node_cidrs
        node_cidrs=$(kubectl get ciliumnodes \
            -o jsonpath='{range .items[*]}{.spec.ipam.podCIDRs[*]}{"\n"}{end}' 2>/dev/null \
            | tr ' ' '\n' | grep -v '^$' || true)
        if helm get values cilium -n kube-system --all 2>/dev/null | grep -qF "$POD_CIDR" \
                && ! grep -qv "^${pod_prefix//./\\.}" <<< "$node_cidrs"; then
            pool_ok=true
        fi
        if [[ "$pool_ok" != true ]]; then
            warning "Cilium pod CIDR is not $POD_CIDR — reinstalling..."
            ready=0
        fi
        if [[ "${ready:-0}" -gt 0 ]]; then
            # Existing clusters predate the Envoy Gateway setup — make sure
            # node IPAM (LoadBalancer on the node IP) is on.
            if ! helm get values cilium -n kube-system --all 2>/dev/null \
                    | grep -A1 '^nodeIPAM:' | grep -q 'enabled: true'; then
                log "Enabling Cilium node IPAM for the Envoy LoadBalancer..."
                cilium upgrade --reuse-values --set nodeIPAM.enabled=true
                cilium status --wait --wait-duration=5m
            fi
            # A previous run may have fixed the pool but died before the
            # old pods were recreated.
            recreate_stale_pods
            log "Cilium already running and healthy, skipping."
            return
        fi
        warning "Cilium helm release exists but pods are unhealthy — reinstalling..."
        # cilium uninstall removes eBPF programs; helm uninstall alone does not.
        cilium uninstall --wait 2>/dev/null \
            || helm uninstall cilium -n kube-system --wait 2>/dev/null \
            || true
        kubectl delete namespace cilium-secrets --force --grace-period=0 2>/dev/null || true
        # Uninstall leaves CiliumNode objects behind; the new operator would
        # reuse their old pod CIDRs instead of allocating from POD_CIDR.
        kubectl delete ciliumnodes --all --ignore-not-found 2>/dev/null || true
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
        --set nodeIPAM.enabled=true \
        --set ipam.mode=cluster-pool \
        --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}" \
        --set ipam.operator.clusterPoolIPv4MaskSize=24 \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true

    # Before the status wait: hubble-relay needs CoreDNS, which may be one
    # of the stale pods.
    recreate_stale_pods

    log "Waiting for Cilium to be ready (timeout 5m)..."
    cilium status --wait --wait-duration=5m

    until kubectl get nodes | grep -q " Ready"; do sleep 3; done
    success "Cilium ready — $(cilium version --client 2>/dev/null | head -1)"
}

# ------------------------------
# Install Envoy Gateway (pinned version)
# Must run before cert-manager: cert-manager only detects Gateway API CRDs
# at startup.
# ------------------------------
install_envoy_gateway() {
    log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}..."

    # Let RKE2's addon jobs finish so any Gateway API CRDs it manages exist
    # before we decide who owns them.
    kubectl wait --for=condition=complete job -n kube-system \
        -l helmcharts.helm.cattle.io/chart --timeout=300s &>/dev/null \
        || warning "Some RKE2 addon jobs are still running — continuing."

    # Gateway API CRDs are cluster-wide and shared. If something else (RKE2 ≥1.37
    # bundles them) already manages a new-enough version, leave it as owner and
    # install only Envoy Gateway's own CRDs; two owners fighting over the same
    # CRDs is how they get downgraded or deleted.
    local crd="gateways.gateway.networking.k8s.io" existing managers install_gw_api
    existing=$(kubectl get crd "$crd" \
        -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)
    managers=$(kubectl get crd "$crd" -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || true)

    if [[ -z "$existing" || "$managers" == *vms-envoy-gateway* ]]; then
        log "Installing Gateway API CRDs (standard channel) with Envoy Gateway"
        install_gw_api=true
    elif [[ "$(printf '%s\n%s\n' "$GATEWAY_API_MIN_VERSION" "$existing" | sort -V | head -1)" == "$GATEWAY_API_MIN_VERSION" ]]; then
        log "Gateway API ${existing} already managed by the cluster — keeping that owner"
        install_gw_api=false
    else
        error "Cluster provides Gateway API ${existing}; Envoy Gateway ${ENVOY_GATEWAY_VERSION} needs >= ${GATEWAY_API_MIN_VERSION}."
        error "Upgrade RKE2 (which owns those CRDs) or pin an older ENVOY_GATEWAY_VERSION."
        exit 1
    fi

    # helm template | apply --server-side: the upstream-recommended way, because
    # Helm never upgrades CRDs it installed from a chart's crds/ directory.
    helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
        --version "$ENVOY_GATEWAY_VERSION" \
        --set crds.gatewayAPI.enabled="$install_gw_api" \
        --set crds.gatewayAPI.channel=standard \
        --set crds.envoyGateway.enabled=true \
        | kubectl apply --server-side --field-manager=vms-envoy-gateway -f -

    helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
        --version "$ENVOY_GATEWAY_VERSION" \
        --namespace "$GATEWAY_NS" \
        --create-namespace \
        --set crds.enabled=false \
        --atomic \
        --timeout 300s
    kubectl wait --for=condition=Available deployment/envoy-gateway \
        -n "$GATEWAY_NS" --timeout=300s

    # EnvoyProxy: how the data plane is exposed.
    # - LoadBalancer with class io.cilium/node → Cilium answers on the node IP
    #   :80/:443 (no cloud LB needed on a single VM).
    # - externalTrafficPolicy Local → real client IPs reach Envoy (logs,
    #   rate limits, IP allow-lists).
    # - No NodePorts: Cilium's eBPF datapath handles them before UFW/iptables,
    #   so they would be reachable from the internet on 30000-32767.
    kubectl apply -f - <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: public-proxy
  namespace: ${GATEWAY_NS}
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        loadBalancerClass: io.cilium/node
        externalTrafficPolicy: Local
        allocateLoadBalancerNodePorts: false
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: public-proxy
    namespace: ${GATEWAY_NS}
EOF
    success "Envoy Gateway ${ENVOY_GATEWAY_VERSION} ready"
}

# ------------------------------
# Public Gateway: one HTTP listener (ACME challenges + redirect to HTTPS) and
# one HTTPS listener per hostname, each with its own Let's Encrypt cert.
# ------------------------------
setup_gateway() {
    log "Creating public Gateway..."

    # One HTTPS listener per app hostname. Only namespaces labelled
    # gateway-access=true (prod, sandbox) may attach routes to them.
    local app_listeners="" i=0 h
    for h in ${APP_HOSTNAMES[@]+"${APP_HOSTNAMES[@]}"}; do
        i=$((i + 1))
        app_listeners+="
  - name: https-app-${i}
    protocol: HTTPS
    port: 443
    hostname: ${h}
    tls:
      mode: Terminate
      certificateRefs:
      - name: app-${i}-tls
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: \"true\""
    done

    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NS}
  annotations:
    # cert-manager creates a Certificate for every HTTPS listener below
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  gatewayClassName: envoy
  listeners:
  # Plain HTTP: only routes from this namespace may attach — the HTTPS
  # redirect and cert-manager's ACME challenge routes. Apps can't serve
  # plaintext.
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  # Rancher UI/API — only routes from cattle-system may attach.
  - name: https-rancher
    protocol: HTTPS
    port: 443
    hostname: ${RANCHER_HOSTNAME}
    tls:
      mode: Terminate
      certificateRefs:
      - name: rancher-tls
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            kubernetes.io/metadata.name: cattle-system${app_listeners}
---
# Redirect all plain-HTTP traffic to HTTPS. cert-manager's challenge routes
# match an exact path, so they take precedence over this catch-all.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: ${GATEWAY_NS}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
---
# Client-side hardening for every listener on the Gateway.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: public-client
  namespace: ${GATEWAY_NS}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GATEWAY_NAME}
  tls:
    minVersion: "1.2"
  headers:
    # Headers with underscores are a request-smuggling / header-spoofing
    # vector (X_Forwarded_For vs X-Forwarded-For) — reject them.
    withUnderscoresAction: RejectRequest
EOF

    kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" \
        -n "$GATEWAY_NS" --timeout=300s
    success "Gateway programmed — listening on the node IP :80/:443"
}

# ------------------------------
# Install cert-manager (pinned version)
# ------------------------------
install_cert_manager() {
    log "Installing cert-manager $CERT_MANAGER_VERSION..."
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
    helm repo add jetstack https://charts.jetstack.io --force-update
    # No --atomic: its rollback deletes the pods and events that explain a
    # failure. First install pulls four images plus the startupapicheck hook,
    # which can outlast a short timeout on a fresh node.
    if ! helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set config.gatewayAPI.enabled=true \
        --wait --wait-for-jobs \
        --timeout 5m; then
        error "cert-manager install failed — current state:"
        kubectl get pods,jobs -n cert-manager -o wide || true
        kubectl get events -n cert-manager --sort-by=.lastTimestamp | tail -20 || true
        kubectl logs -n cert-manager -l app.kubernetes.io/component=startupapicheck --tail=20 2>/dev/null || true
        exit 1
    fi
    # Gateway API support is detected only at startup — restart in case the
    # release already existed from before the CRDs were installed.
    kubectl rollout restart deployment cert-manager -n cert-manager
    kubectl rollout status  deployment cert-manager -n cert-manager --timeout=120s

    # HTTP-01 challenges are answered through the Gateway's plain-HTTP
    # listener. The webhook can take a few seconds after rollout to accept
    # requests, so retry.
    local i=0
    until kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: ${GATEWAY_NAME}
            namespace: ${GATEWAY_NS}
            kind: Gateway
            sectionName: http
EOF
    do
        i=$((i + 1))
        [[ $i -gt 12 ]] && { error "cert-manager webhook not accepting requests after 60s"; exit 1; }
        sleep 5
    done
    success "cert-manager ready (Gateway API enabled, ClusterIssuer 'letsencrypt')"
}

# ------------------------------
# Install Rancher
# ------------------------------
install_rancher() {
    log "Installing Rancher $RANCHER_VERSION..."
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update

    # Bootstrap password goes in a root-only values file, not --set: command
    # line arguments are readable by every local user via ps.
    local values
    values=$(mktemp)   # 0600
    printf 'bootstrapPassword: "%s"\n' "$BOOTSTRAP_PASSWORD" > "$values"

    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --create-namespace \
        --version "$RANCHER_VERSION" \
        --values "$values" \
        --set hostname="$RANCHER_HOSTNAME" \
        --set ingress.enabled=false \
        --set tls=external \
        --set agentTLSMode=system-store \
        --atomic \
        --timeout 300s
    rm -f "$values"

    # TLS terminates at Envoy (tls=external); Rancher serves plain HTTP on the
    # Service's port 80 inside the cluster. agentTLSMode=system-store: agents
    # trust the Let's Encrypt cert via the OS CA bundle.
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rancher
  namespace: cattle-system
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${GATEWAY_NS}
    sectionName: https-rancher
  hostnames:
  - ${RANCHER_HOSTNAME}
  rules:
  - backendRefs:
    - name: rancher
      port: 80
    # Rancher streams watches and websockets (kubectl, shells, logs);
    # 0s disables the per-request timeout so they aren't cut off.
    timeouts:
      request: 0s
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: Strict-Transport-Security
          value: max-age=31536000; includeSubDomains
EOF

    # Saved root-only instead of printed, so it never lands in terminal
    # scrollback, tmux logs or CI output. Delete it after first login.
    rm -f "$BOOTSTRAP_FILE"
    ( umask 077; printf '%s\n' "$BOOTSTRAP_PASSWORD" > "$BOOTSTRAP_FILE" )
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
        # gateway-access=true lets HTTPRoutes here attach to the app listeners
        kubectl label namespace "$NS" environment="$NS" gateway-access=true --overwrite
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
  # DNS only to cluster CoreDNS — "to: []" allowed port 53 to ANY host,
  # an open channel for DNS tunnelling / exfiltration.
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
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
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
---
# ── Let the Envoy proxy reach app pods ──────────────────────────────────────
# default-deny-all blocks everything from outside the namespace, including
# the gateway — without this no app behind an HTTPRoute is reachable.
# Scoped to Envoy's proxy pods only, not the whole envoy-gateway-system
# namespace (the controller never needs to call app pods).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-gateway
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${GATEWAY_NS}
      podSelector:
        matchLabels:
          app.kubernetes.io/name: envoy
          app.kubernetes.io/component: proxy
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-gateway
  namespace: sandbox
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${GATEWAY_NS}
      podSelector:
        matchLabels:
          app.kubernetes.io/name: envoy
          app.kubernetes.io/component: proxy
EOF

    success "Namespaces, quotas, LimitRanges, and NetworkPolicies applied"
}

open_ports
install_rke2
install_helm
install_cilium
wait_for_coredns
install_envoy_gateway
install_cert_manager
setup_gateway
install_rancher
setup_namespaces

echo ""
success "==========================================================="
success " Rancher:            https://$RANCHER_HOSTNAME"
success " Bootstrap password: sudo cat $BOOTSTRAP_FILE"
success " Gateway:            ${GATEWAY_NS}/${GATEWAY_NAME} (Envoy Gateway ${ENVOY_GATEWAY_VERSION})"
for idx in "${!APP_HOSTNAMES[@]}"; do
success " App listener:       https-app-$((idx + 1)) → ${APP_HOSTNAMES[$idx]}"
done
success " Namespaces:         prod, sandbox (network-isolated)"
success "==========================================================="
warning "After setting your permanent admin password: sudo shred -u $BOOTSTRAP_FILE"
echo ""
log "Next steps:"
echo "  1. Point DNS: $RANCHER_HOSTNAME ${APP_HOSTNAMES[*]+${APP_HOSTNAMES[*]} }→ this VM's public IP"
echo "     (certificates are issued once DNS resolves: kubectl get certificate -n ${GATEWAY_NS})"
echo "  2. Login to Rancher and set your permanent admin password"
echo "  3. Cluster → Projects/Namespaces → assign prod and sandbox to separate Projects"
echo "  4. source ~/.bashrc   (or open a new terminal) to pick up KUBECONFIG"
echo "  5. Expose an app — HTTPRoute in prod/sandbox attached to its listener:"
cat <<EOF
       apiVersion: gateway.networking.k8s.io/v1
       kind: HTTPRoute
       metadata: { name: my-api, namespace: prod }
       spec:
         parentRefs:
         - { name: ${GATEWAY_NAME}, namespace: ${GATEWAY_NS}, sectionName: https-app-1 }
         hostnames: [ "${APP_HOSTNAMES[0]:-api.example.com}" ]
         rules:
         - backendRefs: [ { name: my-api, port: 8080 } ]
EOF
echo "     New hostname later? Re-run with ALL app hostnames — the listener list is replaced on each run."
echo "     Pods are default-deny for egress too — add a NetworkPolicy for any outbound"
echo "     traffic an app needs (external APIs, databases)."
