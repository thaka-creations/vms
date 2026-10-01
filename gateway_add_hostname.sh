#!/bin/bash
# ==============================================================================
# Add app hostnames to the public Gateway created by rancher_setup.sh
#
# Appends one HTTPS listener per hostname (https-app-N, cert app-N-tls) and
# touches nothing else: no Helm upgrades, no restarts, existing listeners and
# their certificates keep their names. Hostnames already on the Gateway are
# skipped, so re-running is safe.
#
# Usage (on the server):
#   bash gateway_add_hostname.sh offline.tafa.co.ke [more.example.com ...]
#   bash gateway_add_hostname.sh --dry-run offline.tafa.co.ke   # validate only
#
# Uses $KUBECONFIG, else ~/.kube/config (rancher_setup.sh writes one for the
# user who ran it), else the RKE2 admin kubeconfig (root only).
#
# Then point each hostname's DNS A record at this VM; cert-manager issues the
# Let's Encrypt certificate once it resolves.
#
# rancher_setup.sh rebuilds the listener list from its prompt, so if you ever
# re-run it, include these hostnames there too (it prints the current list).
# ==============================================================================

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

# Must match rancher_setup.sh
GATEWAY_NS="envoy-gateway-system"
GATEWAY_NAME="public"
RKE2_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi
if [[ $# -eq 0 ]]; then
    error "Usage: bash $0 [--dry-run] <hostname> [...]"
    exit 1
fi

if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -r "$HOME/.kube/config" ]]; then
        export KUBECONFIG="$HOME/.kube/config"
    else
        export KUBECONFIG="$RKE2_KUBECONFIG"
    fi
fi
export PATH="$PATH:/var/lib/rancher/rke2/bin"

# Hostnames are interpolated into the listener JSON — same strict check as
# rancher_setup.sh.
HOSTNAME_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?[.])+[a-zA-Z]{2,}$'
for h in "$@"; do
    [[ "$h" =~ $HOSTNAME_RE ]] || { error "Invalid hostname: $h"; exit 1; }
done

kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" &>/dev/null || {
    error "Gateway $GATEWAY_NS/$GATEWAY_NAME not found — run rancher_setup.sh first."
    exit 1
}

# One "<name> <hostname>" line per listener.
listeners() {
    kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" \
        -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.hostname}{"\n"}{end}'
}

added=()
for h in "$@"; do
    current=$(listeners)

    if awk -v h="$h" '$2 == h { found = 1 } END { exit !found }' <<<"$current"; then
        name=$(awk -v h="$h" '$2 == h { print $1 }' <<<"$current")
        warning "$h is already on the Gateway ($name) — skipping."
        continue
    fi

    # Next free index after the highest https-app-N, so gaps are never reused
    # and an existing listener's certificate is never repointed.
    n=$(awk '$1 ~ /^https-app-[0-9]+$/ { sub("https-app-", "", $1); if ($1 + 0 > max) max = $1 + 0 }
             END { print max + 1 }' <<<"$current")

    log "Adding https-app-${n} → ${h} (certificate app-${n}-tls)..."
    dry=()
    [[ $DRY_RUN -eq 1 ]] && dry=(--dry-run=server)
    # JSON patch "add .../-" appends, leaving every other listener untouched.
    kubectl patch gateway "$GATEWAY_NAME" -n "$GATEWAY_NS" --type=json -p "[{
      \"op\": \"add\",
      \"path\": \"/spec/listeners/-\",
      \"value\": {
        \"name\": \"https-app-${n}\",
        \"protocol\": \"HTTPS\",
        \"port\": 443,
        \"hostname\": \"${h}\",
        \"tls\": {
          \"mode\": \"Terminate\",
          \"certificateRefs\": [{ \"name\": \"app-${n}-tls\" }]
        },
        \"allowedRoutes\": {
          \"namespaces\": {
            \"from\": \"Selector\",
            \"selector\": { \"matchLabels\": { \"gateway-access\": \"true\" } }
          }
        }
      }
    }]" "${dry[@]+"${dry[@]}"}" >/dev/null
    added+=("$h")
done

if [[ ${#added[@]} -eq 0 ]]; then
    success "Nothing to add."
    exit 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
    success "Dry run: the API server accepted the listener(s) for ${added[*]}; nothing was changed."
    exit 0
fi

kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" -n "$GATEWAY_NS" --timeout=120s >/dev/null
success "Gateway programmed with: ${added[*]}"

# The Gateway's cert-manager annotation creates one Certificate per listener;
# it can take a few seconds to appear.
sleep 5
kubectl get certificate -n "$GATEWAY_NS"

NODE_IP=$(hostname -I | awk '{print $1}')
echo ""
log "Next steps:"
echo "  1. DNS A record for each new hostname → ${NODE_IP}"
echo "     (certificates issue once it resolves: kubectl get certificate -n ${GATEWAY_NS} -w)"
echo "  2. Attach an HTTPRoute from prod/sandbox with that hostname — no sectionName needed."
echo "  3. If you ever re-run rancher_setup.sh, give it ALL app hostnames, in this order:"
echo "     $(listeners | awk '$1 ~ /^https-app-/ { print $2 }' | xargs)"
