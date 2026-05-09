# rancher_setup.sh — Documentation

## Overview

`rancher_setup.sh` provisions a single Ubuntu VM into a production-grade Kubernetes environment. It installs k3s (Kubernetes), Cilium CNI, nginx ingress, cert-manager, and Rancher, then creates isolated `prod` and `sandbox` namespaces with resource quotas and network policies.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                        Single VM                        │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Rancher (cattle-system)            │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌───────────────────┐   ┌───────────────────────────┐  │
│  │   prod namespace  │   │    sandbox namespace      │  │
│  │  quota: 8cpu/8Gi  │   │   quota: 2cpu/2Gi         │  │
│  │  pods: 50 max     │   │   pods: 20 max            │  │
│  │  NetworkPolicy:   │   │   NetworkPolicy:           │  │
│  │  deny-all + intra │   │   deny-all + intra        │  │
│  └───────────────────┘   └───────────────────────────┘  │
│  ┌─────────────────────────────────────────────────┐   │
│  │         Cilium CNI (eBPF pod networking)        │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌──────────────────┐  ┌──────────────┐  ┌──────────┐  │
│  │  nginx ingress   │  │ cert-manager │  │   k3s    │  │
│  └──────────────────┘  └──────────────┘  └──────────┘  │
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
| Domain | A record pointing to VM's public IP |

> Run the hardening scripts (`ubuntu_hardening_v1.sh`, `ubuntu_setup_logging.sh`) before this script.

## Pinned Versions

| Component | Version |
|---|---|
| Rancher | 2.8.4 |
| cert-manager | v1.14.4 |
| ingress-nginx | 4.10.1 |
| Cilium CLI | latest stable (fetched at runtime, checksum verified) |

To upgrade a component, update the version variable at the top of the script and re-run — `helm upgrade --install` and `kubectl apply` are idempotent.

## Usage

```bash
sudo bash rancher_setup.sh
```

The script prompts for two inputs then runs unattended:

```
Enter your Rancher domain (e.g. rancher.yourdomain.com): rancher.example.com
Enter your email for Let's Encrypt certs: you@example.com
```

Estimated runtime: **8–12 minutes** on a clean VM.

## What It Does (in order)

### 1. `open_ports`
Opens TCP 80 and 443 in UFW. Port 80 is required for the Let's Encrypt HTTP-01 ACME challenge.

### 2. `install_k3s`
Installs k3s with two flags:
- `--flannel-backend=none` — disables Flannel so Cilium can own all pod networking
- `--disable-network-policy` — removes the built-in controller since Cilium handles this

Writes kubeconfig to the invoking user's `~/.kube/config` (not just root's) and appends `export KUBECONFIG=...` to `~/.bashrc`.

> The node will show `NotReady` until Cilium is installed. This is expected.

### 3. `install_helm`
Installs Helm 3 via the official install script. Skips if already present.

### 4. `install_cilium`
Downloads the Cilium CLI binary for the detected architecture (`amd64` or `arm64`), verifies the SHA-256 checksum before extracting, then installs Cilium into the cluster with:

- `kubeProxyReplacement=true` — Cilium replaces kube-proxy using eBPF for all service routing
- `hubble.relay.enabled=true` — enables the Hubble observability relay
- `hubble.ui.enabled=true` — enables the Hubble traffic flow UI

Skips if Cilium is already running.

### 5. `install_nginx_ingress`
Installs the nginx ingress controller as a LoadBalancer service. Used by both Rancher and application ingress resources. Installed with `--atomic` so a failed install rolls back automatically.

### 6. `install_cert_manager`
Installs cert-manager for automatic TLS certificate provisioning via Let's Encrypt. CRDs are applied before the Helm chart.

### 7. `install_rancher`
Installs Rancher into the `cattle-system` namespace. TLS is sourced from Let's Encrypt via cert-manager. The bootstrap password is **randomly generated** with `openssl rand -base64 24` and printed once at the end of the script.

