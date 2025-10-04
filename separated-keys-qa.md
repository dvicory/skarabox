# Separated-Key Architecture QA Test Plan

**Feature Under Test:** Separated-key architecture for SSH host keys
- Boot key: Used only for initrd unlock (stored unencrypted on /boot)
- Runtime key: Used for SOPS encryption (stored in encrypted ZFS pool)
- Security benefit: Physical access to server cannot compromise SOPS secrets

**Test Environment:** VM with snapshot capability
**Date Started:** 2025-10-03
**Branch Under Test:** `protected-sops-key`

---

## 🚀 Test Setup & Prerequisites

Before running any tests, you must set up the test environment with the Skarabox flake pointing to the correct branch.

### Initial Environment Setup

1. **Create a clean test directory:**
   ```bash
   mkdir ~/skarabox-qa
   cd ~/skarabox-qa
   ```

2. **Bootstrap a new Skarabox repository from the protected-sops-key branch:**
   ```bash
   nix run github:dvicory/skarabox/protected-sops-key#init -- -n testhost
   ```
   
   When prompted:
   - Enter a password for the admin user (remember this for SSH later)
   - This will create:
     - `testhost/` directory with configuration files
     - `.sops.yaml` with SOPS configuration
     - `sops.key` (your main SOPS key)
     - `flake.nix` pre-configured

3. **Verify the generated files:**
   ```bash
   ls -la
   # Expected:
   # - flake.nix
   # - .sops.yaml
   # - sops.key
   # - testhost/ (directory)
   
   ls -la testhost/
   # Expected:
   # - configuration.nix
   # - host_key + host_key.pub
   # - runtime_host_key + runtime_host_key.pub (if separated-key mode)
   # - secrets.yaml
   # - hostid
   ```

4. **Configure VM network settings in flake.nix:**
   ```nix
   # Edit flake.nix, find the skarabox.hosts.testhost section:
   skarabox.hosts.testhost = {
     system = "x86_64-linux";
     ip = "192.168.1.30";  # VM will use this IP
     # ... other settings
   };
   ```

5. **Generate known_hosts file:**
   ```bash
   nix run .#testhost-gen-knownhosts-file
   cat testhost/known_hosts
   # Expected: SSH host key fingerprints for boot and runtime ports
   ```

6. **Initialize git repository (required for flake):**
   ```bash
   git init
   git add .
   git commit -m "Initial test setup"
   ```

7. **Start the test VM:**
   ```bash
   nix run .#testhost-beacon-vm &
   # VM will start in background with 4 disks:
   # - /dev/nvme0, /dev/nvme1 (for root pool mirror)
   # - /dev/sda, /dev/sdb (for data pool mirror)
   ```

8. **Wait for VM to boot (check for login prompt in VM window)**
   - You should see auto-login as the configured username
   - The beacon will show instructions on first boot

9. **Get hardware configuration from beacon:**
   ```bash
   nix run .#testhost-get-facter > testhost/facter.json
   git add testhost/facter.json
   git commit -m "Add hardware config"
   ```

10. **Run the installer:**
    ```bash
    nix run .#testhost-install-on-beacon
    # This will:
    # - Connect to beacon
    # - Partition disks
    # - Create ZFS pools
    # - Install NixOS
    # - Copy SSH keys (including runtime key if separated-key mode)
    # - Reboot into installed system
    ```

11. **Wait for reboot, then unlock the encrypted root pool:**
    ```bash
    # Wait ~30 seconds for reboot to complete
    nix run .#testhost-unlock
    # Enter the root passphrase from secrets.yaml when prompted
    # Connection will close automatically after unlock
    ```

12. **Wait for boot to complete (~30 seconds), then SSH in:**
    ```bash
    nix run .#testhost-ssh
    # Should connect successfully
    # Verify separated-key mode is active:
    sudo systemctl status sops-nix
    # Should show secrets loaded successfully
    ```

13. **Create a VM snapshot (IMPORTANT for test rollback):**
    ```bash
    # If using QEMU directly, snapshot the disk images in .skarabox-tmp/
    # If using virt-manager or similar, create snapshot named "base-install"
    # This allows rollback between tests
    ```

### Prerequisites Checklist

Before starting each test case, verify:
- ✅ Skarabox flake is on `protected-sops-key` branch
- ✅ VM is running and accessible
- ✅ You can successfully run `nix run .#<hostname>-ssh`
- ✅ You can successfully run `nix run .#<hostname>-unlock` after reboot
- ✅ Git repository is initialized and changes are committed
- ✅ You have a VM snapshot to rollback to

### Common VM Operations

**Reboot VM:**
```bash
nix run .#<hostname>-ssh -- sudo reboot
# Wait ~30 seconds
nix run .#<hostname>-unlock  # Unlock encrypted root
# Wait ~30 seconds for full boot
nix run .#<hostname>-ssh     # SSH back in
```

**Stop VM:**
```bash
# Find the QEMU process
ps aux | grep qemu
# Kill it
kill <pid>
```

**Restart VM from snapshot:**
```bash
# Restore VM disk images from backup
# Or use VM manager's snapshot restore feature
nix run .#<hostname>-beacon-vm &
```

**Check SOPS secrets:**
```bash
nix run .#<hostname>-ssh -- "sudo systemctl status sops-nix"
nix run .#<hostname>-ssh -- "ls -la /run/secrets/"
```

**View SOPS configuration locally:**
```bash
cat .sops.yaml
# Check which keys are configured for each host
```

