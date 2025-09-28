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

**Phase 2: Deploy Normally**
```bash
colmena deploy
# or
nix run .#myhost-install-on-beacon
```

The runtime key installs automatically via skarabox's built-in activation scripts.

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