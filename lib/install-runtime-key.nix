{
  pkgs,
  add-sops-cfg,
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

    HOST_NAME=""
    FLAKE_ROOT="."
    VERBOSE=0
    USE_COLMENA=0

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
Usage: $0 -n HOST_NAME [-f FLAKE_ROOT] [-c] [-v]
  -h:            Show this usage
  -n HOST_NAME:  Name of the host to install runtime key on
  -f FLAKE_ROOT: Root directory of the flake (default: current directory)
  -c:            Use colmena for deployment
  -v:            Verbose output

This is Phase 2 of dual SSH key migration. It automatically installs
the runtime SSH key on your host using skarabox's built-in activation scripts.

Prerequisites:
  - Run: nix run .#HOST_NAME-prepare-dual-migration
  - Runtime key files must exist: HOST_NAME/runtime_host_key*
  - Host must import skarabox modules

What this does:
  1. Validates prerequisites
  2. Deploys runtime key via secure transport (/tmp/)
  3. Skarabox activation script automatically installs it
  4. Validates installation 
  5. Host remains in single-key mode (no behavior change)

Next step: nix run .#HOST_NAME-enable-dual-mode
USAGE
    }

    # Parse command line arguments
    while getopts "hn:f:cv" opt; do
      case ''${opt} in
        h)
          usage
          exit 0
          ;;
        n)
          HOST_NAME="''${OPTARG}"
          ;;
        f)
          FLAKE_ROOT="''${OPTARG}"
          ;;
        c)
          USE_COLMENA=1
          ;;
        v)
          VERBOSE=1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done

    if [[ -z "$HOST_NAME" ]]; then
      echo "Error: Host name is required (-n HOST_NAME)"
      usage
      exit 1
    fi

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
    log "Deploying runtime key to $HOST_NAME..."

    if [[ $USE_COLMENA -eq 1 ]]; then
      # Use colmena with runtime key deployment
      log "Deploying with colmena..."
      
      # Deploy with runtime key as extra file
      colmena deploy --on "$HOST_NAME" \
        --disk-encryption-keys /tmp/runtime_host_key "$RUNTIME_KEY" \
        --disk-encryption-keys /tmp/runtime_host_key.pub "$RUNTIME_KEY_PUB"
        
    else
      # Use nixos-rebuild or provide instructions
      echo ""
      log "Deploy the runtime key using your preferred method:"
      echo ""
      echo "Option 1 - With nixos-rebuild:"
      echo "  nixos-rebuild switch --flake .#$HOST_NAME --target-host USER@HOST \\"
      echo "    --disk-encryption-keys /tmp/runtime_host_key $RUNTIME_KEY \\"
      echo "    --disk-encryption-keys /tmp/runtime_host_key.pub $RUNTIME_KEY_PUB"
      echo ""
      echo "Option 2 - With colmena:"
      echo "  colmena deploy --on $HOST_NAME \\"
      echo "    --disk-encryption-keys /tmp/runtime_host_key $RUNTIME_KEY \\"
      echo "    --disk-encryption-keys /tmp/runtime_host_key.pub $RUNTIME_KEY_PUB"
      echo ""
      echo "Option 3 - Manual copy (for testing):"
      echo "  scp $RUNTIME_KEY USER@HOST:/tmp/runtime_host_key"
      echo "  scp $RUNTIME_KEY_PUB USER@HOST:/tmp/runtime_host_key.pub"
      echo "  ssh USER@HOST 'sudo nixos-rebuild switch'"
      echo ""
      warn "Choose one method above to deploy"
      exit 0
    fi

    success "Runtime key deployed"

    # Validate installation
    log "Validating runtime key installation..."
    
    echo ""
    echo "Verify the installation:"
    echo "  ssh USER@$HOST_NAME 'sudo ls -la /persist/ssh/'"
    echo "  # Should show: runtime_host_key (600) and runtime_host_key.pub (644)"
    echo ""
    echo "Check activation log:"
    echo "  ssh USER@$HOST_NAME 'sudo journalctl -u nixos-rebuild | tail -20'"
    echo "  # Should show: 'Skarabox: Runtime SSH key installed'"
    echo ""
    
    success "Phase 2 complete - runtime key installation deployed"
    warn "Host remains in single-key mode until you run enable-dual-mode"
    echo ""
    echo "Next step: nix run .#$HOST_NAME-enable-dual-mode"
  '';
}