**Decrypt secrets locally (testing):**
```bash
# IMPORTANT: Use PRIVATE keys, not public keys!
# Run from /tmp to avoid falling back to sops.key file

# With boot key (single-key mode only - will fail on separated-key):
cd /tmp
boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/path/to/<hostname>/host_key)
SOPS_AGE_KEY="$boot_age_key" nix run ~/path/to/project#sops -- -d ~/path/to/<hostname>/secrets.yaml

# With runtime key (separated-key mode):
cd /tmp
runtime_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/path/to/<hostname>/runtime_host_key)
SOPS_AGE_KEY="$runtime_age_key" nix run ~/path/to/project#sops -- -d ~/path/to/<hostname>/secrets.yaml
```

---

## Test Case Matrix

| Test ID | Scenario | Boot Key | Runtime Key | SOPS Uses | Migration Path |
|---------|----------|----------|-------------|-----------|----------------|
| fresh-separated | Fresh install (separated-key, default) | ✓ | ✓ | Runtime | N/A |
| fresh-single | Fresh install (single-key, legacy) | ✓ | ✗ | Boot | N/A |
| migrate-separated | Migration: single-key → separated-key | ✓ | ✓ | Boot → Runtime | enable-key-separation |
| rotate-boot | Boot key rotation (separated-key) | rotate | ✓ | Runtime | rotate-boot-key |
| rotate-runtime | Runtime key rotation (separated-key) | ✓ | rotate | Runtime | manual |
| deploy-deployrs | Deploy-rs deployment (separated-key) | ✓ | ✓ | Runtime | N/A |
| deploy-colmena | Colmena deployment (separated-key) | ✓ | ✓ | Runtime | N/A |

---

## fresh-separated: Fresh Install - Separated-Key Mode (Default)

**Objective:** Verify that new hosts default to separated-key architecture with proper key separation and SOPS configuration.

**Prerequisites:**
- Complete "Test Setup & Prerequisites" section above
- Have a working base installation with testhost
- VM snapshot of base installation

**Test Steps:**

### Phase 1: Initial Setup
1. **Start fresh - restore VM snapshot or create new test directory:**
   ```bash
   # Option A: Rollback existing VM to base snapshot
   # (Restore .skarabox-tmp/*.qcow2 files from backup)
   
   # Option B: Start completely fresh
   cd ~
   mkdir skarabox-qa-freshsep
   cd skarabox-qa-freshsep
   ```

2. **Bootstrap new repository with separated-key host (default):**
   ```bash
   # If starting fresh without existing flake.nix/.sops.yaml:
   nix run github:dvicory/skarabox/protected-sops-key#init -- -n freshsep
   
   # OR if you already have a project (flake.nix/.sops.yaml exist):
   nix run github:dvicory/skarabox/protected-sops-key#gen-new-host -- -n freshsep
   
   # Enter password when prompted
   # This will create freshsep/ with separated-key mode by default
   ```

3. **Verify separated-key files created:**
   ```bash
   ls -la freshsep/
   # Expected files:
   # - host_key (boot key private)
   # - host_key.pub (boot key public)
   # - runtime_host_key (runtime key private)
   # - runtime_host_key.pub (runtime key public)
   # - secrets.yaml
   # - configuration.nix
   # - hostid
   ```

4. **Verify SOPS configuration:**
   ```bash
   cat .sops.yaml | grep -A10 freshsep
   # Expected: Only runtime key listed
   # - freshsep: <age_key> (runtime key for SOPS)
   # Note: Boot key is NOT in SOPS config (security feature)
   ```

5. **Check flake.nix - verify runtimeHostKeyPub is configured:**
   ```bash
   grep -A5 "skarabox.hosts.freshsep" flake.nix
   # Expected: Should see runtimeHostKeyPub = ./freshsep/runtime_host_key.pub;
   ```

6. **Verify configuration uses runtime key for SOPS:**
   ```bash
   grep -A2 "sops.age.sshKeyPaths" freshsep/configuration.nix
   # Expected: Comment says "Separated-key mode: SOPS uses secure runtime key"
   # Expected: Path is /persist/etc/ssh/ssh_host_ed25519_key (runtime key location)
   ```

7. **Configure VM network settings:**
   ```bash
   # Edit flake.nix, update:
   # skarabox.hosts.freshsep.system = "x86_64-linux";
   # skarabox.hosts.freshsep.ip = "192.168.1.30";
   ```

8. **Initialize git repository:**
   ```bash
   git init
   git add .
   git commit -m "Initial freshsep setup"
   ```

### Phase 2: Deployment
9. **Generate known_hosts:**
   ```bash
   nix run .#freshsep-gen-knownhosts-file
   cat freshsep/known_hosts
   # Expected: 2 entries (boot port with boot key, ssh port with runtime key)
   # Format should be: [ip]:port <key_type> <key>
   ```

10. **Start VM:**
    ```bash
    nix run .#freshsep-beacon-vm &
    # Wait for VM to boot and show login prompt
    ```

11. **Get hardware configuration:**
    ```bash
    nix run .#freshsep-get-facter > freshsep/facter.json
    git add freshsep/facter.json
    git commit -m "Add hardware config"
    ```

12. **Deploy to beacon:**
    ```bash
    nix run .#freshsep-install-on-beacon
    # Monitor output - should see:
    # - Disk partitioning
    # - ZFS pool creation
    # - NixOS installation
    # - "Copying extra file /tmp/runtime_host_key" (KEY VERIFICATION)
    # - Automatic reboot
    ```

