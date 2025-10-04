# Skarabox Knowledge Dump for LLM Context Bootstrap

**Date Created**: September 20, 2025
**Purpose**: Preserve full LLM context when transitioning to homelab repo setup

## User Profile & Requirements

### Background
- **New to Nix** but has strong opinions on desired setup
- Wants to **deploy on own hardware and VMs**
- Wants **different hosts with shared configurations** but ability to customize per-host
- Interested in **contributing/tweaking** Skarabox, possibly as Git worktree
- Plans to use for **homelab management** with independent Git history

### Specific Interests
- **Lanzaboote instead of GRUB** - wants secure boot capability
- **Remote SSH unlock** - questioning if mandatory, wants alternatives
- **nix-community/impermanence** - wants proper persistence management
- **Customization points** - understanding what can be overridden

## Skarabox Architecture Understanding

### What Skarabox Is
- **NixOS flake template** for "fastest way to install NixOS on server with batteries included"
- **Opinionated automation** combining multiple tools into cohesive system
- **Targets NAS users** specifically, not general homelab
- **Three main components**: Beacon, Flake Module, NixOS Module

### Core Components

#### 1. Beacon System
- Creates **bootable ISO** for USB installation on on-premise servers
- **VM testing environment** with proper disk layout simulation
- Sets up **WiFi hotspot** with SSID "Skarabox" for installation access
- **Static IP assignment** matching target server configuration

#### 2. Flake Module (`flakeModules/default.nix`)
- Integrates with **flake-parts** for managing multiple servers
- Commands like `nix run .#gen-new-host <hostname>` for setup
- **SOPS secrets management** - creates keys, encrypts files
- **SSH key management** - host keys, authorized keys, known_hosts
- **Multi-host coordination** - synchronizes config between beacon and targets

#### 3. NixOS Module
- **nixos-anywhere** for headless installation
- **ZFS with native encryption** for OS and data pools
- **Disk mirroring (RAID1)** using ZFS
- **Remote root pool decryption** via SSH
- **nixos-facter** for hardware detection
- **SOPS-nix** for secrets management

### Hardware Requirements
- **1-2 SSD/NVMe drives** for OS (mirrored if 2 drives)
- **0-2 Hard drives** for data storage (mirrored if 2 drives)
- ⚠️ **All disks completely wiped** during installation

## Key Customization Findings

### Bootloader Customization ✅ POSSIBLE
```nix
# Can replace GRUB with lanzaboote
{
  boot.loader.grub.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/etc/secureboot";
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
}
```

### SSH Remote Unlock ✅ OPTIONAL
- **Can be disabled** entirely by disabling bootssh.nix module
- **Console unlock** available by disabling initrd.network
- **Alternative unlock mechanisms** possible (TPM, YubiKey, etc.)

### Multi-Host Configuration Patterns
```nix
# Shared configuration via nixosModules
flake = {
  nixosModules = {
    common = { /* shared settings */ };
    server1 = { imports = [ ./server1/configuration.nix ]; };
  };
};

skarabox.hosts = {
  server1 = {
    modules = [
      self.nixosModules.common  # Shared
      self.nixosModules.server1 # Host-specific
      { skarabox.disks.dataPool.enable = false; } # Overrides
    ];
  };
};
```

### Extension Points
- **Module-level overrides** using `lib.mkForce`
- **Nixpkgs patching** per host
- **Custom modules** in `extraBeaconModules`
- **SOPS secrets** management with per-host files

## Critical Issue: Impermanence Gap

### Problem Identified
Skarabox implements "erase your darlings" but **doesn't properly handle system persistence**:

#### What Gets Persisted (by default)
```nix
"local/nix" = {          # /nix - Nix store ✅
  mountpoint = "/nix";
};
"safe/home" = {          # /home - User directories ✅
  mountpoint = "/home";
};
"safe/persist" = {       # /persist - Only data_passphrase ⚠️
  mountpoint = "/persist";
};
```

#### What Gets ERASED Every Boot ❌
- `/var/log` - All system logs
- `/var/lib/nixos` - NixOS state (machine-id, etc.)
- `/var/lib/systemd` - systemd state
- `/etc/machine-id` - System identity
- `/var/lib/<service>` - All service data
- Network Manager connections
- DHCP leases

### Why This is Problematic
- **Services lose state** every reboot
- **No persistent logging** (journalctl previous boots unavailable)
- **Network configuration issues** (WiFi passwords forgotten)
- **Certificate renewals break** (ACME state lost)
- **Any service using /var/lib breaks**

