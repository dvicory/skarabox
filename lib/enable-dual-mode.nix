{
  pkgs,
  hostName,
  hostCfg,
  nixosCfg,
}:
pkgs.writeShellApplication {
  name = "enable-dual-mode";

  runtimeInputs = [
    (import ./add-sops-cfg.nix { inherit pkgs; })
  ];

  text = ''
    set -e
    set -o pipefail

    HOST_NAME="${hostName}"
    FLAKE_ROOT="."

    # Colors for output
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    log() {
      echo -e "''${BLUE}[enable-dual-mode]''${NC} $*"
    }

    success() {
      echo -e "''${GREEN}[✓]''${NC} $*"
    }

    warn() {
      echo -e "''${YELLOW}[⚠]''${NC} $*"
    }

    usage() {
      cat <<USAGE
Usage: $0 [-f FLAKE_ROOT]
  -h:            Show this usage
  -f FLAKE_ROOT: Root directory of the flake (default: current directory)

This is Phase 3 of dual SSH key migration for host: ${hostName}

Prerequisites:
  - Phase 1: nix run .#${hostName}-prepare-dual-migration (completed)
  - Phase 2: nix run .#${hostName}-install-runtime-key (completed)
  - Runtime keys must be installed on the host

What this does:
  1. Validates prerequisites (runtime keys exist on host)
  2. Updates SOPS configuration to use both keys
  3. Host switches to dual SSH key mode
  4. Improved security and SOPS access via runtime key

After this step, the host will be in full dual SSH key mode.
USAGE
    }

    # Parse command line arguments
    while getopts "hf:" opt; do
      case ''${opt} in
        h)
          usage
          exit 0
          ;;
        f)
          FLAKE_ROOT="''${OPTARG}"
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done

    # Validate prerequisites
    log "Validating prerequisites for $HOST_NAME..."

    HOST_DIR="$FLAKE_ROOT/$HOST_NAME"
    if [[ ! -d "$HOST_DIR" ]]; then
      echo "Error: Host directory not found: $HOST_DIR"
      exit 1
    fi

    SECRETS_FILE="$HOST_DIR/secrets.yaml"
    if [[ ! -f "$SECRETS_FILE" ]]; then
      echo "Error: Secrets file not found: $SECRETS_FILE"
      exit 1
    fi

    # Check if runtime keys exist on host
    log "Checking if runtime keys are installed on host..."
    HOST_IP="${hostCfg.ip}"
    SSH_PORT="${toString nixosCfg.skarabox.sshPort}"
    SSH_USER="${nixosCfg.skarabox.username}"
    KNOWN_HOSTS="${hostCfg.knownHosts}"
    SSH_KEY="${if hostCfg.sshPrivateKeyPath != null then hostCfg.sshPrivateKeyPath else "${hostName}/ssh"}"

    if ! ssh -p "$SSH_PORT" -i "$SSH_KEY" \
         -o "IdentitiesOnly=yes" \
         -o "UserKnownHostsFile=$KNOWN_HOSTS" \
         -o "ConnectTimeout=10" \
         "$SSH_USER@$HOST_IP" \
         'sudo test -f /persist/ssh/runtime_host_key && sudo test -f /persist/ssh/runtime_host_key.pub'; then
      echo "Error: Runtime keys not found on host. Run Phase 2 first:"
      echo "  nix run .#$HOST_NAME-install-runtime-key"
      exit 1
    fi

    success "Prerequisites validated - runtime keys are installed"

    # Update SOPS configuration to include runtime key
    log "Adding runtime key to SOPS configuration..."
    
    RUNTIME_KEY_ALIAS="''${HOST_NAME}_runtime"
    RUNTIME_KEY_PATH="/persist/ssh/runtime_host_key"
    
    # Add the runtime key to SOPS configuration
    add-sops-cfg -o "$SECRETS_FILE" path-regex "$RUNTIME_KEY_ALIAS" "$RUNTIME_KEY_PATH"
    
    success "SOPS configuration updated to include runtime key"

    # Instructions for deployment
    echo ""
    log "SOPS configuration updated. Deploy to complete Phase 3:"
    echo ""
    echo "Deploy with your normal workflow:"
    echo "  nix run .#colmena -- apply --on $HOST_NAME"
    echo "  nix run .#deploy-rs -- .#$HOST_NAME"
    echo ""
    warn "After deployment, the host will be in dual SSH key mode"
    echo ""
    echo "Dual SSH key mode features:"
    echo "  - Boot SSH key: /boot/host_key (unlock/emergency access)"  
    echo "  - Runtime SSH key: /persist/ssh/runtime_host_key (admin/SOPS access)"
    echo "  - Enhanced security with separate key purposes"
    echo ""
    success "Phase 3 setup complete - ready for dual SSH key mode deployment"
  '';
}