13. **Wait for reboot (~30 seconds), then unlock:**
    ```bash
    nix run .#freshsep-unlock
    # Enter root passphrase from secrets.yaml
    # Connection will close after successful unlock
    ```

14. **Wait for full boot (~30 seconds), then SSH in:**
    ```bash
    nix run .#freshsep-ssh -- echo "runtime key works"
    # Expected: Connection succeeds with runtime key
    ```

15. **Verify boot SSH also works:**
    ```bash
    nix run .#freshsep-boot-ssh -- echo "boot key works"
    # Expected: Connection succeeds with boot key
    # Note: This uses the initrd SSH, which runs on different port
    ```

### Phase 3: SOPS Verification (Critical Security Tests)
16. **Verify SOPS secrets loaded on host:**
    ```bash
    nix run .#freshsep-ssh -- "sudo systemctl status sops-nix"
    # Expected: Active (exited) with success
    
    nix run .#freshsep-ssh -- "ls -la /run/secrets/"
    # Expected: Should see secrets directory structure
    
    nix run .#freshsep-ssh -- "sudo cat /run/secrets/freshsep/user/hashedPassword"
    # Expected: Password hash visible (proves SOPS working)
    ```

17. **Verify runtime key location on host:**
    ```bash
    nix run .#freshsep-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
    # Expected: File exists with 600 permissions
    # This is the runtime key used by SOPS
    
    nix run .#freshsep-ssh -- "ls -la /boot/host_key"
    # Expected: File exists with 600 permissions
    # This is the boot key (should NOT be used for SOPS)
    ```

18. **🔒 SECURITY TEST: Verify boot key CANNOT decrypt secrets (CRITICAL):**
    ```bash
    # IMPORTANT: Run from /tmp to avoid falling back to sops.key file
    cd /tmp
    
    # Convert boot key PRIVATE key to age format and try to decrypt
    boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsep/freshsep/host_key)
    SOPS_AGE_KEY="$boot_age_key" nix run ~/skarabox-qa-freshsep#sops -- -d ~/skarabox-qa-freshsep/freshsep/secrets.yaml
    
    # Expected: FAILS with "no key could decrypt the data key"
    # This proves boot key (accessible from /boot) cannot compromise secrets
    
    # Return to work directory
    cd ~/skarabox-qa-freshsep
    ```

19. **✅ Verify runtime key CAN decrypt secrets:**
    ```bash
    # Convert runtime key PRIVATE key to age format and decrypt
    runtime_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i freshsep/runtime_host_key)
    
    # Run from /tmp to ensure we're only using the specified key
    cd /tmp
    SOPS_AGE_KEY="$runtime_age_key" nix run ~/skarabox-qa-freshsep#sops -- -d ~/skarabox-qa-freshsep/freshsep/secrets.yaml
    
    # Expected: SUCCESS - secrets visible
    # This proves runtime key (in encrypted pool) works correctly
    
    # Return to work directory
    cd ~/skarabox-qa-freshsep
    ```

### Phase 4: Reboot Persistence Test
20. **Reboot and verify separated-key mode persists:**
    ```bash
    nix run .#freshsep-ssh -- sudo reboot
    # Wait ~30 seconds for reboot
    ```

21. **Unlock root pool:**
    ```bash
    nix run .#freshsep-unlock
    # Enter root passphrase
    # Connection closes automatically
    # Wait ~30 seconds for boot completion
    ```

22. **Verify SOPS still works after reboot:**
    ```bash
    nix run .#freshsep-ssh -- "sudo systemctl status sops-nix"
    # Expected: Active (exited) with success
    
    nix run .#freshsep-ssh -- "sudo cat /run/secrets/freshsep/user/hashedPassword"
    # Expected: Password hash visible
    ```

23. **Verify runtime key still in place:**
    ```bash
    nix run .#freshsep-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
    # Expected: File exists
    ```

**Expected Results:**
- ✅ Separated-key mode enabled by default
- ✅ Two SSH keys generated (boot + runtime)
- ✅ SOPS configured with runtime key as primary
- ✅ Runtime key installed during deployment
- ✅ Both keys work for their respective purposes
- ✅ SOPS secrets only decrypt with runtime key (security verified)
- ✅ Configuration survives reboot

**Actual Results:**
- [ ] Test not yet run

---

## fresh-single: Fresh Install - Single-Key Mode (Legacy)

**Objective:** Verify backward compatibility with single-key architecture.

**Prerequisites:**
- Complete "Test Setup & Prerequisites" section
- Can reuse VM from fresh-separated test OR start fresh

**Test Steps:**

### Phase 1: Initial Setup
1. **Start fresh:**
   ```bash
   cd ~
   mkdir skarabox-qa-freshsingle
   cd skarabox-qa-freshsingle
   ```

2. **Generate new host with --single-key flag:**
   ```bash
   nix run github:dvicory/skarabox/protected-sops-key#gen-new-host -- -n freshsingle --single-key
   # Enter password when prompted
   # Note the --single-key flag explicitly requests legacy mode
   ```

3. **Verify single-key files created:**
   ```bash
   ls -la freshsingle/
   # Expected files:
   # - host_key (single key private)
   # - host_key.pub (single key public)
   # - NO runtime_host_key files (KEY DIFFERENCE)
   # - secrets.yaml
   # - configuration.nix
   # - hostid
   ```

4. **Verify SOPS configuration (single key only):**
   ```bash
   cat .sops.yaml | grep -A5 freshsingle
   # Expected: Only ONE key listed
   # - freshsingle: <age_key> (boot key used for SOPS)
   # No _boot alias, no runtime key
   ```

