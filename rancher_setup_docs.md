# rancher_setup.sh — Documentation

## Overview

`rancher_setup.sh` turns a single Ubuntu VM into a Kubernetes environment. It installs RKE2 (Kubernetes), Cilium (CNI, kube-proxy replacement, load balancer), Envoy Gateway (Gateway API ingress), cert-manager and Rancher. It then creates isolated `prod` and `sandbox` namespaces with resource quotas and network policies.

## Architecture

```
                      internet
                         │  :80 / :443 on the node IP
┌────────────────────────▼────────────────────────────────┐
│  Cilium (eBPF) — LoadBalancer via node IPAM             │
│                         │                               │
│  ┌──────────────────────▼──────────────────────────┐    │
│  │ Envoy proxy (envoy-gateway-system)              │    │
│  │ Gateway "public": TLS termination, HTTP→HTTPS   │    │
│  └───────┬─────────────────┬───────────────┬───────┘    │
│          │ HTTPRoute       │ HTTPRoute     │ HTTPRoute  │
│  ┌───────▼───────┐ ┌───────▼───────┐ ┌─────▼─────────┐  │
│  │ Rancher       │ │ prod          │ │ sandbox       │  │
│  │ cattle-system │ │ 8cpu/8Gi, 50  │ │ 2cpu/2Gi, 20  │  │
│  │               │ │ default-deny  │ │ default-deny  │  │
│  └───────────────┘ └───────────────┘ └───────────────┘  │
│  cert-manager (Let's Encrypt, HTTP-01 via the Gateway)  │
│  RKE2 (Kubernetes 1.35)                                 │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

| Requirement | Minimum |
|---|---|
| OS | Ubuntu 22.04+ |
| CPU | 4 cores |
| RAM | 8 GB |
| Disk | 40 GB |
| Ports | 80, 443 open inbound |
| Domain | A record for Rancher and each app hostname pointing to the VM's public IP |

> Run the hardening scripts (`ubuntu_hardening_v1.sh`, `ubuntu_setup_logging.sh`) before this script.

## Pinned Versions

| Component | Version | Notes |
|---|---|---|
| RKE2 | `v1.35` channel | Rancher 2.14.x needs Kubernetes < 1.36; RKE2 `stable` is already 1.36 |
| Rancher | 2.14.1 | |
| Envoy Gateway | v1.9.2 | Needs Gateway API ≥ v1.6 |
| cert-manager | v1.20.2 | Gateway API support enabled |
| Helm | v3.19.0 | Release tarball, checksum verified |
| Cilium CLI | latest stable (fetched at runtime, checksum verified) | |

Why not ingress-nginx: the Kubernetes project retired it in March 2026, so it no longer gets security fixes, and RKE2 1.37 removes it. RKE2's bundled ingress controllers (`rke2-ingress-nginx`, `rke2-traefik`) are disabled, so Envoy is the only entry point.

## Usage

```bash
sudo bash rancher_setup.sh
```

The script prompts for four inputs, then runs unattended:

```
Enter your Rancher domain (e.g. rancher.yourdomain.com): rancher.example.com
Enter your email for Let's Encrypt certs: you@example.com
Trusted admin CIDR for direct kube-API access (e.g. 203.0.113.4/32, blank = none):
App hostnames served from prod/sandbox, space-separated (e.g. api.example.com, blank = none): api.example.com app.example.com
```

Every input is validated. Hostnames and the email go into Helm values and YAML, so anything malformed is rejected.

Estimated runtime: **10–15 minutes** on a clean VM.

## What It Does (in order)

### 1. `open_ports`
Opens TCP 80 and 443 in UFW and keeps the SSH port open. Port 80 is needed for the Let's Encrypt HTTP-01 challenge and the redirect to HTTPS. The Kubernetes API (6443), RKE2 supervisor (9345) and kubelet (10250) are **not** exposed publicly. Port 6443 is opened only to the optional trusted admin CIDR. For remote kubectl, use Rancher's kubeconfig, which is proxied over 443.

### 2. `install_rke2`
Downloads the RKE2 installer, then runs it on the pinned channel (the installer verifies its own tarball checksum). Config:
- `cni: none` and `disable-kube-proxy: true`: Cilium owns pod networking and service routing
- `disable: [rke2-ingress-nginx, rke2-traefik]`: Envoy Gateway replaces them. On an existing cluster, the bundled controllers are also removed.
- `write-kubeconfig-mode: "0600"` and `secrets-encryption: true`

Writes the kubeconfig to the invoking user's `~/.kube/config` (mode 600).

> The node shows `NotReady` until Cilium is installed. This is expected.

### 3. `install_helm`
Installs a pinned Helm release tarball after verifying its SHA-256.

### 4. `install_cilium`
Verifies the Cilium CLI's checksum, then installs Cilium with:
- `kubeProxyReplacement=true`: eBPF service routing
- `nodeIPAM.enabled=true`: `LoadBalancer` services with class `io.cilium/node` get the node's IP, so no cloud load balancer is needed
- Hubble relay and UI for traffic visibility

On an existing healthy install, it only turns on node IPAM if it's missing.

### 5. `install_envoy_gateway`
- **CRDs:** the Gateway API CRDs are cluster-wide and shared.
  - If the cluster already provides a new-enough version (RKE2 1.37+ bundles them), that owner is kept and only Envoy Gateway's own CRDs are installed.
  - If none exist, the standard-channel CRDs are installed along with Envoy Gateway.
  - An older version stops the script rather than risk a downgrade.
- **Controller:** installs the `gateway-helm` chart into `envoy-gateway-system`.
- **`EnvoyProxy` `public-proxy`**: `LoadBalancer` service on the node IP with:
  - `externalTrafficPolicy: Local`, so real client IPs reach Envoy for logs, rate limits and IP allow-lists
  - `allocateLoadBalancerNodePorts: false`. Cilium handles NodePorts in eBPF before UFW sees the traffic, so NodePorts would be reachable from the internet.
- **`GatewayClass` `envoy`**: points at that `EnvoyProxy`.

### 6. `install_cert_manager`
Installs cert-manager with `config.enableGatewayAPI=true`. It's installed after the Gateway API CRDs because cert-manager detects them only at startup. It then creates the `ClusterIssuer` `letsencrypt`, which answers HTTP-01 challenges through the Gateway's `http` listener.

### 7. `setup_gateway`
Creates the `Gateway` `public` in `envoy-gateway-system`:

| Listener | Port | Hostname | Routes may attach from |
|---|---|---|---|
| `http` | 80 | any | `envoy-gateway-system` only (redirect + ACME) |
| `https-rancher` | 443 | Rancher domain | `cattle-system` only |
| `https-app-N` | 443 | each app hostname | namespaces labelled `gateway-access=true` (`prod`, `sandbox`) |

- cert-manager issues a Let's Encrypt certificate for every HTTPS listener, triggered by the Gateway annotation.
- All plain-HTTP traffic gets a 301 redirect to HTTPS. Apps can't serve plaintext.
- The `ClientTrafficPolicy` sets TLS 1.2 as the minimum and rejects headers containing underscores, which can be used to spoof or smuggle headers.

### 8. `install_rancher`
Installs Rancher with its own ingress turned off, TLS terminated at Envoy (`tls=external`), and `agentTLSMode=system-store`, so agents trust the Let's Encrypt certificate. An `HTTPRoute` in `cattle-system` attaches to `https-rancher`. It has no request timeout, because Rancher streams watches, shells and logs, and it adds an HSTS header.

The bootstrap password is randomly generated and passed in a root-only values file, not on the command line. It's saved to `/root/.rancher_bootstrap_password` (mode 600) and never printed.

### 9. `setup_namespaces`
Creates `prod` and `sandbox`, labelled `gateway-access=true`, with:

- **Resource Quotas**: hard limits on total CPU, memory and pod count.
- **LimitRanges**: default requests and limits for containers that don't declare their own. Without them, those pods bypass the quota.
- **NetworkPolicies**:
  - `default-deny-all`: blocks all ingress and egress
  - `allow-intra-namespace`: pod-to-pod within the namespace, plus DNS to cluster CoreDNS only
  - `allow-from-gateway`: inbound from Envoy's proxy pods only. Without this, nothing behind an HTTPRoute is reachable.

Traffic between `prod` and `sandbox` stays blocked. **Outbound traffic is also blocked** (external APIs, databases). Add a policy per app for what it needs; see below.

## Resource Allocations

| | prod | sandbox |
|---|---|---|
| CPU request limit | 4 cores | 1 core |
| CPU hard limit | 8 cores | 2 cores |
| Memory request limit | 4 Gi | 1 Gi |
| Memory hard limit | 8 Gi | 2 Gi |
| Max pods | 50 | 20 |
| Default container CPU | 500m | 250m |
| Default container memory | 256 Mi | 128 Mi |

## After Installation

### 1. DNS
Point A records for the Rancher domain and every app hostname to the VM's public IP. Let's Encrypt won't issue certificates until DNS resolves. Check progress with:
```bash
kubectl get certificate -n envoy-gateway-system
```

### 2. First Login
```
URL:      https://<your-domain>
Password: sudo cat /root/.rancher_bootstrap_password
```
Set a permanent admin password, then run `sudo shred -u /root/.rancher_bootstrap_password`.

### 3. Pick up KUBECONFIG
```bash
source ~/.bashrc
kubectl get nodes
```

### 4. Assign Projects in Rancher UI
`Cluster → Projects/Namespaces → Create Project` for `prod` and `sandbox`. Projects give you RBAC, resource visibility and monitoring scoped per environment.

### 5. Expose an App
Deploy the app and its Service, then attach an `HTTPRoute` to the listener for its hostname:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-api
  namespace: prod
spec:
  parentRefs:
  - name: public
    namespace: envoy-gateway-system
    sectionName: https-app-1        # listener for api.example.com
  hostnames: ["api.example.com"]
  rules:
  - backendRefs:
    - name: my-api                  # Service name
      port: 8080
```

