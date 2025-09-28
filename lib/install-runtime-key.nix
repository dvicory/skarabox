{
  pkgs,
  hostName,
  ...
}:
pkgs.writeShellApplication {
  name = "install-runtime-key";

  runtimeInputs = [
    pkgs.openssh
    pkgs.nixos-rebuild
    pkgs.colmena
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
      echo -e "''${BLUE}[install-runtime-key]''${NC} $*"
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

This is Phase 2 of dual SSH key migration for host: ${hostName}

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

    RUNTIME_KEY="$HOST_DIR/runtime_host_key"
    RUNTIME_KEY_PUB="$HOST_DIR/runtime_host_key.pub"
    
    if [[ ! -f "$RUNTIME_KEY" || ! -f "$RUNTIME_KEY_PUB" ]]; then
      echo "Error: Runtime key not found. Run prepare-dual-migration first:"
      echo "  nix run .#$HOST_NAME-prepare-dual-migration"
      exit 1
    fi

    success "Prerequisites validated"

    # Deploy runtime key using skarabox's activation infrastructure
    log "Copying runtime keys to $HOST_NAME..."

    # Get host connection info from flake
    HOST_IP=$(nix eval --raw ".#skarabox.hosts.$HOST_NAME.ip" 2>/dev/null || echo "")
    SSH_PORT=$(nix eval --json ".#nixosConfigurations.$HOST_NAME.config.skarabox.sshPort" 2>/dev/null || echo "22")
    SSH_USER=$(nix eval --raw ".#nixosConfigurations.$HOST_NAME.config.skarabox.username" 2>/dev/null || echo "root")
    KNOWN_HOSTS=$(nix eval --raw ".#skarabox.hosts.$HOST_NAME.knownHosts" 2>/dev/null || echo "$HOST_NAME/known_hosts")
    SSH_KEY=$(nix eval --raw ".#skarabox.hosts.$HOST_NAME.sshPrivateKeyPath" 2>/dev/null || echo "$HOST_NAME/ssh")

    if [[ -z "$HOST_IP" ]]; then
      echo "Error: Could not determine IP for host $HOST_NAME"
      exit 1
    fi

    # Copy runtime keys to /tmp/ on target host
    log "Copying runtime keys to $HOST_IP:$SSH_PORT"
    scp -P "$SSH_PORT" -i "$SSH_KEY" \
      -o "IdentitiesOnly=yes" \
      -o "UserKnownHostsFile=$KNOWN_HOSTS" \
      -o "ConnectTimeout=10" \
      "$RUNTIME_KEY" "$RUNTIME_KEY_PUB" \
      "$SSH_USER@$HOST_IP:/tmp/"

    success "Runtime keys copied to /tmp/ on $HOST_NAME"

    # Instructions for deployment
    echo ""
    log "Next: Deploy using your normal workflow to trigger installation"
    echo ""
    echo "Examples:"
    echo "  nix run .#colmena -- apply --on $HOST_NAME"
    echo "  nix run .#deploy-rs -- .#$HOST_NAME"
    echo "  nixos-rebuild switch --flake .#$HOST_NAME --target-host $SSH_USER@$HOST_IP"
    echo ""
    echo "The skarabox activation script will automatically detect the keys in /tmp/"
    echo "and install them to /persist/ssh/ with proper permissions."

    # Validate installation
    echo ""
    log "After deployment, verify the installation:"
    echo ""
    echo "  ssh $SSH_USER@$HOST_IP 'sudo ls -la /persist/ssh/'"
    echo "  # Should show: runtime_host_key (600) and runtime_host_key.pub (644)"
    echo ""
    echo "  ssh $SSH_USER@$HOST_IP 'sudo journalctl -u nixos-rebuild-switch | tail -20'"
    echo "  # Should show: 'Skarabox: Runtime SSH key installed'"
    echo ""

    success "Phase 2 setup complete - runtime keys are ready for installation"
    warn "Complete the deployment above, then run enable-dual-mode"
    echo ""
    echo "Final step: nix run .#$HOST_NAME-enable-dual-mode"
  '';
}