5. **Check flake.nix - verify NO runtimeHostKeyPub:**
   ```bash
   grep -A5 "skarabox.hosts.freshsingle" flake.nix
   # Expected: Should NOT see runtimeHostKeyPub line
   ```

6. **Verify configuration uses boot key for SOPS:**
   ```bash
   grep -A2 "sops.age.sshKeyPaths" freshsingle/configuration.nix
   # Expected: Comment says "Single-key mode: SOPS uses boot key (less secure)"
   # Expected: Path is /boot/host_key
   ```

7. **Configure VM network settings:**
   ```bash
   # Edit flake.nix, update:
   # skarabox.hosts.freshsingle.system = "x86_64-linux";
   # skarabox.hosts.freshsingle.ip = "192.168.1.30";
   ```

8. **Initialize git repository:**
   ```bash
   git init
   git add .
   git commit -m "Initial freshsingle setup (single-key mode)"
   ```

### Phase 2: Deployment & Verification
9. **Generate known_hosts:**
   ```bash
   nix run .#freshsingle-gen-knownhosts-file
   cat freshsingle/known_hosts
   # Expected: 2 entries with SAME KEY for both ports
   # [192.168.1.30]:2223 ssh-ed25519 AAAA... (boot port)
   # [192.168.1.30]:2222 ssh-ed25519 AAAA... (ssh port)
   # The keys should be identical!
   ```

10. **Start VM:**
    ```bash
    nix run .#freshsingle-beacon-vm &
    # Wait for VM to boot
    ```

11. **Get hardware configuration:**
    ```bash
    nix run .#freshsingle-get-facter > freshsingle/facter.json
    git add freshsingle/facter.json
    git commit -m "Add hardware config"
    ```

12. **Deploy to beacon:**
    ```bash
    nix run .#freshsingle-install-on-beacon
    # Monitor: Should NOT see "Copying extra file /tmp/runtime_host_key"
    # (no runtime key in single-key mode)
    ```

13. **Wait for reboot, then unlock:**
    ```bash
    nix run .#freshsingle-unlock
    # Enter root passphrase
    ```

14. **SSH in:**
    ```bash
    nix run .#freshsingle-ssh -- echo "single key works"
    # Expected: Success
    ```

15. **Verify SOPS works:**
    ```bash
    nix run .#freshsingle-ssh -- "sudo systemctl status sops-nix"
    # Expected: Active
    
    nix run .#freshsingle-ssh -- "sudo cat /run/secrets/freshsingle/user/hashedPassword"
    # Expected: Password hash visible
    ```

16. **Verify key locations:**
    ```bash
    nix run .#freshsingle-ssh -- "ls -la /boot/host_key"
    # Expected: File exists (used for both boot AND SOPS)
    
    nix run .#freshsingle-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
    # Expected: File does NOT exist (no runtime key)
    ```

17. **⚠️ VULNERABILITY TEST: Verify boot key CAN decrypt secrets:**
    ```bash
    # Run from /tmp to ensure clean test environment
    cd /tmp
    boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/host_key)
    SOPS_AGE_KEY="$boot_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
    
    # Expected: SUCCESS (demonstrates vulnerability!)
    # In single-key mode, anyone with physical access to /boot
    # can extract host_key and decrypt all secrets
    
    cd ~/skarabox-qa-freshsingle
    ```

**Expected Results:**
- ✅ Single-key mode works when explicitly requested
- ✅ Only one SSH key generated
- ✅ SOPS configured with boot key
- ✅ Boot key works for both boot unlock and SSH
- ✅ SOPS secrets decrypt with boot key (vulnerable to physical access)

**Actual Results:**
- [ ] Test not yet run

---

## migrate-separated: Migration - Single-Key → Separated-Key

**Objective:** Verify complete migration workflow from legacy single-key to secure separated-key architecture.

**Prerequisites:**
- VM from fresh-single with working single-key host (snapshot: `migrate-separated-base`)
- Host fully deployed and operational

**Test Steps:**

### Phase 1: Pre-Migration State
1. **Create VM snapshot:** `migrate-separated-base` (fresh-single host running)

2. **Verify current single-key state:**
   ```bash
   ls -la freshsingle/ | grep runtime
   # Expected: No runtime key files
   
   nix run .#freshsingle-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
   # Expected: File does not exist
   
   grep runtimeHostKeyPub flake.nix
   # Expected: No entry for freshsingle
   ```

3. **Document current SOPS key setup:**
   ```bash
   cat .sops.yaml | grep -A5 freshsingle
   # Expected: Single key (boot key)
   ```

### Phase 2: Generate Runtime Keys
4. **Run enable-key-separation:**
   ```bash
   nix run .#freshsingle-enable-key-separation
   # Expected output:
   # - Runtime keys generated
   # - SOPS config updated
   # - Boot key renamed to freshsingle_boot (alias)
   # - Runtime key added as freshsingle (primary)
   # - Secrets re-encrypted
   ```

5. **Verify new files created:**
   ```bash
   ls -la freshsingle/
   # Expected: runtime_host_key and runtime_host_key.pub now exist
   ```

6. **Verify SOPS config updated:**
   ```bash
   cat .sops.yaml | grep -A10 freshsingle
   # Expected: Two keys now
   # - freshsingle_boot: <boot_key_age> (aliased)
   # - freshsingle: <runtime_key_age> (primary, no '&' suffix)
   ```

