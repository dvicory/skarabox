# Session Notes: 2025-10-04
## SOPS Timing Issue - RESOLVED ✅

---

## 🔑 CRITICAL FIX IMPLEMENTED

### Problem
After completing boot key rotation (migrate-separated Steps 20-23), discovered SOPS unable to decrypt secrets:
- Error: `"Cannot read ssh key '/persist/etc/ssh/ssh_host_ed25519_key': no such file or directory"`
- Error: `"failed to decrypt: Error getting data key: 0 successful groups required, got 0"`
- Result: `/run/secrets-for-users.d/` only contained empty `age-keys.txt`

### Root Cause
Boot sequence timing issue revealed by `journalctl` analysis:
```
Oct 04 10:30:14 testhost stage-2-init: SOPS tries to read key → FAILS (file not found)
Oct 04 10:30:15 testhost systemd[1]: Mounting /persist → TOO LATE!
```

**SOPS runs during stage-2-init activation BEFORE systemd mounts /persist filesystem.**

### Solution (TESTED & WORKING ✅)
Added to `/Users/daniel.vicory/src/skarabox/modules/disks.nix` (lines 316-319):
```nix
fileSystems = {
  "/boot".neededForBoot = true;
  "/boot-backup" = mkIf (cfg.rootPool.disk2 != null) { neededForBoot = true; };
  "/persist".neededForBoot = true;  # ← FIXES SOPS timing issue
};
```

**Why this works:**
- `neededForBoot = true` forces /persist to mount during **initrd phase** (before stage-2-init)
- SOPS can now read runtime key when activation scripts run
- Official sops-nix solution for encrypted filesystems (confirmed via DeepWiki)

### Testing Results
**testhost (VERIFIED WORKING):**
```bash
# After deployment and reboot:
$ nix run .#testhost-ssh -- "sudo find /run/secrets-for-users.d -type f"
/run/secrets-for-users.d/1/testhost/user/hashedPassword  ✅
/run/secrets-for-users.d/age-keys.txt  ✅

$ nix run .#testhost-ssh -- "journalctl -b 0 | grep -i 'sops.*decrypt\|Cannot read ssh key'"
(no output = no errors)  ✅

$ nix run .#testhost-ssh -- "sudo cat /run/secrets-for-users.d/1/testhost/user/hashedPassword"
$y$j9T$Izo/NsvXtmBwB1KsB7E4.0$MDl4i6nqGyF1m1lJKIEE...  ✅
```

---

## 📋 CONTINUATION CHECKLIST (HIGH PRIORITY)

### Step 1: Update Known Hosts (REQUIRED)
Boot key was rotated during testing, need to update known_hosts:
```bash
cd ~/src/skarabox-qa
nix run .#fresh-single-gen-knownhosts-file
```

### Step 2: Deploy SOPS Fix to fresh-single
```bash
nix run .#colmena -- apply --on fresh-single --build-on-target
```
Expected: "All done! Activation successful"

### Step 3: Reboot and Unlock
```bash
nix run .#fresh-single-ssh -- sudo reboot
# Wait ~15 seconds
nix run .#fresh-single-unlock
```

### Step 4: Verify SOPS Working
```bash
# Check secrets exist
nix run .#fresh-single-ssh -- "sudo find /run/secrets-for-users.d -type f"
# Expected output:
#   /run/secrets-for-users.d/3/fresh-single/user/hashedPassword
#   /run/secrets-for-users.d/age-keys.txt

# Check no SOPS errors in boot logs
nix run .#fresh-single-ssh -- "journalctl -b 0 | grep -i 'sops.*decrypt\|Cannot read ssh key'"
# Expected: Empty output (no errors)

# Verify secret is readable (Step 25 verification)
nix run .#fresh-single-ssh -- "sudo cat /run/secrets-for-users.d/3/fresh-single/user/hashedPassword"
# Expected: Password hash displayed
```

### Step 5: Complete Common Verification Steps (V1-V9)
Document results in separated-keys-qa.md as specified in test case template.

### Step 6: Update QA Documentation
- Mark migrate-separated as ✅ PASSED
- Update test matrix: "2/7 completed" → "3/7 completed"  
- Document verification results in "Actual Results" section

---

## 🔧 OTHER IMPROVEMENTS COMPLETED

### 1. Boot Key Rotation Validation
**File:** `/Users/daniel.vicory/src/skarabox/lib/rotate-boot-key.nix` (lines 88-102)

Added fingerprint comparison to prevent accidental rotation with same key:
```nix
old_key_fp=$(ssh ... "sudo ssh-keygen -l -f /boot/host_key")
new_key_fp=$(ssh-keygen -l -f "$private_key_path")

if [ "$old_key_fp" = "$new_key_fp" ]; then
  echo "❌ ERROR: Old and new keys are identical!" >&2
  echo "You must generate a new key before rotating:" >&2
  echo "  ssh-keygen -t ed25519 -f $private_key_path -N \"\"" >&2
  exit 1
fi
```

**Tested:** Correctly rejects rotation when keys match.

### 2. Install Runtime Key Simplification
**File:** `/Users/daniel.vicory/src/skarabox/lib/install-runtime-key.nix` (line 94)

Removed redundant mkdir/chmod (install -D creates directories automatically):
```bash
# Before:
sudo mkdir -p /persist/etc/ssh && sudo chmod 755 /persist/etc/ssh && sudo install -D ...

# After:
sudo install -D -m 600 /dev/stdin /persist/etc/ssh/ssh_host_ed25519_key
```

**Verified:** install -D creates parent directories with correct 755 permissions.

### 3. Documentation Fixes
**File:** `/Users/daniel.vicory/src/skarabox/docs/normal-operations.md`