**Adding a hostname later:** use `gateway_add_hostname.sh`. It appends one HTTPS listener (and certificate) per hostname and changes nothing else, with no Helm upgrades or restarts. Hostnames already on the Gateway are skipped.

```bash
bash gateway_add_hostname.sh --dry-run new.example.com   # validate only
bash gateway_add_hostname.sh new.example.com
```

Re-running `rancher_setup.sh` rebuilds the listener list from its prompt, so pass it **all** app hostnames in their current order: `https-app-N` and its certificate `app-N-tls` follow the order you type. `gateway_add_hostname.sh` prints that list after each run.

### 6. Allow an App's Outbound Traffic
Example: let pods labelled `app: my-api` in `prod` call HTTPS APIs on the internet but not other cluster namespaces:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-api-egress-https
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: my-api
  policyTypes: [Egress]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except: [10.42.0.0/16, 10.43.0.0/16]
    ports:
    - port: 443
      protocol: TCP
```

Databases on the VM itself (Postgres, Mongo) listen on `127.0.0.1` only and can't be reached from pods. That's intentional. Exposing them needs a deliberate change to both the database bind address and a `CiliumNetworkPolicy` using `toEntities: [host]`.

## Envoy Gateway Extras

Envoy Gateway policies attach to a Gateway or an HTTPRoute:

| Need | Resource |
|---|---|
| Rate limiting | `BackendTrafficPolicy` → `rateLimit` (type `Local` needs no Redis) |
| JWT / OIDC login | `SecurityPolicy` → `jwt` / `oidc` |
| IP allow-list (e.g. Rancher to office IPs only) | `SecurityPolicy` → `authorization` with `clientCIDRs` |
| CORS | `SecurityPolicy` → `cors` |
| Retries, timeouts, circuit breaking | `BackendTrafficPolicy` |

Client IPs are preserved (`externalTrafficPolicy: Local`), so IP-based rules see the real address. Before adding an IP allow-list to Rancher, make sure downstream clusters' agents can still reach it.

## Observability — Hubble

```bash
cilium hubble ui                       # browser UI
hubble observe --namespace prod        # live flows
hubble observe --verdict DROPPED       # what NetworkPolicies are blocking
cilium status
```

## Useful Commands

```bash
# Cluster health
kubectl get nodes
kubectl get pods -A