7. **Verify secrets re-encrypted:**
   ```bash
   # Both keys should be able to decrypt (during migration period)
   # Run from /tmp for clean test environment
   cd /tmp
   
   # Test boot key (use PRIVATE key)
   boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/host_key)
   SOPS_AGE_KEY="$boot_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
   # Expected: SUCCESS (boot key still works during migration)
   
   # Test runtime key (use PRIVATE key)
   runtime_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/runtime_host_key)
   SOPS_AGE_KEY="$runtime_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
   # Expected: SUCCESS (runtime key works)
   
   cd ~/skarabox-qa-freshsingle
   ```

### Phase 3: Install Runtime Key
8. **Run install-runtime-key:**
   ```bash
   nix run .#freshsingle-install-runtime-key
   # Expected: Key copied to target host at /tmp/runtime_host_key
   ```

9. **Verify key installed but not active:**
   ```bash
   nix run .#freshsingle-ssh -- "ls -la /tmp/runtime_host_key"
   # Expected: File exists
   
   nix run .#freshsingle-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
   # Expected: File does not exist yet (activation script hasn't run)
   ```

### Phase 4: Update Configuration
10. **Update freshsingle/configuration.nix:**
    ```nix
    # Change from:
    sops.age.sshKeyPaths = [ "/boot/host_key" ];
    
    # To:
    sops.age.sshKeyPaths = [ "/persist/etc/ssh/ssh_host_ed25519_key" ];
    ```

11. **Update flake.nix:**
    ```nix
    skarabox.hosts.freshsingle = {
      # ... existing config
      runtimeHostKeyPub = ./freshsingle/runtime_host_key.pub;  # ADD THIS LINE
    };
    ```

### Phase 5: Deploy Separated-Key Configuration
12. **Regenerate known_hosts:**
    ```bash
    nix run .#freshsingle-gen-knownhosts-file
    cat freshsingle/known_hosts
    # Expected: 2 entries with DIFFERENT keys (boot vs runtime)
    ```

13. **Deploy configuration:**
    ```bash
    nix run .#deploy-rs
    # Expected: Successful deployment
    # Activation script should move /tmp/runtime_host_key to /persist/etc/ssh/ssh_host_ed25519_key
    ```

14. **Verify runtime key activated:**
    ```bash
    nix run .#freshsingle-ssh -- "ls -la /persist/etc/ssh/ssh_host_ed25519_key"
    # Expected: File exists with correct permissions (600)
    
    nix run .#freshsingle-ssh -- "sudo systemctl restart sops-nix"
    nix run .#freshsingle-ssh -- "sudo systemctl status sops-nix"
    # Expected: SOPS using runtime key successfully
    ```

15. **Verify both SSH keys still work:**
    ```bash
    nix run .#freshsingle-boot-ssh -- echo "boot key works"
    # Expected: Success
    
    nix run .#freshsingle-ssh -- echo "runtime key works"
    # Expected: Success
    ```

### Phase 6: Remove Boot Key from SOPS
16. **Remove boot key from SOPS:**
    ```bash
    age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age < freshsingle/host_key.pub)
    nix run .#sops -- -r -i --rm-age "$age_key" freshsingle/secrets.yaml
    # Expected: Boot key removed, secrets re-encrypted with runtime key only
    ```

17. **Verify boot key can NO LONGER decrypt:**
    ```bash
    # Run from /tmp for clean test
    cd /tmp
    boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/host_key)
    SOPS_AGE_KEY="$boot_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
    # Expected: FAILS with "no key could decrypt the data key" - security achieved!
    cd ~/skarabox-qa-freshsingle
    ```

18. **Verify runtime key STILL decrypts:**
    ```bash
    cd /tmp
    runtime_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/runtime_host_key)
    SOPS_AGE_KEY="$runtime_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
    # Expected: SUCCESS
    cd ~/skarabox-qa-freshsingle
    ```

### Phase 7: Rotate Boot Key (Security Hardening)
19. **Run rotate-boot-key:**
    ```bash
    nix run .#freshsingle-rotate-boot-key
    # Expected: Confirmation prompt
    # - Backs up boot files to tmpfs
    # - Wipes boot partition with dd + TRIM
    # - Recreates filesystem
    # - Generates new boot key
    # - Reinstalls bootloader
    # - Updates known_hosts
    ```

20. **Verify old boot key files replaced:**
    ```bash
    ls -la freshsingle/host_key*
    # Expected: host_key files have new timestamps
    
    # Compare old vs new key
    # (Save old key before rotation for comparison)
    diff freshsingle/host_key.pub freshsingle/host_key.pub.backup
    # Expected: Different keys
    ```

21. **Regenerate known_hosts:**
    ```bash
    nix run .#freshsingle-gen-knownhosts-file
    ```

22. **Verify boot unlock still works with new key:**
    ```bash
    nix run .#freshsingle-ssh -- sudo reboot
    # Wait for boot
    nix run .#freshsingle-unlock
    # Expected: Unlocks successfully
    
    nix run .#freshsingle-boot-ssh -- echo "new boot key works"
    # Expected: Success
    ```

23. **Verify old boot key in git history is useless:**
    ```bash
    # Try to decrypt with old boot key (from backup or git history)
    cd /tmp
    old_boot_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsingle/freshsingle/host_key.backup)
    SOPS_AGE_KEY="$old_boot_age_key" nix run ~/skarabox-qa-freshsingle#sops -- -d ~/skarabox-qa-freshsingle/freshsingle/secrets.yaml
    # Expected: FAILS with "no key could decrypt the data key" - old key is worthless
    cd ~/skarabox-qa-freshsingle
    
    # Try to SSH with old boot key
    ssh -i freshsingle/host_key.backup -p <boot_port> root@<ip>
    # Expected: FAILS - key rejected
    ```