### Solution: Impermanence Required
```nix
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
      "/var/lib/acme"
      "/var/lib/postgresql"
      "/var/lib/containers"
    ];
    files = [
      "/etc/machine-id"
    ];
  };
}
```

## ZFS vs tmpfs for Root

### Skarabox's Choice: ZFS Rollback
```nix
# Creates snapshot during installation
"local/root" = {
  type = "zfs_fs";
  mountpoint = "/";
  postCreateHook = "zfs snapshot ${cfg.rootPool}/local/root@blank";
};

# Rolls back on every boot
boot.initrd.postResumeCommands = ''
  zfs rollback -r ${cfg.rootPool}/local/root@blank
'';
```

### Why Not tmpfs?
- **No size limitations** (tmpfs limited by RAM)
- **Performance suitable** for server workloads
- **Consistency with ZFS ecosystem** (encryption, snapshots, etc.)
- **Snapshot capabilities** for manual rollbacks
- **Encrypted ephemeral data** (tmpfs wouldn't be encrypted)

### Could Use tmpfs Instead
```nix
# Override Skarabox's approach
{
  boot.initrd.postResumeCommands = lib.mkForce "";
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "defaults" "size=8G" "mode=755" ];
  };
}
```

## Planned Homelab Setup

### Target Structure
```
/Users/daniel.vicory/src/homelab/           # Main homelab repo
├── .git/                                   # Independent Git history
├── flake.nix                              # Main homelab flake
├── skarabox/                              # Git worktree of skarabox
│   ├── .git                               # Points to skarabox repo
│   ├── modules/                           # Can modify for customization
│   └── ...
├── servers/
│   ├── nas1/
│   ├── nas2/
│   └── shared/
├── nixos-modules/                         # Custom NixOS modules
└── README.md
```

### Homelab Flake Pattern
```nix
{
  inputs = {
    skarabox.url = "path:./skarabox";  # Local worktree
    impermanence.url = "github:nix-community/impermanence";
  };
  
  outputs = inputs@{ skarabox, ... }: {
    imports = [ skarabox.flakeModules.default ];
    skarabox.hosts = {
      nas1 = {
        modules = [
          ./servers/nas1/configuration.nix
          ./nixos-modules/impermanence.nix  # Fix persistence gap
        ];
      };
    };
  };
}
```

### Development Workflow
```bash
# Normal homelab work
cd /Users/daniel.vicory/src/homelab
vim servers/nas1/configuration.nix

# Skarabox modifications
cd skarabox/
git checkout -b my-improvements
vim modules/disks.nix
cd ..
nix flake check  # Test immediately
```

## Current Status
- Located in `/Users/daniel.vicory/src/skarabox` (upstream clone)
- Need to transition to homelab repo with skarabox as worktree
- Planning to add impermanence for proper system persistence
- Want to customize bootloader (lanzaboote) and other components
- Goal: Single VS Code workspace with full development context

## Key Files Analyzed
- `/modules/configuration.nix` - Main NixOS module with options
- `/modules/disks.nix` - ZFS setup, encryption, disk layout
- `/modules/bootssh.nix` - SSH unlock configuration
- `/flakeModules/default.nix` - Flake module for multi-host management
- `/template/flake.nix` - Example deployment configuration
- `/docs/architecture.md` - Detailed architecture documentation

## Commands and Utilities Available
- `nix run .#gen-new-host <name>` - Create new host
- `nix run .#<host>-ssh` - SSH to host
- `nix run .#<host>-unlock` - Decrypt root partition
- `nix run .#<host>-beacon-vm` - Test installation in VM
- `nix run .#deploy-rs` or `nix run .#colmena` - Deploy changes

## Next Actions Planned
1. Set up homelab repo structure
2. Add skarabox as worktree
3. Configure flake to use local skarabox
4. Add impermanence for proper persistence
5. Test lanzaboote integration
6. Validate development workflow

---

**Instructions for New LLM Session:**
This user understands Nix concepts but is new to the ecosystem. They want a robust homelab setup with Skarabox as foundation but need proper customization. Key focus areas:
1. Help with homelab repo setup and worktree management
2. Impermanence integration (critical for production use)
3. Bootloader customization (lanzaboote)
4. Multi-host configuration patterns
5. Development workflow for contributing back to Skarabox

The user values thorough understanding over quick solutions and prefers to understand the "why" behind architectural decisions.