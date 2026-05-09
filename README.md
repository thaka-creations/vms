# VM Hardening Scripts

A collection of bash scripts for securing and configuring Ubuntu virtual machines.

## Scripts

| Script | Description |
|---|---|
| `ubuntu_hardening_v1.sh` | Main hardening script — SSH config, UFW firewall, AppArmor, kernel hardening, time sync, and more |
| `create_user.sh` | Creates a new sudo user with SSH key access |
| `pampolicies.sh` | Configures PAM password policies without breaking sudo |
| `ubuntu_setup_logging.sh` | Sets up auditd, AppArmor, OSSEC HIDS, and Lynis for monitoring and intrusion detection |

## Usage

Run each script as root or with sudo:

```bash
sudo bash ubuntu_hardening_v1.sh
sudo bash create_user.sh
sudo bash pampolicies.sh
sudo bash ubuntu_setup_logging.sh
```

## Recommended Order

1. `create_user.sh` — create your admin user and add your SSH public key
2. `ubuntu_hardening_v1.sh` — harden the system (disables root login and password auth)
3. `pampolicies.sh` — enforce password policies
4. `ubuntu_setup_logging.sh` — set up logging and intrusion detection

> Before running `ubuntu_hardening_v1.sh`, ensure your SSH public key is in `~/.ssh/authorized_keys` for your user. See `ssh_key_setup.md` for key generation instructions.

## Target Environment

Ubuntu Server (tested on Ubuntu 22.04+)
