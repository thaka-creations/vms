# VM Hardening Scripts

A collection of bash scripts for securing and configuring Ubuntu virtual machines.

## Scripts

| Script | Description |
|---|---|
| `ubuntu_hardening_v1.sh` | Main hardening script — SSH config, UFW firewall, AppArmor, kernel hardening, time sync, and more |
| `create_user.sh` | Creates a new sudo user with SSH key access |
| `pampolicies.sh` | Configures PAM password policies without breaking sudo |
| `ubuntu_setup_logging.sh` | Sets up auditd, AppArmor, OSSEC HIDS, and Lynis for monitoring and intrusion detection |
| `rancher_setup.sh` | Installs k3s (Kubernetes) + Rancher on a single VM with prod and sandbox namespaces |

## Usage

Run each script as root or with sudo:

```bash
sudo bash ubuntu_hardening_v1.sh
sudo bash create_user.sh
sudo bash pampolicies.sh
sudo bash ubuntu_setup_logging.sh
```

## Recommended Order

### Per VM (run on all nodes)
1. `create_user.sh` — create your admin user and add your SSH public key
2. `ubuntu_hardening_v1.sh` — harden the system (disables root login and password auth)
3. `pampolicies.sh` — enforce password policies
4. `ubuntu_setup_logging.sh` — set up logging and intrusion detection

> Before running `ubuntu_hardening_v1.sh`, ensure your SSH public key is in `~/.ssh/authorized_keys` for your user. See `ssh_key_setup.md` for key generation instructions.

### Kubernetes / Rancher (single VM)

```
1 VM — k3s (Kubernetes) + Rancher + prod namespace + sandbox namespace
```

1. `sudo bash rancher_setup.sh` — installs k3s, Rancher, and creates prod/sandbox namespaces with resource quotas
2. Point your domain DNS to the VM's public IP
3. Login to Rancher UI and set your admin password
4. In Rancher: Cluster → Projects/Namespaces → assign `prod` and `sandbox` to separate Projects for RBAC
5. Deploy workloads with `kubectl apply -f app.yaml -n prod` or `-n sandbox`

## Target Environment

Ubuntu Server (tested on Ubuntu 22.04+)
