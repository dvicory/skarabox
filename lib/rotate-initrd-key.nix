{
  pkgs,
  hostName,
  hostCfg,
  nixosCfg,
}:
let
  # Create a package with all tools we need on the remote system
  remoteTools = pkgs.buildEnv {
    name = "rotate-initrd-tools";
    paths = [
      pkgs.util-linux      # findmnt, lsblk, umount, mount
      pkgs.dosfstools       # mkfs.vfat
      pkgs.rsync
      pkgs.coreutils       # dd, install, mkdir, rm, etc
      pkgs.gnugrep
      pkgs.gawk
    ];
  };
in
pkgs.writeShellApplication {
  name = "rotate-initrd-key";
  
  runtimeInputs = [
    pkgs.openssh
    pkgs.coreutils
    pkgs.nix  # for nix-copy-closure
  ];

  text = ''
    set -euo pipefail

    # From flake configuration
    HOST_NAME="${hostName}"
    HOST_IP="${hostCfg.ip}"
    SSH_PORT="${toString nixosCfg.skarabox.sshPort}"
    SSH_USER="${nixosCfg.skarabox.username}"
    SSH_KEY="${if hostCfg.sshPrivateKeyPath != null then hostCfg.sshPrivateKeyPath else "${hostName}/ssh"}"
    KNOWN_HOSTS="${hostCfg.knownHosts}"
    NEW_KEY="${hostName}/host_key"
    REMOTE_TOOLS="${remoteTools}"
    
    # Validate
    [[ -f "$NEW_KEY" ]] || { echo "Error: $NEW_KEY not found"; exit 1; }
    
    # Show fingerprints
    echo "Initrd SSH Key Rotation for $HOST_NAME"
    echo "========================================"
    echo ""
    echo "Old key: $(ssh -p "$SSH_PORT" -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" "$SSH_USER@$HOST_IP" "sudo ssh-keygen -l -f /boot/host_key")"
    echo "New key: $(ssh-keygen -l -f "$NEW_KEY")"
    echo ""
    echo "This will:"
    echo "  1. Backup /boot contents to tmpfs"
    echo "  2. Securely wipe the boot partition (dd with zeros)"
    echo "  3. Recreate the filesystem"
    echo "  4. Restore boot files with new SSH key"
    echo "  5. Reinstall bootloader"
    echo ""
    echo "Security: Old key will be unrecoverable (block-level wipe)"
    echo ""
    read -p "Continue with rotation? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    
    # Copy tools to remote system
    echo ""
    echo "Copying tools to remote system..."
    nix-copy-closure --to "$SSH_USER@$HOST_IP" "$REMOTE_TOOLS"
    
    # Remote script using the tools we just copied
    echo "Running rotation on remote system..."
    echo ""
    ssh -p "$SSH_PORT" -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" "$SSH_USER@$HOST_IP" \
      "PATH=$REMOTE_TOOLS/bin:\$PATH bash -s" \
      <<'REMOTE_SCRIPT'
      set -euo pipefail
      
      # Discover current boot partition configuration
      echo "[1/8] Discovering current partition layout..."
      BOOT_DEV=$(findmnt -n -o SOURCE /boot)
      BOOT_FSTYPE=$(lsblk -ndo FSTYPE "$BOOT_DEV")
      BOOT_LABEL=$(lsblk -ndo LABEL "$BOOT_DEV" || echo "")
      BOOT_MOUNT_OPTS=$(findmnt -n -o OPTIONS /boot)
      
      # Check for mirrored boot
      if findmnt /boot-backup &>/dev/null; then
        HAS_BACKUP=true
        BACKUP_DEV=$(findmnt -n -o SOURCE /boot-backup)
        echo "      Found mirrored boot: $BACKUP_DEV"
      else
        HAS_BACKUP=false
      fi
      
      echo "      Device: $BOOT_DEV"
      echo "      Filesystem: $BOOT_FSTYPE"
      echo "      Label: ${BOOT_LABEL:-<none>}"
      echo "      Mount options: $BOOT_MOUNT_OPTS"
      
      # Validate it's vfat (we only handle FAT filesystems)
      if [[ "$BOOT_FSTYPE" != "vfat" ]]; then
        echo "Error: Expected vfat filesystem, found $BOOT_FSTYPE"
        exit 1
      fi
      
      # Backup boot contents
      echo ""
      echo "[2/8] Backing up boot files to tmpfs..."
      mkdir -p /tmp/boot-backup
      rsync -a /boot/ /tmp/boot-backup/ --exclude=host_key
      echo "      $(du -sh /tmp/boot-backup | cut -f1) backed up"
      
      # Unmount and wipe
      echo ""
      echo "[3/8] Unmounting /boot..."
      sudo umount /boot
      
      echo ""
      echo "[4/8] Securely wiping $BOOT_DEV (this may take a moment)..."
      sudo dd if=/dev/zero of="$BOOT_DEV" bs=1M status=progress 2>&1 || true
      echo "      Wipe complete"
      
      # Recreate filesystem with discovered parameters
      echo ""
      echo "[5/8] Recreating filesystem..."
      if [[ -n "$BOOT_LABEL" ]]; then
        sudo mkfs.vfat -F 32 -n "$BOOT_LABEL" "$BOOT_DEV"
      else
        sudo mkfs.vfat -F 32 "$BOOT_DEV"
      fi
      
      # Mount with discovered options
      echo "      Mounting..."
      sudo mount -o "$BOOT_MOUNT_OPTS" "$BOOT_DEV" /boot
      
      # Restore and install new key
      echo ""
      echo "[6/8] Restoring boot files and installing new key..."
      sudo rsync -a /tmp/boot-backup/ /boot/
      sudo install -m 600 /dev/stdin /boot/host_key
      echo "      New key installed"
      
      # Handle mirrored boot
      if [[ "$HAS_BACKUP" == "true" ]]; then
        echo ""
        echo "[6b/8] Processing mirrored boot partition..."
        sudo umount /boot-backup
        sudo dd if=/dev/zero of="$BACKUP_DEV" bs=1M status=progress 2>&1 || true
        if [[ -n "$BOOT_LABEL" ]]; then
          sudo mkfs.vfat -F 32 -n "$BOOT_LABEL" "$BACKUP_DEV"
        else
          sudo mkfs.vfat -F 32 "$BACKUP_DEV"
        fi
        sudo mount -o "$BOOT_MOUNT_OPTS" "$BACKUP_DEV" /boot-backup
        sudo rsync -a /tmp/boot-backup/ /boot-backup/
        sudo install -m 600 /dev/stdin /boot-backup/host_key
        echo "       Backup boot updated"
      fi
      
      # Reinstall bootloader using the system's current bootloader configuration
      echo ""
      echo "[7/8] Reinstalling bootloader..."
      if [[ -x "/run/current-system/bin/switch-to-configuration" ]]; then
        sudo /run/current-system/bin/switch-to-configuration boot || {
          echo "      Warning: Bootloader reinstall may have failed, but boot contents are restored"
        }
      else
        echo "      Warning: Could not find bootloader installer, boot files restored but EFI may need manual update"
      fi
      
      echo ""
      echo "[8/8] Cleaning up..."
      sudo rm -rf /tmp/boot-backup
      
      echo ""
      echo "✓ Rotation complete!"