### Phase 8: Final Verification
24. **Reboot and full unlock test:**
    ```bash
    nix run .#freshsingle-ssh -- sudo reboot
    nix run .#freshsingle-unlock
    nix run .#freshsingle-ssh -- "sudo systemctl status sops-nix"
    # Expected: All working with separated keys
    ```

25. **Verify SOPS secrets accessible:**
    ```bash
    nix run .#freshsingle-ssh -- "sudo cat /run/secrets/freshsingle/user/hashedPassword"
    # Expected: Password hash visible
    ```

**Expected Results:**
- ✅ Migration completes without errors
- ✅ Runtime key generates and installs correctly
- ✅ SOPS transitions from boot key to runtime key
- ✅ Both keys work after initial migration
- ✅ Boot key removal prevents decryption (security goal)
- ✅ Boot key rotation completes successfully
- ✅ Old boot key (from git history) cannot unlock or decrypt
- ✅ System fully functional after complete migration

**Actual Results:**
- [ ] Test not yet run

---

## rotate-boot: Boot Key Rotation (Separated-Key Host)

**Objective:** Verify boot key rotation on a separated-key host (standalone, not part of migration).

**Prerequisites:**
- VM from fresh-separated with working separated-key host (snapshot: `rotate-boot-base`)

**Test Steps:**

1. **Create VM snapshot:** `rotate-boot-base` (TC-01 host running)

2. **Back up current boot key for comparison:**
   ```bash
   cp freshsep/host_key freshsep/host_key.backup
   cp freshsep/host_key.pub freshsep/host_key.pub.backup
   ```

3. **Run rotate-boot-key:**
   ```bash
   nix run .#freshsep-rotate-boot-key
   # Expected: Confirmation prompt, then rotation
   ```

4. **Verify key changed:**
   ```bash
   diff freshsep/host_key.pub freshsep/host_key.pub.backup
   # Expected: Different
   ```

5. **Regenerate known_hosts:**
   ```bash
   nix run .#freshsep-gen-knownhosts-file
   ```

6. **Test boot unlock:**
   ```bash
   nix run .#freshsep-ssh -- sudo reboot
   nix run .#freshsep-unlock
   nix run .#freshsep-boot-ssh -- echo "new boot key works"
   ```

7. **Verify SOPS still works (unaffected by boot key rotation):**
   ```bash
   nix run .#freshsep-ssh -- "sudo systemctl status sops-nix"
   # Expected: SOPS still using runtime key, unaffected
   ```

**Expected Results:**
- ✅ Boot key rotates successfully
- ✅ Boot unlock works with new key
- ✅ Old boot key rejected
- ✅ Runtime key and SOPS unaffected

**Actual Results:**
- [ ] Test not yet run

---

## rotate-runtime: Runtime Key Rotation (Separated-Key Host)

**Objective:** Verify runtime key rotation affects SOPS but not boot unlock.

**Prerequisites:**
- VM from fresh-separated with working separated-key host (snapshot: `rotate-runtime-base`)

**Test Steps:**

1. **Create VM snapshot:** `rotate-runtime-base` (TC-01 host running)

2. **Back up current runtime key:**
   ```bash
   cp freshsep/runtime_host_key freshsep/runtime_host_key.backup
   cp freshsep/runtime_host_key.pub freshsep/runtime_host_key.pub.backup
   ```

3. **Generate new runtime key:**
   ```bash
   ssh-keygen -t ed25519 -N "" -f freshsep/runtime_host_key
   ```

4. **Update SOPS configuration:**
   ```bash
   nix run .#add-sops-cfg -- -o .sops.yaml alias freshsep $(ssh-to-age -i freshsep/runtime_host_key.pub)
   ```

5. **Re-encrypt secrets:**
   ```bash
   nix run .#sops -- updatekeys freshsep/secrets.yaml
   ```

6. **Regenerate known_hosts:**
   ```bash
   nix run .#freshsep-gen-knownhosts-file
   ```

7. **Deploy new runtime key:**
   ```bash
   nix run .#deploy-rs
   ```

8. **Verify SOPS works with new runtime key:**
   ```bash
   nix run .#freshsep-ssh -- "sudo systemctl restart sops-nix"
   nix run .#freshsep-ssh -- "sudo systemctl status sops-nix"
   ```

9. **Verify boot unlock still works (unaffected):**
   ```bash
   nix run .#freshsep-ssh -- sudo reboot
   nix run .#freshsep-unlock
   # Expected: Boot key unchanged, unlock works
   ```

10. **Verify old runtime key cannot decrypt:**
    ```bash
    cd /tmp
    old_runtime_age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age -private-key -i ~/skarabox-qa-freshsep/freshsep/runtime_host_key.backup)
    SOPS_AGE_KEY="$old_runtime_age_key" nix run ~/skarabox-qa-freshsep#sops -- -d ~/skarabox-qa-freshsep/freshsep/secrets.yaml
    # Expected: FAILS with "no key could decrypt the data key"
    cd ~/skarabox-qa-freshsep
    ```

**Expected Results:**
- ✅ Runtime key rotates successfully
- ✅ SOPS re-encrypts with new runtime key
- ✅ Boot unlock unaffected
- ✅ Old runtime key cannot decrypt

**Actual Results:**
- [ ] Test not yet run

---

## deploy-deployrs: Deploy-rs Deployment (Separated-Key)