Added missing prerequisite (2 locations):
```bash
# Generate new boot key
ssh-keygen -t ed25519 -f myskarabox/host_key -N ""

# Then rotate
nix run .#myskarabox-rotate-boot-key
```

---

## 📊 TEST STATUS SUMMARY

### Completed (2/7):
1. ✅ **fresh-separated** - Separated-key deployment verified working
2. ✅ **fresh-single** - Single-key deployment verified (boot key CAN decrypt secrets - vulnerability confirmed)

### In Progress (1/7):
3. 🔄 **migrate-separated** - Migration from single→separated:
   - Steps 1-23: ✅ COMPLETE (including boot key rotation)
   - Critical bug: ✅ FIXED (SOPS timing issue)
   - Testing: ✅ VERIFIED on testhost
   - **Next:** Deploy fix to fresh-single, complete Steps 24-25

### Remaining (4/7):
4. ⏭️ **rotate-boot** - SKIP (already tested as part of migrate-separated Steps 20-23)
5. ❌ **rotate-runtime** - Runtime key rotation test
6. ❌ **deploy-deployrs** - Deployment via deploy-rs
7. ❌ **deploy-colmena** - Deployment via colmena (partially tested during fix deployment)

---

## 🔍 TECHNICAL DETAILS

### Fresh-Single Boot Key Rotation Results
- **Old key:** SHA256:fwy5fe7ZeOYjR6vKlZzyBnTGnpFsLPngNMZRQzh7SJg (backed up)
- **New key:** SHA256:HAeRQNR7ncznC/+1761U7fj02wH9o3NW0EBtknYY+sc (installed)
- **Method:** dd wipe + TRIM, new ext4 fs, new key installed, bootloader reinstalled
- **Status:** Boot unlock working with new key ✅

### SOPS Issue Impact
- **Affected hosts:** ALL separated-key hosts (testhost + fresh-single)
- **Why universal:** Runtime key stored on /persist, all separated-key configs need early mount
- **Fix universality:** Single fix in disks.nix applies to all hosts

### Boot Sequence Order (Post-Fix)
1. **Initrd phase:** Unlock encrypted pool, mount /persist ✅
2. **stage-2-init:** Run activation scripts, SOPS decrypts secrets ✅ (key now accessible)
3. **systemd:** Start services, use decrypted secrets ✅

---

## 💡 KEY LEARNINGS

1. **SOPS activation timing:**
   - Runs during stage-2-init (activation scripts)
   - Happens BEFORE systemd mounts filesystems
   - neededForBoot forces early mounting during initrd

2. **Boot log debugging:**
   - `journalctl -b 0 | grep -E '(persist|sops|stage-2)'` reveals timing
   - Look for "Cannot read ssh key" errors
   - Compare timestamps to identify ordering issues

3. **DeepWiki research:**
   - Official documentation often has solutions for common patterns
   - Query: "How does sops-nix handle SSH keys on encrypted filesystems?"
   - Result: neededForBoot recommendation

4. **Centralized configuration:**
   - User suggestion to place fix in disks.nix (not configuration.nix) was correct
   - Keeps all filesystem configuration in one logical place
   - Easier to maintain and understand

5. **Test isolation:**
   - Testing on multiple hosts (testhost + fresh-single) identified universal bug
   - Single-host issue = configuration-specific, multi-host = architectural

---

## 📝 FILES MODIFIED THIS SESSION

### Critical Fix:
- `modules/disks.nix` - Added `/persist.neededForBoot = true`

### Improvements:
- `lib/rotate-boot-key.nix` - Added key comparison validation
- `lib/install-runtime-key.nix` - Simplified install command
- `docs/normal-operations.md` - Added ssh-keygen prerequisites (2 locations)
- `separated-keys-qa.md` - Documented SOPS issue and fix (extensive updates)

### Test Files:
- `skarabox-qa/fresh-single/host_key*` - New boot keys generated and installed
- `skarabox-qa/fresh-single/known_hosts` - Regenerated with new boot key

---

## ⚠️ IMPORTANT NOTES FOR TOMORROW

1. **Don't forget gen-knownhosts-file before deployment!**
   - Boot key was rotated, SSH will fail without updated known_hosts
   - Command: `nix run .#fresh-single-gen-knownhosts-file`

2. **Fix is already in skarabox repo:**
   - No need to make changes before deployment
   - Just deploy and verify working

3. **Expected test duration:**
   - Deployment: ~1-2 minutes
   - Reboot + unlock: ~30 seconds
   - Verification: ~1 minute
   - **Total: ~5 minutes to complete migrate-separated**

4. **After migrate-separated completes:**
   - Can proceed to rotate-runtime test case
   - Or test deploy-rs / colmena deployment methods

5. **Test case overlap note:**
   - rotate-boot case originally planned separately
   - Already fully tested as part of migrate-separated Steps 20-23
   - Marked as SKIP to avoid duplicate testing

---

## 🎯 SUCCESS CRITERIA (FOR TOMORROW)

migrate-separated test will be **✅ PASSED** when:
- [x] Steps 1-23 completed (DONE)
- [x] SOPS fix implemented (DONE)
- [x] SOPS fix tested on testhost (DONE)
- [ ] SOPS fix deployed to fresh-single (NEXT)
- [ ] Secrets decrypt successfully on fresh-single (NEXT)
- [ ] Step 25 verification: Password hash accessible (NEXT)
- [ ] Common verification steps V1-V9 documented (NEXT)
- [ ] QA doc updated with final results (NEXT)

**You're ~5 minutes away from completing this major test case! 🚀**

---

Generated: 2025-10-04 End of Day
Status: Session ended with SOPS fix verified on testhost, ready for fresh-single deployment
