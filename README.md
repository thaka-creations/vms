# VM Hardening Scripts

Bash scripts to harden an Ubuntu 22.04+ server and install databases and a single-VM Kubernetes stack.

Everything except `ssh_keygen.sh` runs **on the server as root**.

## 1. SSH access

**On your machine**, create a key:

```bash
bash ssh_keygen.sh                  # makes ~/.ssh/<name> and prints the public key
```

**Copy the scripts to the server**:

```bash
scp -P <port> *.sh <user>@<server-ip>:~/vms/
ssh -p <port> <user>@<server-ip>
cd ~/vms
```

**On the server**, give yourself a login:

```bash
sudo bash create_user.sh            # new sudo user; paste your public key when asked
sudo bash ssh_authorize.sh          # or: add a key to an existing user
```

Test the key login in a new terminal before going further.

## 2. Harden the server

Run in this order:

```bash
sudo bash ubuntu_hardening_v1.sh    # asks for the SSH port (default 2004)
sudo bash pampolicies.sh
sudo bash ubuntu_setup_logging.sh
sudo reboot
```

| Script | What it does |
|---|---|
| `ubuntu_hardening_v1.sh` | Updates, automatic security upgrades, key-only SSH on a custom port, UFW, fail2ban, kernel/sysctl hardening, AppArmor, time sync |
| `pampolicies.sh` | Password rules (14+ chars, 4 character classes, no reuse of the last 5) and a 15-min lockout after 5 failed logins |
| `ubuntu_setup_logging.sh` | auditd rules, USB storage blocked, `/tmp` mounted `noexec`, unused services disabled, log rotation, file permissions |

> `ubuntu_hardening_v1.sh` turns off password login. It refuses to run if no user has an authorized key.
> Keep your current session open until `ssh -p <new-port> <user>@<server-ip>` works.

## 3. Databases (optional)

Each database listens on localhost only. Generated credentials are saved to a root-only file.

```bash
sudo bash pg_setup.sh               # PostgreSQL: database + admin/app/read-only roles
sudo bash pg_schemas.sh             # after pg_setup: one schema + login roles per service
sudo bash mongo_setup.sh            # MongoDB with auth: admin/app/read-only users
```

| Credentials file | Created by |
|---|---|
| `/root/.pg_<app>.env` | `pg_setup.sh` |
| `/root/.pg_schemas_<db>.env` | `pg_schemas.sh` |
| `/root/.mongo_<app>.env` | `mongo_setup.sh` |

Load them with `set -a; source <file>; set +a`. Never commit them.

## 4. Kubernetes + Rancher (single VM)

```bash
sudo bash rancher_setup.sh
```

The script asks for:

- the Rancher domain
- a Let's Encrypt email
- an optional admin CIDR for direct Kubernetes API access
- optional app hostnames

It installs RKE2, Cilium, Envoy Gateway, cert-manager and Rancher, and creates `prod` and `sandbox` namespaces.

Then:

1. Point DNS A records for the Rancher domain and each app hostname to the server's IP.
2. Get the first-login password with `sudo cat /root/.rancher_bootstrap_password`.
3. Log in at `https://<rancher-domain>` and set a permanent password.
4. Delete the password file: `sudo shred -u /root/.rancher_bootstrap_password`.
5. Expose apps with an `HTTPRoute`.

See [rancher_setup_docs.md](rancher_setup_docs.md) for step 5, outbound network rules and troubleshooting.

## Uninstall

These delete all data. Each asks for confirmation.

```bash
sudo bash rancher_uninstall.sh      # removes the cluster, Rancher and all workloads
sudo bash mongo_uninstall.sh        # removes MongoDB and its data
```

## Don't commit secrets

`.gitignore` excludes kubeconfigs (`local.yaml`), `.env` files and keys. Keep credentials in a password manager, not in this repo or `.notes`.
