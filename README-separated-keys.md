# Dual Host Keys in Skarabox

Skarabox supports dual host keys for enhanced security while maintaining full backward compatibility.

## Security Benefits

| Single Host Key (Legacy) | Dual Host Keys (Default) |
|-------------------|-------------------|
| Physical access = full compromise | Physical access = boot unlock only |
| SOPS secrets at risk | SOPS secrets protected |
| One key does everything | Separation of concerns |

## For New Hosts

**Just works automatically:**
```bash
nix run skarabox#gen-new-host -- -n myhost
```

You get:
- **Initrd Key** (`/boot/host_key`): Boot unlock only
- **Runtime Key** (`/persist/etc/ssh/ssh_host_ed25519_key`): Admin access + SOPS (OpenSSH standard path)

## For Existing Hosts

**Migration requires 4 phases** (all existing hosts were created with single host keys):

1. **Phase 1**: Generate runtime keys (`prepare-dual-migration`)
2. **Phase 2**: Install runtime keys on target system (`install-runtime-key`) 
3. **Phase 3**: Update configuration to use both keys (manual edit)
4. **Phase 4**: Re-encrypt SOPS secrets for both keys ⚠️ **CRITICAL FOR SECURITY**

> **Important**: The POC exploit still works until Phase 4 is complete! The configuration may show dual host keys, but SOPS secrets remain encrypted with only the old key.

**Phase 1: Prepare Migration**
```bash
nix run .#myhost-prepare-dual-migration
```

This safely:
- ✅ Generates runtime host key
- ✅ Updates SOPS config with both keys 
- ✅ No behavior changes yet

### Phase 2: Deploy Runtime Keys (Push to Hosts)

After Phase 1 is complete and deployed, install the runtime host keys on existing hosts.

### Option 1: Automated (Recommended)

```bash
nix run .#<host>-install-runtime-key
```

This automatically copies the runtime keys and deploys with colmena.

### Option 2: Manual Steps

```bash
# Step 1: Copy runtime keys to target host
scp -P <ssh_port> -i <host>/ssh <host>/runtime_host_key* <username>@<host_ip>:/tmp/

# Step 2: Deploy with colmena (activation script will install the keys)
nix run .#colmena -- apply --on <host>
```

### Example for a host named "builder":

```bash
# Automated:
nix run .#builder-install-runtime-key

# Or manual:
scp -P 22 -i builder/ssh builder/runtime_host_key* root@192.168.1.100:/tmp/
nix run .#colmena -- apply --on builder
```

The skarabox activation script automatically detects runtime keys in `/tmp/` and installs them to `/persist/etc/ssh/` with proper permissions (OpenSSH standard path).

**Phase 3: Switch to Dual Mode**

Manually update your host's configuration to use both keys:

```nix
# In your host's configuration.nix:
sops.age.sshKeyPaths = [
  "/boot/host_key"                                  # Original initrd key  
  "/persist/etc/ssh/ssh_host_ed25519_key"          # New runtime key (OpenSSH standard)
];
```

Then deploy the configuration:

```bash
nix run .#colmena -- apply --on myhost
```

The system will automatically detect dual host key mode and apply the appropriate security model.

**Phase 4: Re-encrypt SOPS Secrets** 🔐

**CRITICAL**: The configuration change in Phase 3 only tells SOPS which keys to *try* - it doesn't change which keys can actually decrypt the secrets! You must re-encrypt the secrets to include ONLY the runtime key (removing the vulnerable initrd key).

**Why this matters:** Until Phase 4, an attacker with physical access can still decrypt all secrets using the initrd key, even though your configuration shows dual host keys.

**Step 1: Remove the initrd key from recipients**

```bash
# Remove the initrd key from secrets encryption
cd myhost/
SOPS_AGE_KEY_FILE=../sops.key nix run .#sops -- -r -i --rm-age \
  $(nix shell nixpkgs#ssh-to-age -c ssh-keygen -y -f host_key | ssh-to-age) \
  secrets.yaml
```

