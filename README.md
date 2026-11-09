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

### PostgreSQL backups (Cloudflare R2)

pgBackRest does a full backup every Sunday, a differential backup Mon–Sat (both at 01:30), and archives WAL continuously, so you can restore to any point in time and lose at most about 5 minutes of data. Backups are encrypted with AES-256 before they leave the server. Four weeks of backups are kept. On the 1st of each month, a restore test restores the latest backup to a scratch copy and checks it.

**1. In Cloudflare:** create a bucket, then an R2 API token with **Object Read & Write** access to **that bucket only**. Don't add lifecycle rules or bucket locks to the backup path, because pgBackRest manages retention itself and deleting its files breaks the backup chain.

**2. On the VM:**
```bash
sudo bash pg_backup_setup.sh        # asks for the account ID, bucket and token; turning on WAL archiving restarts Postgres once (a few seconds)
```

**3. Copy `/root/.pgbackrest_cipher.env` off the server** (to a password manager). Every backup is encrypted with it, and without it they can't be restored.

**4. (Recommended) Monitoring:** create two checks on [healthchecks.io](https://healthchecks.io): one for backups (daily, with a 2 h grace period) and one for the restore test (monthly). Give their URLs when the script asks. If a job fails or doesn't run, you get an alert.

**5. (Recommended) Data checks for the restore test:** put SQL in `/etc/pgbackrest/restore-check.sql` that raises an exception when something is wrong, and add `RESTORE_CHECK_DB=<db>` to `/etc/pgbackrest/healthcheck.env`. For example, BulkSms checks that every wallet balance equals its ledger total:
```sql
DO $$
DECLARE drift int;
BEGIN
  SELECT count(*) INTO drift FROM bulksms.accounts_wallet w
    LEFT JOIN (SELECT wallet_id, sum(amount_cents) s FROM bulksms.billing_ledgerentry GROUP BY 1) l
      ON l.wallet_id = w.id
   WHERE coalesce(l.s, 0) <> (w.amount * 100)::bigint;
  IF drift > 0 THEN RAISE EXCEPTION '% wallet(s) do not match the ledger', drift; END IF;
END $$;
```

**Everyday commands:**
```bash
sudo -u postgres pgbackrest --stanza=main info              # backups, sizes, WAL range
sudo systemctl start pgbackrest@diff                        # back up now (full|diff)
sudo bash pg_restore_test.sh                                # run the restore test now
systemctl list-timers 'pgbackrest-*'                        # next scheduled runs
journalctl -u 'pgbackrest@*' -n 50                          # recent job output
```

**Disaster recovery** (on the same VM, or on a new one after `pg_setup.sh` + `pg_backup_setup.sh` with the **same** cipher passphrase in `/root/.pgbackrest_cipher.env`):
```bash
sudo systemctl stop postgresql@18-main
sudo -u postgres pgbackrest --stanza=main --delta restore                                  # latest
sudo -u postgres pgbackrest --stanza=main --delta --type=time \
     --target="2026-11-09 14:30:00+03" --target-action=promote restore                    # point in time
sudo systemctl start postgresql@18-main
```
Stop the apps first, so nothing writes while the restore runs.

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

To serve another hostname later, add a listener without re-running the setup:

```bash
bash gateway_add_hostname.sh offline.example.com      # --dry-run to validate first
```

See [rancher_setup_docs.md](rancher_setup_docs.md) for step 5, outbound network rules and troubleshooting.

## Uninstall

These delete all data. Each asks for confirmation.

```bash
sudo bash rancher_uninstall.sh      # removes the cluster, Rancher and all workloads
sudo bash mongo_uninstall.sh        # removes MongoDB and its data
```

## Don't commit secrets

`.gitignore` excludes kubeconfigs (`local.yaml`), `.env` files and keys. Keep credentials in a password manager, not in this repo or `.notes`.