**Objective:** Verify deploy-rs works correctly with separated-key hosts.

**Prerequisites:**
- VM from fresh-separated (snapshot: `deploy-deployrs-base`)
- deploy-rs flake module imported

**Test Steps:**

1. **Create VM snapshot:** `deploy-deployrs-base`

2. **Make configuration change:**
   ```nix
   # Add to freshsep/configuration.nix
   environment.systemPackages = [ pkgs.htop ];
   ```

3. **Deploy with deploy-rs:**
   ```bash
   nix run .#deploy-rs
   ```

4. **Verify deployment succeeded:**
   ```bash
   nix run .#freshsep-ssh -- htop --version
   # Expected: htop version displayed
   ```

5. **Verify SSH still works post-deployment:**
   ```bash
   nix run .#freshsep-ssh -- echo "test"
   ```

6. **Reboot and verify:**
   ```bash
   nix run .#freshsep-ssh -- sudo reboot
   nix run .#freshsep-unlock
   nix run .#freshsep-ssh -- htop --version
   ```

**Expected Results:**
- ✅ deploy-rs succeeds with separated-key host
- ✅ Configuration changes apply correctly
- ✅ SSH keys remain functional

**Actual Results:**
- [ ] Test not yet run

---

## deploy-colmena: Colmena Deployment (Separated-Key)

**Objective:** Verify colmena works correctly with separated-key hosts.

**Prerequisites:**
- VM from fresh-separated (snapshot: `deploy-colmena-base`)
- colmena flake module imported

**Test Steps:**

1. **Create VM snapshot:** `deploy-colmena-base`

2. **Make configuration change:**
   ```nix
   # Add to freshsep/configuration.nix
   environment.systemPackages = [ pkgs.tree ];
   ```

3. **Deploy with colmena:**
   ```bash
   nix run .#colmena apply -- --on freshsep
   ```

4. **Verify deployment succeeded:**
   ```bash
   nix run .#freshsep-ssh -- tree --version
   # Expected: tree version displayed
   ```

5. **Verify SSH still works post-deployment:**
   ```bash
   nix run .#freshsep-ssh -- echo "test"
   ```

6. **Reboot and verify:**
   ```bash
   nix run .#freshsep-ssh -- sudo reboot
   nix run .#freshsep-unlock
   nix run .#freshsep-ssh -- tree --version
   ```

**Expected Results:**
- ✅ colmena succeeds with separated-key host
- ✅ Configuration changes apply correctly
- ✅ SSH keys remain functional

**Actual Results:**
- [ ] Test not yet run

---

## Edge Cases & Error Conditions

### missing-runtimekey: Missing Runtime Key in flake.nix
**Test:** Deploy separated-key host without runtimeHostKeyPub in flake.nix
**Expected:** Graceful error message

### mismatched-keys: Mismatched Keys
**Test:** Runtime key file doesn't match runtimeHostKeyPub in flake
**Expected:** SSH connection fails with clear error

### sops-mismatch: SOPS Key Mismatch
**Test:** SOPS configured with wrong key
**Expected:** Secrets fail to decrypt with clear error

### rotate-offline: Boot Key Rotation While System Down
**Test:** Try to rotate boot key when host unreachable
**Expected:** Error message indicating host must be accessible

### premature-removal: Premature Boot Key Removal
**Test:** Remove boot key from SOPS before deploying runtime key
**Expected:** SOPS fails to decrypt after next deployment

---

## Regression Tests

### regress-single: Single-Key Host Unchanged
**Test:** Deploy to existing single-key host without changes
**Expected:** No behavior changes, warnings about upgrading

### regress-beacon: Beacon Generation
**Test:** Generate beacon for both single-key and separated-key hosts
**Expected:** Both work correctly

### regress-knownhosts: Known Hosts Generation
**Test:** gen-knownhosts-file for various configurations
**Expected:** Correct entries for single vs separated keys

---

## Performance Tests

### perf-boot: Boot Time Comparison
**Test:** Measure boot time single-key vs separated-key
**Expected:** Negligible difference (<1s)

### perf-sops: SOPS Decrypt Time
**Test:** Measure secret decryption time
**Expected:** No measurable difference

---

## Documentation Tests

### docs-fresh: Fresh User Experience
**Test:** Follow documentation from scratch as new user
**Expected:** All steps work without consultation with maintainer

### docs-migrate: Migration Documentation
**Test:** Follow migration docs step-by-step
**Expected:** Successful migration without errors

---

## Test Execution Log

### Session 1: 2025-10-03

| Test ID | Status | Result | Notes |
|---------|--------|--------|-------|
| fresh-separated | ⏸️ Not Run | - | - |
| fresh-single | ⏸️ Not Run | - | - |
| migrate-separated | ⏸️ Not Run | - | Most critical test |
| rotate-boot | ⏸️ Not Run | - | - |
| rotate-runtime | ⏸️ Not Run | - | - |
| deploy-deployrs | ⏸️ Not Run | - | - |
| deploy-colmena | ⏸️ Not Run | - | - |
| missing-runtimekey | ⏸️ Not Run | - | - |
| mismatched-keys | ⏸️ Not Run | - | - |
| sops-mismatch | ⏸️ Not Run | - | - |
| rotate-offline | ⏸️ Not Run | - | - |
| premature-removal | ⏸️ Not Run | - | - |
| regress-single | ⏸️ Not Run | - | - |
| regress-beacon | ⏸️ Not Run | - | - |
| regress-knownhosts | ⏸️ Not Run | - | - |
| perf-boot | ⏸️ Not Run | - | - |
| perf-sops | ⏸️ Not Run | - | - |
| docs-fresh | ⏸️ Not Run | - | - |
| docs-migrate | ⏸️ Not Run | - | - |