**Step 2: Verify the exploit is now blocked**

```bash
# This should FAIL after Phase 4
ssh myhost 'sudo cat /boot/host_key' > /tmp/stolen_key
nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i /tmp/stolen_key > /tmp/stolen_key.age
SOPS_AGE_KEY_FILE=/tmp/stolen_key.age nix run .#sops -- -d myhost/secrets.yaml
# Should output: "Recovery failed because no master key was able to decrypt the file"
```

**Step 3: Deploy the secure configuration**

```bash
nix run .#colmena -- apply --on myhost
```

## Security Architecture Summary

| Component | Single Host Key (Legacy) | **Dual Host Keys (Secure)** |
|-----------|-------------------|----------------------|
| **Boot unlock** | Initrd key | Initrd key |
| **SOPS secrets** | ❌ Initrd key (vulnerable) | ✅ Runtime key (secure) |
| **Admin SSH** | Initrd key | Runtime key |
| **Physical attack** | 💥 Full compromise | 🔒 Boot unlock only |

⚠️ **CRITICAL: Git History Vulnerability** ⚠️

Even after Phase 4, **old secrets files in git history can still be decrypted with the stolen initrd key**! The secrets themselves (passwords, keys) don't change when you re-encrypt the file.

**Phase 5: Rotate Secrets** (Required for Complete Security)

After completing Phases 1-4, you MUST rotate the actual secret values:

```bash
# 1. Generate new user password  
mkpasswd -m yescrypt > new-password-hash

# 2. Generate new disk encryption keys
openssl rand -hex 32 > new-root-passphrase
openssl rand -hex 32 > new-data-passphrase  

# 3. Update secrets file with new values
nix run .#sops -- -e myhost/secrets.yaml
# Edit: Replace old password hash and passphrases with new ones

# 4. Deploy new secrets
nix run .#colmena -- apply --on myhost

# 5. Update disk encryption (requires careful planning!)
# This is complex and system-specific - plan carefully!
```

**Without Phase 5, an attacker with git access + physical access can still compromise your system using old secrets from repository history.**

## Current Status

✅ **New hosts**: Dual keys by default  
✅ **Existing hosts**: Migration workflow complete (4 phases)  
🚨 **CRITICAL GAP**: Git history vulnerability - Phase 5 (secret rotation) required  
⚠️ **Partial Security**: Phase 4 blocks current secrets, but old secrets in git history remain vulnerable  
✅ **Testing**: POC exploit blocked for new secrets, but works for old secrets from git history  

## Troubleshooting

**Verify your migration status:**

```bash
# Check if system detects dual host key mode
nix eval .#nixosConfigurations.myhost.config.skarabox.isDualHostMode

# Check which keys SOPS configuration expects
nix eval .#nixosConfigurations.myhost.config.sops.age.sshKeyPaths

# Check which keys exist on the system  
ssh myhost 'sudo ls -la /boot/host_key /persist/etc/ssh/ssh_host_ed25519_key'

# Check which keys the secrets are ACTUALLY encrypted for
head -20 myhost/secrets.yaml  # Look for age1... recipients
```

**Test the POC exploit:**

```bash
# Get the initrd key (simulate physical access)
ssh myhost 'sudo cat /boot/host_key' > /tmp/stolen_key

# This should FAIL after Phase 4 is complete
SOPS_AGE_KEY_FILE=/tmp/stolen_key nix run .#sops -- -d myhost/secrets.yaml
```

**Common Issues:**

- **Phase 3 complete but exploit still works**: You need Phase 4! The secrets are still encrypted with only the old key.
- **SSH host key changed**: Expected after Phase 2 - the system now uses the runtime key for SSH connections.
- **Can't connect via SSH after Phase 2**: Update your `~/.ssh/known_hosts` or use `ssh-keygen -R <host_ip>`.

## Backward Compatibility

Existing hosts continue working unchanged. This is not a breaking change.

For single host key mode (if needed):
```bash
nix run skarabox#gen-new-host -- --single-key -n myhost
```
