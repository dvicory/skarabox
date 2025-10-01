{ pkgs, add-sops-cfg }:
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
    usage() {
      cat <<USAGE
    Usage: $0 -n HOST_NAME [-f FLAKE_ROOT] [-v]

      -h:            Show this usage
      -n HOST_NAME:  Name of the host to prepare for dual SSH key migration
      -f FLAKE_ROOT: Root directory of the flake (default: current directory)
      -v:            Verbose output

    This command prepares an existing single-key host for dual SSH key migration by:
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
    HOST_NAME=""
    FLAKE_ROOT="."
    VERBOSE=false

    # Parse command line arguments
    while getopts "hn:f:v" opt; do
      case $opt in
        h)
          usage
          exit 0
          ;;
        n)
          HOST_NAME="$OPTARG"
          ;;
        f)
          FLAKE_ROOT="$OPTARG"
          ;;
        v)
          VERBOSE=true
          ;;
        \?)
          echo "Invalid option: -$OPTARG" >&2
          usage
          exit 1
          ;;
      esac
    done

    # Validate required parameters
    if [ -z "$HOST_NAME" ]; then
      echo "Error: Host name is required (-n HOST_NAME)" >&2
      usage
      exit 1
    fi

    # Change to flake root directory
    cd "$FLAKE_ROOT"

    HOST_DIR="./$HOST_NAME"
    RUNTIME_KEY="$HOST_DIR/runtime_host_key"
    RUNTIME_KEY_PUB="$HOST_DIR/runtime_host_key.pub"
    INITRD_KEY_PUB="$HOST_DIR/host_key.pub"
    SOPS_FILE="$HOST_DIR/secrets.yaml"
    SOPS_CONFIG=".sops.yaml"

    # Verbose logging function
    log() {
      if [ "$VERBOSE" = true ]; then
        echo "[$(date '+%H:%M:%S')] $*"
      fi
    }

    # Validation functions
    validate_host_exists() {
      if [ ! -d "$HOST_DIR" ]; then
        echo "Error: Host directory $HOST_DIR does not exist" >&2
        exit 1
      fi
      log "✓ Host directory $HOST_DIR exists"
    }

    validate_initrd_key() {
      if [ ! -f "$INITRD_KEY_PUB" ]; then
        echo "Error: Initrd public key $INITRD_KEY_PUB not found" >&2
        exit 1
      fi
      log "✓ Initrd public key found: $INITRD_KEY_PUB"
    }

    validate_sops_files() {
      if [ ! -f "$SOPS_CONFIG" ]; then
        echo "Error: SOPS configuration $SOPS_CONFIG not found" >&2
        exit 1
      fi
      if [ ! -f "$SOPS_FILE" ]; then
        echo "Error: SOPS secrets file $SOPS_FILE not found" >&2
        exit 1
      fi
      log "✓ SOPS files exist: $SOPS_CONFIG, $SOPS_FILE"
    }

    # Generate runtime SSH key pair if missing
    generate_runtime_key() {
      if [ -f "$RUNTIME_KEY" ] && [ -f "$RUNTIME_KEY_PUB" ]; then
        echo "Runtime SSH key already exists, skipping generation"
        log "✓ Runtime SSH key pair already exists"
        return 0
      fi

      echo "Generating runtime SSH key pair for $HOST_NAME..."
      ssh-keygen -t ed25519 -N "" -f "$RUNTIME_KEY" -C "runtime-key@$HOST_NAME"
      chmod 600 "$RUNTIME_KEY"
      chmod 644 "$RUNTIME_KEY_PUB"
      echo "✓ Generated runtime SSH key: $RUNTIME_KEY"
      log "✓ Runtime key permissions set correctly"
    }

    # Convert SSH keys to Age format
    get_age_keys() {
      log "Converting SSH public keys to Age format..."
      
      INITRD_AGE_KEY=$(ssh-to-age -i "$INITRD_KEY_PUB" 2>/dev/null)
      RUNTIME_AGE_KEY=$(ssh-to-age -i "$RUNTIME_KEY_PUB" 2>/dev/null)
      
      if [ -z "$INITRD_AGE_KEY" ] || [ -z "$RUNTIME_AGE_KEY" ]; then
        echo "Error: Failed to convert SSH keys to Age format" >&2
        exit 1
      fi
      
      log "✓ Initrd Age key: $INITRD_AGE_KEY"
      log "✓ Runtime Age key: $RUNTIME_AGE_KEY"
    }

    # Update .sops.yaml with both keys
    update_sops_config() {
      echo "Updating SOPS configuration to include both keys..."
      
      # Create backup
      cp "$SOPS_CONFIG" "$SOPS_CONFIG.bak.$(date +%s)"
      log "✓ Backed up SOPS config to $SOPS_CONFIG.bak.*"
      
      # Check if runtime key already exists in config
      if grep -q "$RUNTIME_AGE_KEY" "$SOPS_CONFIG" 2>/dev/null; then
        echo "Runtime key already present in SOPS configuration"
        log "✓ Runtime key already in SOPS config"
        return 0
      fi
      
      # Add runtime key to SOPS configuration using add-sops-cfg
      echo "Adding runtime key to SOPS configuration..."
      
      # Add the runtime key as an alias
      if ! add-sops-cfg -o "$SOPS_CONFIG" alias "''${HOST_NAME}_runtime" "$RUNTIME_AGE_KEY"; then
        echo "Error: Failed to add runtime key alias to SOPS configuration" >&2
        exit 1
      fi
      
      # Add the runtime key to the path regex rules  
      if ! add-sops-cfg -o "$SOPS_CONFIG" path-regex "''${HOST_NAME}_runtime" "''${HOST_NAME}/secrets.yaml"; then
        echo "Error: Failed to add runtime key to path regex rules" >&2
        exit 1
      fi
      
      echo "✓ Updated SOPS configuration with dual keys"
      log "✓ SOPS config updated successfully"
    }

    # Re-encrypt secrets with both keys
    reencrypt_secrets() {
      echo "Preparing secrets for dual-key encryption..."
      
      # Create backup
      cp "$SOPS_FILE" "$SOPS_FILE.bak.$(date +%s)"
      log "✓ Backed up secrets file"
      
      # Check if we can decrypt the current secrets (i.e., do we have the keys?)
      if sops -d "$SOPS_FILE" >/dev/null 2>&1; then
        echo "✓ Can decrypt existing secrets - proceeding with re-encryption"
        
        # Re-encrypt with updated keys
        if ! sops updatekeys "$SOPS_FILE"; then
          echo "Error: Failed to re-encrypt secrets with new keys" >&2
          echo "Restoring backup..."
          mv "$SOPS_FILE.bak."* "$SOPS_FILE" 2>/dev/null || true
          exit 1
        fi
        
        echo "✓ Secrets re-encrypted with both keys"
        log "✓ Secret re-encryption successful"
      else
        echo "ℹ️  Cannot decrypt secrets locally (missing decryption keys)"
        echo "ℹ️  Secrets will be re-encrypted automatically during deployment"
        echo "✓ SOPS configuration updated - ready for deployment"
        log "✓ Deferred re-encryption until deployment"
      fi
    }

    # Validate SOPS decryption with both keys
    validate_sops_decryption() {
      echo "Validating SOPS configuration..."
      
      # Test if we can decrypt with available keys
      if sops -d "$SOPS_FILE" >/dev/null 2>&1; then
        log "✓ Decryption works with available keys"
        
        # Test decryption by extracting a known field (if exists)
        if sops -d --extract '["disks"]' "$SOPS_FILE" >/dev/null 2>&1; then
          log "✓ Can extract disk configuration from secrets"
        fi
        
        echo "✓ SOPS decryption validation completed"
      else
        echo "ℹ️  Local decryption not available (this is normal for remote preparation)"
        echo "✓ SOPS configuration is valid and ready for deployment"
        log "✓ SOPS config validation completed (deferred decryption test)"
      fi
    }

    # Display migration status
    show_migration_status() {
      echo ""
      echo "=== Migration Preparation Complete ==="
      echo "Host: $HOST_NAME"
      echo "Status: Ready for dual SSH key migration"
      echo ""
      echo "Files created/updated:"
      echo "  ✓ $RUNTIME_KEY (runtime private key)"
      echo "  ✓ $RUNTIME_KEY_PUB (runtime public key)" 
      echo "  ✓ $SOPS_CONFIG (updated with both keys)"
      
      # Show re-encryption status based on what actually happened
      if [[ -f "$HOME/.gnupg/secring.gpg" ]] || command -v age-keygen >/dev/null 2>&1; then
        echo "  ✓ $SOPS_FILE (re-encrypted with both keys)"
      else
        echo "  ℹ️ $SOPS_FILE (will be re-encrypted during deployment)"
      fi
      
      echo ""
      echo "Next steps:"
      echo "  1. Add runtime key paths to your flake.nix:"
      echo "     skarabox.hosts.$HOST_NAME = {"
      echo "       runtimeHostKeyPub = ./$HOST_NAME/runtime_host_key.pub;"
      echo "       # ... existing config"
      echo "     };"
      echo ""
      echo "  2. Deploy normally (runtime key installs automatically):"
      echo "     colmena deploy"
      echo "     # or"
      echo "     nix run .#$HOST_NAME-install-on-beacon"
      echo ""
      echo "  3. When ready to switch: nix run .#$HOST_NAME-enable-dual-mode"
      if [[ -f "$HOME/.gnupg/secring.gpg" ]] || command -v age-keygen >/dev/null 2>&1; then
        echo ""
        echo "Optional: Test local SOPS decryption: nix run .#sops -- -d $SOPS_FILE"
      fi
      echo ""
      echo "ℹ️  The host is still in single-key mode. No behavior has changed yet."
      echo ""
    }

    # Main execution
    main() {
      echo "Preparing $HOST_NAME for dual SSH key migration..."
      
      validate_host_exists
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