### 8. `setup_namespaces`
Creates `prod` and `sandbox` namespaces with three layers of isolation:

**Resource Quotas** — hard limits on total CPU, memory, and pod count per namespace.

**LimitRanges** — default CPU/memory requests and limits applied to any container that doesn't declare its own. Without this, pods without resource fields bypass quotas entirely.

**NetworkPolicies** — two policies per namespace:
- `default-deny-all`: blocks all ingress and egress by default
- `allow-intra-namespace`: permits traffic between pods within the same namespace, plus DNS egress (port 53) so service discovery works

Traffic between `prod` and `sandbox` is blocked unless you explicitly add a policy to allow it.

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
Point an A record for your Rancher domain to the VM's public IP. Let's Encrypt will not issue a certificate until DNS resolves.

### 2. First Login
```
URL:      https://<your-domain>
Password: printed at end of script — save it before closing the terminal
```
Set a permanent admin password on first login.

### 3. Pick up KUBECONFIG
```bash
source ~/.bashrc
kubectl get nodes
```

### 4. Assign Projects in Rancher UI
`Cluster → Projects/Namespaces → Create Project` for `prod` and `sandbox`. Projects enable RBAC, resource visibility, and monitoring scoped per environment.

### 5. Deploy Workloads
```bash
kubectl apply -f app.yaml -n prod
kubectl apply -f app.yaml -n sandbox
```

## Observability — Hubble

Cilium ships with Hubble for real-time traffic visibility:

```bash
# Open Hubble UI in browser
cilium hubble ui

# CLI — watch live flows
hubble observe --namespace prod

# Check Cilium and Hubble status
cilium status
```

## Useful Commands

```bash
# Cluster health
kubectl get nodes
kubectl get pods -A

# Namespace resource usage
kubectl describe resourcequota quota -n prod
kubectl describe limitrange defaults -n prod

# Active network policies
kubectl get networkpolicy -n prod
kubectl get networkpolicy -n sandbox

# Rancher pods
kubectl get pods -n cattle-system

# cert-manager — check certificate status
kubectl get certificate -A
kubectl describe certificate -n cattle-system

# Helm releases
helm list -A
```

## Troubleshooting

**Node stuck in NotReady**
Cilium is still starting. Check with `cilium status` and wait for all components to show `OK`.

**Let's Encrypt certificate not issuing**
- Confirm DNS resolves: `dig +short <your-domain>`
- Port 80 must be reachable from the internet for the ACME challenge
- Check: `kubectl describe certificate -n cattle-system`

**Rancher UI not loading**
```bash
kubectl rollout status deployment/rancher -n cattle-system
kubectl logs -n cattle-system -l app=rancher --tail=50
```

**Pod cannot reach DNS**
The `allow-intra-namespace` NetworkPolicy allows port 53 egress. If DNS still fails, check that CoreDNS is running: `kubectl get pods -n kube-system -l k8s-app=kube-dns`.

**Pods cannot reach the Kubernetes API (`10.43.0.1:443` i/o timeout)**
UFW is blocking pod-to-API traffic. The hardening script defaults to deny-all incoming; the k3s pod and service CIDRs must be explicitly whitelisted:
```bash
ufw allow from 10.42.0.0/16
ufw allow from 10.43.0.0/16
ufw allow to 10.42.0.0/16
ufw allow to 10.43.0.0/16
ufw reload
kubectl rollout restart deployment/local-path-provisioner -n kube-system
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout restart deployment/metrics-server -n kube-system
kubectl rollout restart deployment/hubble-relay -n kube-system
```

**Re-running the script**
All steps are idempotent. k3s, Cilium, and Helm components skip if already present. Helm installs use `upgrade --install` so re-runs are safe.

## Upgrading Components

Update the version variable at the top of the script:

```bash
RANCHER_VERSION="2.9.0"
CERT_MANAGER_VERSION="v1.15.0"
INGRESS_NGINX_VERSION="4.11.0"
```

Then re-run — Helm will upgrade in place. Always test in `sandbox` before touching `prod`.
