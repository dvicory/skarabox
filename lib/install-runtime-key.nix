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

    hostname="${hostName}"
    flake_root="."

    usage () {
      cat <<USAGE
Usage: $0 [-h] [-f FLAKE_ROOT]

Copies runtime key to target host in preparation for separated-key migration.

  -h:            Shows this usage
  -f FLAKE_ROOT: Root directory of the flake (default: current directory)

Prerequisites: nix run .#${hostName}-enable-key-separation
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
    echo "Validating prerequisites for $hostname..."

    host_dir="$flake_root/$hostname"
    if [ ! -d "$host_dir" ]; then
      echo "Error: Host directory not found: $host_dir" >&2
      exit 1
    fi

    runtime_key="$host_dir/runtime_host_key"
    runtime_key_pub="$host_dir/runtime_host_key.pub"

    if [ ! -f "$runtime_key" ] || [ ! -f "$runtime_key_pub" ]; then
      echo "Error: Runtime key not found. Run enable-key-separation first:" >&2
      echo " nix run .#$hostname-enable-key-separation" >&2
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

    echo "Runtime key copied to /tmp/ on $hostname"
    echo ""
    echo "Next steps:"
    echo " 1. Update $hostname/configuration.nix:"
    echo "      sops.age.sshKeyPaths = [ \"/persist/etc/ssh/ssh_host_ed25519_key\" ];"
    echo ""
    echo " 2. Update flake.nix:"
    echo "      runtimeHostKeyPub = ./$hostname/runtime_host_key.pub;"
    echo ""
    echo " 3. Deploy:"
    echo "      nix run .#$hostname-gen-knownhosts-file"
    echo "      nix run .#deploy-rs"
    echo ""
    echo " 4. After deployment, complete security migration:"
    echo "      age_key=\$(ssh-to-age < $hostname/host_key.pub)"
    echo "      nix run .#sops -- -r -i --rm-age \"\$age_key\" $hostname/secrets.yaml"
    echo "      nix run .#$hostname-rotate-boot-key"
    echo "   nix run .#$hostname-gen-knownhosts-file"
  '';
}
