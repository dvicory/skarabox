{
  pkgs,
  add-sops-cfg,
  hostName,
  hostCfg,
}:
pkgs.writeShellApplication {
  name = "enable-key-separation";

  runtimeInputs = [
    pkgs.openssh
    pkgs.yq-go
    pkgs.ssh-to-age
    add-sops-cfg
  ];

  text = ''
    set -euo pipefail

    # From flake configuration
    hostname="${hostName}"
    boot_key_pub="${hostCfg.hostKeyPub}"
    runtime_key="${hostCfg.runtimeHostKeyPath}"
    runtime_key_pub_path="''${runtime_key}.pub"
    runtime_key_pub_content="${if hostCfg.runtimeHostKeyPub != null then hostCfg.runtimeHostKeyPub else ""}"
    sops_file="${hostName}/secrets.yaml"
    sops_cfg=".sops.yaml"

    usage () {
      cat <<USAGE
Usage: $0 [-h] [-f FLAKE_ROOT] [-v]

Generates runtime keys and updates SOPS configuration for separated-key migration.

  -h:            Shows this usage
  -f FLAKE_ROOT: Root directory of the flake (default: current directory)
  -v:            Verbose output
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

    cd "$flake_root"

    log () {
      if [ "$verbose" -eq 1 ]; then
        echo "[$(date '+%H:%M:%S')] $*"
      fi
    }

    validate_boot_key () {
      if [ -z "$boot_key_pub" ]; then
        echo "Error: Boot public key not configured in flake" >&2
        exit 1
      fi
      log "Boot public key configured"
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

    generate_runtime_key () {
      if [ -f "$runtime_key" ] && [ -f "$runtime_key_pub_path" ]; then
        echo "[1/6] Runtime SSH key already exists, skipping generation"
        return 0
      fi

      echo "[1/6] Generating runtime SSH key pair for $hostname..."
      ssh-keygen -t ed25519 -N "" -f "$runtime_key" -C "runtime-key@$hostname"
      chmod 600 "$runtime_key"
      chmod 644 "$runtime_key_pub_path"
      echo "Generated runtime SSH key: $runtime_key"
      log "Runtime key permissions set correctly"
    }

    get_age_keys () {
      echo "[2/6] Converting SSH keys to Age format..."
      log "Converting SSH public keys to Age format..."

      boot_age_key=$(echo "$boot_key_pub" | ssh-to-age 2>/dev/null)
      if [ -n "$runtime_key_pub_content" ]; then
        runtime_age_key=$(echo "$runtime_key_pub_content" | ssh-to-age 2>/dev/null)
      else
        runtime_age_key=$(ssh-to-age < "$runtime_key_pub_path" 2>/dev/null)
      fi

      if [ -z "$boot_age_key" ] || [ -z "$runtime_age_key" ]; then
        echo "Error: Failed to convert SSH keys to Age format" >&2
        exit 1
      fi

      log "Boot Age key: $boot_age_key"
      log "Runtime Age key: $runtime_age_key"
    }

    update_sops_config () {
      echo "[3/6] Updating SOPS configuration..."

      cp "$sops_cfg" "$sops_cfg.bak.$(date +%s)"
      log "Backed up SOPS config to $sops_cfg.bak.*"

      if grep -q "$runtime_age_key" "$sops_cfg" 2>/dev/null; then
        echo "Runtime key already in SOPS config"
        return 0
      fi

      echo "Renaming boot host key alias to ''${hostname}_boot..."
      if yq eval ".keys.[] | select(anchor == \"$hostname\")" "$sops_cfg" >/dev/null 2>&1; then
        # Rename anchor and update all alias references
        yq eval -i \
          "(.keys.[] | select(anchor == \"$hostname\")) anchor = \"''${hostname}_boot\" |
           (.. | select(alias == \"$hostname\")) alias = \"''${hostname}_boot\"" \
          "$sops_cfg"
        log "Renamed existing key alias to ''${hostname}_boot"
      fi

      # Add runtime key as primary $hostname alias
      echo "Adding runtime host key as $hostname..."
      if ! add-sops-cfg -o "$sops_cfg" alias "$hostname" "$runtime_age_key"; then
        echo "Error: Failed to add runtime key alias to SOPS configuration" >&2
        exit 1
      fi

      # Add the runtime key to the path regex rules
      if ! add-sops-cfg -o "$sops_cfg" path-regex "$hostname" "$sops_file"; then
        echo "Error: Failed to add runtime key to path regex rules" >&2
        exit 1
      fi

      echo "Updated SOPS configuration with both keys"
      log "SOPS config updated successfully"
    }

    # Note: Secrets re-encryption is now a manual step
  # The script will guide the user after completing the automated steps

    show_migration_status () {
      echo ""
      echo "[4/4] Migration Preparation Complete"
      echo ""
      echo "Files updated:"
      echo "  $runtime_key"
      echo "  $runtime_key_pub_path"
      echo "  $sops_cfg"

      echo ""
      echo "Next steps:"
      echo " 1. Re-encrypt secrets:"
      echo "      nix run .#sops -- updatekeys $sops_file"
      echo ""
      echo " 2. Install runtime key on target:"
      echo "      nix run .#$hostname-install-runtime-key"
      echo ""
      echo " 3. Update configuration.nix SOPS path:"
      echo "      sshKeyPaths = [\"/persist/etc/ssh/ssh_host_ed25519_key\"];"
      echo ""
      echo " 4. Update flake.nix:"
      echo "      runtimeHostKeyPub = ./$hostname/runtime_host_key.pub;"
      echo ""
      echo " 5. Regenerate known_hosts and deploy:"
      echo "      nix run .#$hostname-gen-knownhosts-file"
      echo "      nix run .#deploy-rs"
      echo ""
    }

    main () {
      echo "Preparing $hostname for separated-key migration..."

      validate_boot_key
      validate_sops_files

      generate_runtime_key
      get_age_keys
      update_sops_config

      show_migration_status
    }

    main
  '';
}