# Gateway / routing
kubectl get gateway,httproute -A
kubectl describe gateway public -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system     # EXTERNAL-IP should be the node IP

# Certificates
kubectl get certificate,challenge -A

# Namespace resource usage
kubectl describe resourcequota quota -n prod
kubectl get networkpolicy -n prod

# Helm releases
helm list -A
```

## Troubleshooting

**Node stuck in NotReady**
Cilium is still starting. Run `cilium status` and wait for all components to show `OK`.

**Gateway not `Programmed` / Envoy service has no EXTERNAL-IP**
Node IPAM isn't enabled: `helm get values cilium -n kube-system --all | grep -A1 nodeIPAM`. Re-running the script turns it on.

**Let's Encrypt certificate not issuing**
- Confirm DNS resolves: `dig +short <hostname>`
- Port 80 must be reachable from the internet
- `kubectl describe certificate -n envoy-gateway-system` and `kubectl get challenge -A`
- cert-manager must have started after the Gateway API CRDs existed: `kubectl rollout restart deployment cert-manager -n cert-manager`

**App returns 503 / upstream connect error**
- The HTTPRoute isn't accepted: `kubectl describe httproute <name> -n prod` and look at `Accepted` / `ResolvedRefs`.
- The namespace lacks the `gateway-access=true` label, or `allow-from-gateway` is missing.
- `hubble observe --namespace prod --verdict DROPPED` shows blocked traffic.

**App can't call external services**
Egress is default-deny. Add an egress NetworkPolicy (see "Allow an App's Outbound Traffic").

**Rancher UI not loading**
```bash
kubectl rollout status deployment/rancher -n cattle-system
kubectl describe httproute rancher -n cattle-system
kubectl logs -n cattle-system -l app=rancher --tail=50
```

**Pods cannot reach the Kubernetes API (`10.43.0.1:443` i/o timeout)**
UFW is blocking pod traffic. The pod and service CIDRs must be allowed (the script does this):
```bash
ufw allow from 10.42.0.0/16
ufw allow from 10.43.0.0/16
ufw allow to 10.42.0.0/16
ufw allow to 10.43.0.0/16
ufw reload
```

**Re-running the script**
Re-runs are safe. RKE2, Helm and a healthy Cilium are skipped, Helm releases use `upgrade --install`, and manifests use `kubectl apply`.

## Upgrading Components

Update the version variables at the top of the script and re-run:

```bash
RANCHER_VERSION="2.14.1"
ENVOY_GATEWAY_VERSION="v1.9.2"   # CRDs are upgraded first, automatically
CERT_MANAGER_VERSION="v1.20.2"
RKE2_CHANNEL="v1.35"             # only raise once Rancher supports the new minor
```

Always test in `sandbox` before touching `prod`.
