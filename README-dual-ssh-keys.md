# Dual SSH Keys in Skarabox

Skarabox supports dual SSH keys for enhanced security while maintaining full backward compatibility.

## Security Benefits

| Single Key (Legacy) | Dual Keys (Default) |
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
- **Runtime Key** (`/persist/ssh/runtime_host_key`): Admin access + SOPS

## For Existing Hosts

**Phase 1: Prepare Migration**
```bash
nix run .#myhost-prepare-dual-migration
```

This safely:
- ✅ Generates runtime SSH key
- ✅ Updates SOPS config with both keys 
- ✅ No behavior changes yet

## Phase 2: Install Runtime Keys

After Phase 1 is complete and deployed, install the runtime SSH keys on existing hosts.

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

The skarabox activation script automatically detects runtime keys in `/tmp/` and installs them to `/persist/ssh/` with proper permissions.

**Phase 3: Switch to Dual Mode** (Coming Soon)
```bash
nix run .#myhost-enable-dual-mode  
```

## Current Status

✅ **New hosts**: Dual keys by default  
✅ **Existing hosts**: Phase 1 preparation ready  
✅ **Phase 2**: Use your normal deployment - runtime key installs automatically  
🚧 **Migration**: Phase 3 (`enable-dual-mode`) coming soon

## Backward Compatibility

Existing hosts continue working unchanged. This is not a breaking change.

For single key mode (if needed):
```bash
nix run skarabox#gen-new-host -- --single-key -n myhost
```