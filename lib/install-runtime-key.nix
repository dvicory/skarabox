{
  pkgs,
  hostName,
  hostCfg,
  nixosCfg,
}:
pkgs.writeShellApplication {
  name = "install-runtime-key";

  runtimeInputs = [
    pkgs.openssh
  ];

  text = ''
    set -euo pipefail

    host_name="${hostName}"
    flake_root="."

    usage () {
      cat <<USAGE
    Usage: $0 [-h] [-f FLAKE_ROOT]

      -h:            Shows this usage
      -f FLAKE_ROOT: Root directory of the flake (default: current directory)

    Phase 2 of dual host key migration for host: ${hostName}

    Prerequisites:
      - Run: nix run .#${hostName}-prepare-dual-migration
      - Runtime key files must exist: ${hostName}/runtime_host_key*
      - Host must import skarabox modules

    What this does:
      1. Validates prerequisites
      2. Copies runtime keys to /tmp/ on target host
      3. Shows deployment instructions for your normal workflow
      4. Host remains in single-key mode (no behavior change)

    Next step: Deploy, then run nix run .#${hostName}-enable-dual-mode
USAGE
    }

    check_empty () {
      if [ -z "$1" ]; then
        echo "$3 must not be empty, pass with flag $2" >&2
        exit 1
      fi
    }

    while getopts "hf:" o; do
      case "''${o}" in
        h)
          usage
          exit 0
          ;;
        f)
          flake_root="''${OPTARG}"
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done
    shift $((OPTIND-1))

    # Validate prerequisites
    echo "Validating prerequisites for $host_name..."

    host_dir="$flake_root/$host_name"
    if [ ! -d "$host_dir" ]; then
      echo "Error: Host directory not found: $host_dir" >&2
      exit 1
    fi

    runtime_key="$host_dir/runtime_host_key"
    runtime_key_pub="$host_dir/runtime_host_key.pub"
    
    if [ ! -f "$runtime_key" ] || [ ! -f "$runtime_key_pub" ]; then
      echo "Error: Runtime key not found. Run prepare-dual-migration first:" >&2
      echo " nix run .#$host_name-prepare-dual-migration" >&2
      exit 1
    fi

    echo "Prerequisites validated"

    # Get host connection info from passed configuration
    host_ip="${hostCfg.ip}"
    ssh_port="${toString nixosCfg.skarabox.sshPort}"
    ssh_user="${nixosCfg.skarabox.username}"
    known_hosts="${hostCfg.knownHosts}"
    ssh_key="${if hostCfg.sshPrivateKeyPath != null then hostCfg.sshPrivateKeyPath else "${hostName}/ssh"}"

    # Copy runtime private key to /tmp/ on target host
    echo "Copying runtime key to $host_ip:$ssh_port..."
    scp -P "$ssh_port" -i "$ssh_key" \
      -o "IdentitiesOnly=yes" \
      -o "UserKnownHostsFile=$known_hosts" \
      -o "ConnectTimeout=10" \
      "$runtime_key" \
      "$ssh_user@$host_ip:/tmp/"

    echo "Runtime key copied to /tmp/ on $host_name"

    # Instructions for deployment
    echo ""
    echo "Next: Deploy using your normal workflow to trigger installation"
    echo ""
    echo "Examples:"
    echo " nix run .#colmena -- apply --on $host_name"
    echo " nix run .#deploy-rs -- .#$host_name"
    echo " nixos-rebuild switch --flake .#$host_name --target-host $ssh_user@$host_ip"
    echo ""
    echo "The skarabox activation script will automatically detect the keys in /tmp/"
    echo "and install them to /persist/etc/ssh/ with proper permissions (OpenSSH standard)."

    # Validate installation
    echo ""
    echo "After deployment, verify the installation:"
    echo ""
    echo " ssh $ssh_user@$host_ip 'sudo ls -la /persist/etc/ssh/'"
    echo " # Should show: ssh_host_ed25519_key (600)"
    echo ""
    echo " ssh $ssh_user@$host_ip 'sudo journalctl -u nixos-rebuild-switch | tail -20'"
    echo " # Should show: 'Skarabox: Runtime SSH key installed'"
    echo ""

    echo "Phase 2 setup complete - runtime keys installed"
    echo ""
    echo "Next steps to complete dual host key migration:"
    echo "1. Update $host_name/configuration.nix:"
    echo "  sops.age.sshKeyPaths = [ \"/persist/etc/ssh/ssh_host_ed25519_key\" ];"
    echo ""
    echo "2. Regenerate known_hosts: nix run .#$host_name-gen-knownhosts-file"
    echo ""
    echo "3. Deploy: nix run .#deploy-rs (or colmena, etc.)"
    echo ""
    echo "4. Remove boot key from SOPS:"
    echo "  age_key=\$(nix shell nixpkgs#ssh-to-age -c ssh-to-age < $host_name/host_key.pub)"
    echo "  nix run .#sops -- -r -i --rm-age \"\$age_key\" $host_name/secrets.yaml"
    echo ""
    echo "See docs/normal-operations.md for complete migration guide"
  '';
}
