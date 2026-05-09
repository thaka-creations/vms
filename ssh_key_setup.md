# SSH Key Setup Guide

## 1. Generate a Key Pair (on your local machine)

```bash
ssh-keygen -t ed25519 -C "thakacreations@gmail.com"
```

- Press Enter to accept the default path (`~/.ssh/id_ed25519`)
- Set a passphrase (recommended) or press Enter to skip

Two files are created:

- `~/.ssh/id_ed25519` — private key (never share this)
- `~/.ssh/id_ed25519.pub` — public key (this goes on the server)

---

## 2. Copy the Public Key to the VM

### Option A — Automatic (if password auth is still enabled)

```bash
ssh-copy-id -p 2004 username@vm-ip-address
```

### Option B — Manual (via VM console)

View your public key on your local machine:

```bash
cat ~/.ssh/id_ed25519.pub
```

Then on the VM, paste it into `authorized_keys`:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "paste-your-public-key-here" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## 3. Test Before Disabling Password Auth

Always verify key login works before locking out password access:

```bash
ssh -p 2004 -i ~/.ssh/id_ed25519 username@vm-ip-address
```

Only disable `PasswordAuthentication` in `/etc/ssh/sshd_config` once this succeeds.

---

## Recovery: If You're Already Locked Out

1. Log in via the VM console (VirtualBox/VMware/cloud provider web UI)
2. Temporarily re-enable password auth:

```bash
sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

3. SSH in from your local machine and add your public key to `~/.ssh/authorized_keys`
4. Re-disable password auth and restart SSH
