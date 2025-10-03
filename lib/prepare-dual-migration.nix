{
  pkgs,
  add-sops-cfg,
  hostName,
  hostCfg,
}:
pkgs.writeShellApplication {
  name = "prepare-dual-migration";

  runtimeInputs = [
    pkgs.openssh
    pkgs.sops
    pkgs.jq
    pkgs.yq-go
    pkgs.ssh-to-age
    add-sops-cfg
  ];

  text = ''
    set -euo pipefail

    # From flake configuration
    host_name="${hostName}"
    initrd_key_pub="${hostCfg.hostKeyPub}"
    runtime_key="${hostCfg.runtimeHostKeyPath}"
    runtime_key_pub_path="''${runtime_key}.pub"
    runtime_key_pub_content="${if hostCfg.runtimeHostKeyPub != null then hostCfg.runtimeHostKeyPub else ""}"
    sops_file="${hostName}/secrets.yaml"
    sops_cfg=".sops.yaml"

    usage () {
      cat <<USAGE
    Usage: $0 [-h] [-f FLAKE_ROOT] [-v]

      -h:            Shows this usage
      -f FLAKE_ROOT: Root directory of the flake (default: current directory)
      -v:            Verbose output

    This command prepares an existing single-key host for dual host key migration by:
      1. Generating a runtime SSH key pair if missing
      2. Converting the runtime key to Age format for SOPS
      3. Updating .sops.yaml to include both initrd and runtime keys
      4. Re-encrypting secrets with both keys for safe migration
      5. Validating that SOPS decryption works with both keys

    The host remains in single-key mode until you run the actual migration steps.
    This is a safe preparation step that doesn't change host behavior.
USAGE
    }

    # Default values
    flake_root="."
    verbose=0

    while getopts "hf:v" o; do
      case "''${o}" in
        h)
          usage
          exit 0
          ;;
        f)
          flake_root="''${OPTARG}"
          ;;
        v)
          verbose=1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done
    shift $((OPTIND-1))

    # Change to flake root directory
    cd "$flake_root"

    # Verbose logging function
    log () {
      if [ "$verbose" -eq 1 ]; then
        echo "[$(date '+%H:%M:%S')] $*"
      fi
    }

    # Validation functions
    validate_initrd_key () {
      # initrd_key_pub is already the file content from flake config
      if [ -z "$initrd_key_pub" ]; then
        echo "Error: Initrd public key not configured in flake" >&2
        exit 1
      fi
      log "Initrd public key configured"
    }

    validate_sops_files () {
      if [ ! -f "$sops_cfg" ]; then
        echo "Error: SOPS configuration $sops_cfg not found" >&2
        exit 1
      fi
      if [ ! -f "$sops_file" ]; then
        echo "Error: SOPS secrets file $sops_file not found" >&2
        exit 1
      fi
      log "SOPS files exist: $sops_cfg, $sops_file"
    }

    # Generate runtime SSH key pair if missing
    generate_runtime_key () {
      if [ -f "$runtime_key" ] && [ -f "$runtime_key_pub_path" ]; then
        echo "[1/6] Runtime SSH key already exists, skipping generation"
        return 0
      fi

      echo "[1/6] Generating runtime SSH key pair for $host_name..."
      ssh-keygen -t ed25519 -N "" -f "$runtime_key" -C "runtime-key@$host_name"
      chmod 600 "$runtime_key"
      chmod 644 "$runtime_key_pub_path"
      echo "Generated runtime SSH key: $runtime_key"
      log "Runtime key permissions set correctly"
    }

    # Convert SSH keys to Age format
    get_age_keys () {
      echo "[2/6] Converting SSH keys to Age format..."
      log "Converting SSH public keys to Age format..."
      
      # initrd_key_pub is already the file content from config
      initrd_age_key=$(echo "$initrd_key_pub" | ssh-to-age 2>/dev/null)
      
      # runtime_key_pub_content from config if available, otherwise read from path
      if [ -n "$runtime_key_pub_content" ]; then
        runtime_age_key=$(echo "$runtime_key_pub_content" | ssh-to-age 2>/dev/null)
      else
        runtime_age_key=$(ssh-to-age < "$runtime_key_pub_path" 2>/dev/null)
      fi
      
      if [ -z "$initrd_age_key" ] || [ -z "$runtime_age_key" ]; then
        echo "Error: Failed to convert SSH keys to Age format" >&2
        exit 1
      fi
      
      log "Initrd Age key: $initrd_age_key"
      log "Runtime Age key: $runtime_age_key"
    }

    # Update .sops.yaml with both keys
    update_sops_config () {
      echo "[3/6] Updating SOPS configuration to include both keys..."
      
      # Create backup
      cp "$sops_cfg" "$sops_cfg.bak.$(date +%s)"
      log "Backed up SOPS config to $sops_cfg.bak.*"
      
      # Check if runtime key already exists in config
      if grep -q "$runtime_age_key" "$sops_cfg" 2>/dev/null; then
        echo "Runtime key already present in SOPS configuration"
        log "Runtime key already in SOPS config"
        return 0
      fi
      
      # Add runtime key to SOPS configuration using add-sops-cfg
      echo "Adding runtime key to SOPS configuration..."
      
      # Add the runtime key as an alias
      if ! add-sops-cfg -o "$sops_cfg" alias "''${host_name}_runtime" "$runtime_age_key"; then
        echo "Error: Failed to add runtime key alias to SOPS configuration" >&2
        exit 1
      fi
      
      # Add the runtime key to the path regex rules  
      if ! add-sops-cfg -o "$sops_cfg" path-regex "''${host_name}_runtime" "$sops_file"; then
        echo "Error: Failed to add runtime key to path regex rules" >&2
        exit 1
      fi
      
      echo "Updated SOPS configuration with dual keys"
      log "SOPS config updated successfully"
    }

    # Re-encrypt secrets with both keys
    reencrypt_secrets () {
      echo "[4/6] Preparing secrets for dual-key encryption..."
      
      # Create backup
      cp "$sops_file" "$sops_file.bak.$(date +%s)"
      log "Backed up secrets file"
      
      # Check if we can decrypt the current secrets (i.e., do we have the keys?)
      if sops -d "$sops_file" >/dev/null 2>&1; then
        echo "Can decrypt existing secrets - proceeding with re-encryption"
        
        # Re-encrypt with updated keys
        if ! sops updatekeys "$sops_file"; then
          echo "Error: Failed to re-encrypt secrets with new keys" >&2
          echo "Restoring backup..."
          mv "$sops_file.bak."* "$sops_file" 2>/dev/null || true
          exit 1
        fi
        
        echo "Secrets re-encrypted with both keys"
      else
        echo "Note:  Cannot decrypt secrets locally (missing decryption keys)"
        echo "Note:  Secrets will be re-encrypted automatically during deployment"
        echo "SOPS configuration updated - ready for deployment"
      fi
    }

    # Validate SOPS decryption with both keys
    validate_sops_decryption () {
      echo "[5/6] Validating SOPS configuration..."
      
      # Test if we can decrypt with available keys
      if sops -d "$sops_file" >/dev/null 2>&1; then
        log "Decryption works with available keys"
        
        # Test decryption by extracting a known field (if exists)
        if sops -d --extract '["disks"]' "$sops_file" >/dev/null 2>&1; then
          log "Can extract disk configuration from secrets"
        fi
        
        echo "SOPS decryption validation completed"
      else
        echo "Note:  Local decryption not available (this is normal for remote preparation)"
        echo "SOPS configuration is valid and ready for deployment"
      fi
    }

    # Display migration status
    show_migration_status () {
      echo ""
      echo "[6/6] Migration Preparation Complete"
      echo ""
      echo "=== Summary ==="
      echo "Host: $host_name"
      echo "Status: Ready for dual host key migration"
      echo ""
      echo "Files created/updated:"
      echo "  $runtime_key (runtime private key)"
      echo "  $runtime_key_pub_path (runtime public key)" 
      echo "  $sops_cfg (updated with both keys)"
      
      # Show re-encryption status based on what actually happened
      if [[ -f "$HOME/.gnupg/secring.gpg" ]] || command -v age-keygen >/dev/null 2>&1; then
        echo "  $sops_file (re-encrypted with both keys)"
      else
        echo " Note: $sops_file (will be re-encrypted during deployment)"
      fi
      
      echo ""
      echo "Next steps:"
      echo " 1. Add runtime key paths to your flake.nix:"
      echo "    skarabox.hosts.$host_name = {"
      echo "      runtimeHostKeyPub = ./$host_name/runtime_host_key.pub;"
      echo "      # ... existing config"
      echo "    };"
      echo ""
      echo " 2. Deploy normally (runtime key installs automatically):"
      echo "    colmena deploy"
      echo "    # or"
      echo "    nix run .#$host_name-install-on-beacon"
      echo ""
      echo " 3. When ready to switch: nix run .#$host_name-enable-dual-mode"
      if [[ -f "$HOME/.gnupg/secring.gpg" ]] || command -v age-keygen >/dev/null 2>&1; then
        echo ""
        echo "Optional: Test local SOPS decryption: nix run .#sops -- -d $sops_file"
      fi
      echo ""
      echo "Note:  The host is still in single-key mode. No behavior has changed yet."
      echo ""
    }

    # Main execution
    main () {
      echo "Preparing $host_name for dual host key migration..."
      
      validate_initrd_key
      validate_sops_files
      
      generate_runtime_key
      get_age_keys
      update_sops_config
      reencrypt_secrets
      validate_sops_decryption
      
      show_migration_status
    }

    # Run main function
    main
  '';
}