REMOTE_SCRIPT
    < "$NEW_KEY"
    
    # Verify
    echo ""
    echo "Verification"
    echo "============"
    ACTUAL_FP=$(ssh -p "$SSH_PORT" -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" "$SSH_USER@$HOST_IP" "sudo ssh-keygen -l -f /boot/host_key")
    EXPECTED_FP=$(ssh-keygen -l -f "$NEW_KEY")
    echo "Expected: $EXPECTED_FP"
    echo "Actual:   $ACTUAL_FP"
    
    if [[ "$EXPECTED_FP" == "$ACTUAL_FP" ]]; then
      echo "✓ Key rotation verified successfully"
    else
      echo "✗ Warning: Key fingerprints do not match!"
      exit 1
    fi
    
    echo ""
    echo "Next Steps"
    echo "=========="
    echo "1. Update known_hosts:"
    echo "   nix run .#$HOST_NAME-gen-knownhosts-file"
    echo ""
    echo "2. Test initrd SSH (before reboot):"
    echo "   ssh -p \$(cat $HOST_NAME/ssh_boot_port) root@$HOST_IP"
    echo ""
    echo "3. Reboot to activate new key in initrd:"
    echo "   ssh -p $SSH_PORT $SSH_USER@$HOST_IP sudo reboot"
    echo ""
  '';
}