---

## Summary Statistics

- **Total Tests Defined:** 7 core + 5 edge cases + 3 regression + 2 performance + 2 documentation = 19
- **Tests Passed:** 0
- **Tests Failed:** 0
- **Tests Blocked:** 0
- **Tests Not Run:** 19
- **Code Coverage:** Core migration workflow, edge cases, regressions, performance, documentation

---

## Test Priorities

**P0 (Critical - Must Pass):**
- `migrate-separated` - Full migration workflow with security verification
- `fresh-separated` - Default new host experience
- `rotate-boot` - Security hardening (destructive operation)

**P1 (High - Should Pass):**
- `fresh-single` - Backward compatibility
- `rotate-runtime` - SOPS key rotation
- `premature-removal` - Prevent security holes

**P2 (Medium - Nice to Have):**
- `deploy-deployrs`, `deploy-colmena` - Deployment tool compatibility
- `regress-single`, `regress-beacon`, `regress-knownhosts` - No regressions
- `docs-fresh`, `docs-migrate` - Documentation accuracy

**P3 (Low - Informational):**
- `perf-boot`, `perf-sops` - Performance baseline
- Error condition tests - UX polish

---

## Issues Found

_None yet - testing not started_

---

## Notes & Observations

### Pre-Test Setup (2025-10-03)
- **Branch:** `protected-sops-key` in skarabox repo
- **Test Approach:** VM snapshots for rollback capability
- **Host Naming:** Short identifiers (freshsep, freshsingle, etc.)
- **Critical Security Tests:**
  - Boot key cannot decrypt SOPS after migration
  - Old boot key from git history is worthless after rotation
  - Runtime key in encrypted pool is inaccessible from initrd

### Terminology Reference
- **Boot key:** SSH key for initrd unlock, stored unencrypted in `/boot/host_key`
- **Runtime key:** SSH key for SOPS encryption, stored encrypted in `/persist/etc/ssh/ssh_host_ed25519_key`
- **Separated-key mode:** Uses both keys (secure, default for new hosts)
- **Single-key mode:** Uses only boot key (legacy, vulnerable to physical access)

### Key Security Properties to Verify
1. **Physical Access Protection:** Boot key accessible from /boot cannot decrypt SOPS secrets
2. **Git History Protection:** Old boot keys from git history become useless after rotation
3. **Migration Safety:** Both keys work during migration period, only runtime key after completion
4. **Activation Script:** Runtime key auto-installs from /tmp during NixOS activation
5. **Reboot Persistence:** Separated-key configuration survives reboot cycles

---

## 📝 Test Execution Instructions

### How to Execute Tests

1. **Start with the Test Setup section** at the top - complete all prerequisite steps
2. **Run tests in priority order:**
   - P0 tests first (migrate-separated, fresh-separated, rotate-boot)
   - Then P1 tests
   - P2 and P3 as time permits
3. **For each test:**
   - Follow EVERY step exactly as written
   - Copy-paste commands when possible to avoid typos
   - Document actual output in the "Actual Results" section
   - If a step fails, capture the error and note it in "Issues Found"
   - Use VM snapshots to rollback between tests

### Reporting Results

**For successful test steps:**
- Mark the step with ✅ in your notes
- Note any deviations from expected output
- Proceed to next step

**For failed test steps:**
- Mark the step with ❌ in your notes
- Capture the EXACT error message
- Capture relevant log output (`journalctl -xe`, etc.)
- Take a screenshot if UI-related
- Add to "Issues Found" section with:
  - Test ID
  - Step number
  - Command that failed
  - Error message
  - Expected vs actual behavior
  - Hypothesis about root cause

**For blocked tests:**
- Note what prerequisite is missing
- Mark as blocked in execution log
- Move to next test if possible

### Post-Test Checklist

After completing each test:
- [ ] Update "Actual Results" section
- [ ] Update execution log with status
- [ ] Document any issues found
- [ ] Commit changes to QA document
- [ ] Restore VM snapshot if needed for next test
- [ ] Note any documentation improvements needed

### Common Troubleshooting

**VM won't start:**
- Check if another QEMU process is running: `ps aux | grep qemu`
- Check disk space: `df -h`
- Check .skarabox-tmp directory exists and has disk images

**SSH connection fails:**
- Verify VM is booted: check VM window for login prompt
- Verify known_hosts generated: `cat <hostname>/known_hosts`
- Try manual SSH: `ssh -p 2222 -i <hostname>/ssh <user>@192.168.1.30`
- Check if boot unlock is required (after reboot)

**SOPS fails to decrypt:**
- Check which key you're using: `echo $SOPS_AGE_KEY`
- IMPORTANT: Use PRIVATE keys with `-private-key` flag, not public keys
- Verify key conversion: `ssh-to-age -private-key -i key` (not `ssh-to-age < key.pub`)
- Run from `/tmp` to avoid falling back to `sops.key` file
- Check .sops.yaml has correct keys: `cat .sops.yaml`
- Compare key in .sops.yaml: `ssh-to-age < key.pub` gives public age key

**Deploy fails:**
- Check git status: `git status` (all changes must be committed)
- Check flake syntax: `nix flake check`
- Check facter.json exists: `ls -la <hostname>/facter.json`
- Check VM is accessible: `nix run .#<hostname>-ssh -- echo test`
